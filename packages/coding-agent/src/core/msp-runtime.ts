// msp-runtime.ts — in-process MSP sandbox kernel for pi-shell.
//
// Loads libMSPKernel.so (the vendored ModelShellProxy compiled to a C ABI
// shared library, see packages/msp-kernel) via Bun FFI and exposes
// mspRunJson(workspace, command). All sandbox execution happens inside the
// pi-shell process — no external msp-shell process is spawned.
//
// In non-Bun runtimes (plain `node dist/cli.js`) "bun:ffi" does not resolve, so
// the kernel is unavailable and the bash tool falls back to the default local
// shell.

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export interface MspRunResult {
	stdout: string;
	stderr: string;
	exit_code: number;
}

// ---- bun:ffi (loaded lazily, only inside the Bun runtime) ----

interface BunFfiModule {
	dlopen: (
		path: string,
		definitions: Record<string, unknown>,
	) => { symbols: Record<string, (...args: unknown[]) => unknown> };
	FFIType: Record<string, unknown>;
	ptr: (value: ArrayBufferView) => number;
	CString: new (pointer: number) => { toString(): string };
}

let ffiModule: BunFfiModule | undefined;

async function getFfi(): Promise<BunFfiModule> {
	if (ffiModule) return ffiModule;
	// @ts-expect-error — "bun:ffi" only exists inside the Bun runtime (pi-shell binary)
	const mod = (await import("bun:ffi")) as BunFfiModule;
	ffiModule = mod;
	return ffiModule;
}

// ---- kernel loading ----

interface LoadedKernel {
	ffi: BunFfiModule;
	symbols: {
		// All three args are raw C pointers (addresses of C strings / the out slot).
		msp_run_json: (workspacePtr: number, commandPtr: number, outSlot: number) => number;
		msp_free_json: (pointer: number) => void;
	};
}

let loadedKernel: LoadedKernel | undefined;
let kernelLoadError: string | undefined;
let kernelLoadPromise: Promise<{ ok: true; kernel: LoadedKernel } | { ok: false; error: string }> | undefined;

function candidateSoPaths(): string[] {
	const candidates = [join(dirname(process.execPath), "libMSPKernel.so")];
	// Running from source/dist with bun (dev): packages/coding-agent/dist/core/../../../msp-kernel/...
	candidates.push(
		join(
			dirname(fileURLToPath(import.meta.url)),
			"..",
			"..",
			"..",
			"msp-kernel",
			"swift",
			".build",
			"release",
			"libMSPKernel.so",
		),
	);
	candidates.push(
		join(
			dirname(fileURLToPath(import.meta.url)),
			"..",
			"..",
			"..",
			"msp-kernel",
			"swift",
			".build",
			"debug",
			"libMSPKernel.so",
		),
	);
	const envOverride = process.env.PI_MSP_KERNEL;
	if (envOverride) candidates.push(envOverride);
	return candidates;
}

async function loadKernel(): Promise<{ ok: true; kernel: LoadedKernel } | { ok: false; error: string }> {
	if (loadedKernel) return { ok: true, kernel: loadedKernel };
	if (kernelLoadError) return { ok: false, error: kernelLoadError };
	// Shared promise: the agent issues several bash tool calls concurrently in one
	// block. Without a single shared load, the first caller flips a "loading"
	// flag and the concurrent callers race past it and incorrectly fall back to
	// the host shell. All callers must await the SAME dlopen result.
	kernelLoadPromise ??= (async () => {
		let ffi: BunFfiModule;
		try {
			ffi = await getFfi();
		} catch (error) {
			return {
				ok: false as const,
				error: `MSP kernel unavailable (not running under Bun): ${(error as Error).message}`,
			};
		}

		const soPath = candidateSoPaths().find((p) => existsSync(p));
		if (!soPath) {
			return {
				ok: false as const,
				error: "libMSPKernel.so not found. Build it with: bash packages/msp-kernel/build.sh, or set PI_MSP_KERNEL to its path.",
			};
		}

		try {
			const { symbols } = ffi.dlopen(soPath, {
				msp_run_json: {
					// NOTE: args are all FFIType.pointer — we pass explicit C-string
					// Buffers for workspace/command (bun's `cstring` arg type is
					// unreliable; it throws "To convert a string to a pointer").
					args: [ffi.FFIType.pointer, ffi.FFIType.pointer, ffi.FFIType.pointer],
					returns: ffi.FFIType.i32,
				},
				msp_free_json: {
					args: [ffi.FFIType.pointer],
					returns: ffi.FFIType.void,
				},
			});
			const kernel: LoadedKernel = {
				ffi,
				symbols: {
					msp_run_json: symbols.msp_run_json as LoadedKernel["symbols"]["msp_run_json"],
					msp_free_json: symbols.msp_free_json as LoadedKernel["symbols"]["msp_free_json"],
				},
			};
			loadedKernel = kernel;
			return { ok: true as const, kernel };
		} catch (error) {
			return { ok: false as const, error: `libMSPKernel.so dlopen failed: ${(error as Error).message}` };
		}
	})();
	const result = await kernelLoadPromise;
	if (!result.ok) kernelLoadError = result.error;
	return result;
}

/** True when the in-process MSP kernel is available (i.e. running pi-shell). */
export async function isMspKernelAvailable(): Promise<boolean> {
	return (await loadKernel()).ok;
}

/**
 * Synchronous check for "this is a pi-msp environment": running under Bun AND a
 * libMSPKernel.so candidate exists on disk. Unlike isMspKernelAvailable (which
 * dlopens lazily and is async), this never loads the kernel — it is meant for
 * synchronous decisions like system-prompt text. It may report true even if a
 * later dlopen fails; actual execution still gates on isMspKernelAvailable.
 */
export function isMspKernelEnvironment(): boolean {
	if (typeof (process.versions as { bun?: string }).bun !== "string") {
		return false;
	}
	return candidateSoPaths().some((p) => existsSync(p));
}

/**
 * Run one command inside the MSP sandbox rooted at `workspace`.
 * Returns the MSP JSON protocol result { stdout, stderr, exit_code }.
 * Throws if the kernel is unavailable or the command failed to produce JSON.
 */
export async function mspRunJson(workspace: string, command: string): Promise<MspRunResult> {
	const loaded = await loadKernel();
	if (!loaded.ok) throw new Error(loaded.error);
	const { ffi, symbols } = loaded.kernel;

	// char** out slot: a writable 8-byte buffer whose address we pass to the C
	// function; afterwards slot[0] holds the malloc'd JSON pointer.
	const workspaceBuf = Buffer.from(`${workspace}\0`, "utf8");
	const commandBuf = Buffer.from(`${command}\0`, "utf8");
	const outSlot = new BigUint64Array(1);
	const exitCode = symbols.msp_run_json(ffi.ptr(workspaceBuf), ffi.ptr(commandBuf), ffi.ptr(outSlot));
	const jsonAddress = outSlot[0];
	if (jsonAddress === 0n) {
		throw new Error(`msp_run_json returned null JSON (exit=${exitCode})`);
	}
	try {
		const jsonText = new ffi.CString(Number(jsonAddress)).toString();
		const result = JSON.parse(jsonText) as MspRunResult;
		if (process.env.MSP_KERNEL_DEBUG === "1") {
			// Ground-truth trace of every sandbox command (stderr, not fed to the model).
			console.error(
				`[msp-kernel] ws=${workspace} cmd=${JSON.stringify(command)} rc=${result.exit_code} ` +
					`stdout=${JSON.stringify(result.stdout.slice(0, 120))} stderr=${JSON.stringify(result.stderr.slice(0, 120))}`,
			);
		}
		return result;
	} finally {
		symbols.msp_free_json(Number(jsonAddress));
	}
}

// ---- dynamic workspace mapping ----

export interface MappedCommand {
	/** Sandbox root (real directory) for this command. */
	workspace: string;
	/** Command to run inside the sandbox. */
	command: string;
	/** True when a leading `cd` re-rooted the workspace. */
	rooted: boolean;
}

/**
 * The sandbox root, fixed at the session workspace. `cd` inside commands is
 * handled by the MSP virtual FS, which is bounded to this root — it can never
 * re-root the sandbox to an arbitrary real host directory.
 */
export class WorkspaceMapper {
	private readonly workspaceRoot: string;

	constructor(initialDir: string) {
		this.workspaceRoot = initialDir;
	}

	get active(): string {
		return this.workspaceRoot;
	}

	mapCommand(command: string): MappedCommand {
		// SECURITY: do NOT re-root to an arbitrary real host directory. The
		// previous implementation resolved `cd <target>` against the HOST
		// filesystem (existsSync) and re-rooted the sandbox there, so `cd /etc &&
		// cat passwd` escaped the sandbox and read the real host. The MSP virtual
		// FS handles `cd` itself and only knows paths inside the workspace root.
		return { workspace: this.workspaceRoot, command, rooted: false };
	}
}

// ---- shared workspace mapper (used by bash and any MSP-backed tool) ----

let sharedMapper: WorkspaceMapper | undefined;

/**
 * Get the process-wide workspace mapper, initializing with `initialDir` on first
 * use. All tools (bash/grep/find) share it so the sandbox root follows the
 * agent's active directory consistently.
 */
export function getMspMapper(initialDir: string): WorkspaceMapper {
	sharedMapper ??= new WorkspaceMapper(initialDir);
	return sharedMapper;
}
