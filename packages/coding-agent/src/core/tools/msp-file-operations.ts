// msp-file-operations.ts — workspace-bounded file operations for the structured
// tools (read/edit/write/grep/find/ls).
//
// The MSP bash sandbox already confines commands to a virtual FS rooted at the
// session workspace; a path outside it "does not exist". The structured tools,
// however, read/write the real host filesystem via fs/promises, so `read
// /etc/passwd` reached the host. These operations wrap each fs call with
// resolveSandboxed so the structured tools share the bash sandbox's boundary.
//
// I/O is unchanged — still fs/promises Buffers — so binary/image handling,
// truncation, and diffs are untouched. Only path resolution gains a boundary.
//
// Availability is gated on isMspKernelAvailable() per call, mirroring the bash
// tool (bash.ts): when the in-process MSP kernel is not loadable (plain `node`,
// or dlopen failed), operations fall back to the default host implementations
// so behavior matches upstream pi exactly. The cost is one cached promise
// check per call; the kernel load itself happens once (msp-runtime.ts shared
// promise + loadedKernel/kernelLoadError cache).

import { constants } from "node:fs";
import {
	access as fsAccess,
	mkdir as fsMkdir,
	readdir as fsReaddir,
	readFile as fsReadFile,
	stat as fsStat,
	writeFile as fsWriteFile,
} from "node:fs/promises";
import { join } from "node:path";
import { detectSupportedImageMimeTypeFromFile } from "../../utils/mime.ts";
import { canonicalizePath, getCwdRelativePath } from "../../utils/paths.ts";
import { isMspKernelAvailable } from "../msp-runtime.ts";
import type { EditOperations } from "./edit.ts";
import type { FindOperations } from "./find.ts";
import type { GrepOperations } from "./grep.ts";
import type { LsOperations } from "./ls.ts";
import { pathExists, resolveSandboxed, resolveToCwd } from "./path-utils.ts";
import type { ReadOperations } from "./read.ts";
import type { WriteOperations } from "./write.ts";

/**
 * Build workspace-bounded operations for all six structured file tools, rooted
 * at `workspaceRoot`. The root is canonicalized once (symlink-resolved) so a
 * workspace root that is itself a symlink is compared against its real target.
 *
 * Each operation resolves the caller's path against `workspaceRoot` (acting as
 * both the relative-base cwd and the boundary root) via resolveSandboxed, then
 * performs the underlying fs call. When the MSP kernel is unavailable, every
 * operation falls back to plain resolution against the workspace root with no
 * boundary enforced — matching upstream pi behavior when the kernel is absent.
 */
export function createMspFileOperations(workspaceRoot: string): {
	read: ReadOperations;
	edit: EditOperations;
	write: WriteOperations;
	grep: GrepOperations;
	find: FindOperations;
	ls: LsOperations;
} {
	// Canonicalize once so boundary checks compare against the real target even
	// when the workspace root itself is a symlink. canonicalizePath falls back
	// to the raw path if resolution fails, which is acceptable for a root that
	// should exist.
	const root = canonicalizePath(workspaceRoot);

	/**
	 * Resolve p against the workspace, enforcing the boundary when the kernel
	 * is up; falling back to plain resolution (no boundary) when it is not.
	 *
	 * Paths the model passes are interpreted relative to the sandbox's virtual
	 * root "/" (which maps to workspaceRoot). But the tool factories resolve
	 * relative paths against the REAL cwd BEFORE reaching these operations (e.g.
	 * edit.ts resolveToCwd(path, cwd)), so by the time we get here a relative
	 * path is already an absolute path under the workspace — leave those alone.
	 * A genuinely absolute path like /tmp/foo that is OUTSIDE the workspace was
	 * passed by the model as a virtual-root path (it saw `Current working
	 * directory: /`), so map it under the workspace root to match what the MSP
	 * bash sandbox does (`/tmp/foo` → workspaceRoot/tmp/foo). This keeps the
	 * structured tools and bash on the same virtual filesystem.
	 */
	const resolve = async (p: string): Promise<string> => {
		if (await isMspKernelAvailable()) {
			const rel = getCwdRelativePath(canonicalizePath(p), root);
			// Out-of-workspace absolute path → treat as virtual-root path.
			const mapped = rel === undefined && p.startsWith("/") ? join(root, p.replace(/^\/+/, "")) : p;
			return resolveSandboxed(mapped, root, root);
		}
		return resolveToCwd(p, root);
	};

	return {
		read: {
			async readFile(absolutePath: string): Promise<Buffer> {
				return fsReadFile(await resolve(absolutePath));
			},
			async access(absolutePath: string): Promise<void> {
				return fsAccess(await resolve(absolutePath), constants.R_OK);
			},
			detectImageMimeType: detectSupportedImageMimeTypeFromFile,
		},
		edit: {
			async readFile(absolutePath: string): Promise<Buffer> {
				return fsReadFile(await resolve(absolutePath));
			},
			async writeFile(absolutePath: string, content: string): Promise<void> {
				await fsWriteFile(await resolve(absolutePath), content, "utf-8");
			},
			async access(absolutePath: string): Promise<void> {
				return fsAccess(await resolve(absolutePath), constants.R_OK | constants.W_OK);
			},
		},
		write: {
			async writeFile(absolutePath: string, content: string): Promise<void> {
				await fsWriteFile(await resolve(absolutePath), content, "utf-8");
			},
			async mkdir(dir: string): Promise<void> {
				await fsMkdir(await resolve(dir), { recursive: true });
			},
		},
		grep: {
			async isDirectory(absolutePath: string): Promise<boolean> {
				return (await fsStat(await resolve(absolutePath))).isDirectory();
			},
			async readFile(absolutePath: string): Promise<string> {
				return fsReadFile(await resolve(absolutePath), "utf-8");
			},
		},
		find: {
			async exists(absolutePath: string): Promise<boolean> {
				if (!(await isMspKernelAvailable())) {
					// Kernel unavailable: resolve against the workspace (no boundary)
					// so relative paths work, then check existence.
					return pathExists(resolveToCwd(absolutePath, root));
				}
				try {
					await resolve(absolutePath);
					return true;
				} catch {
					return false;
				}
			},
			// glob stays on the host fd binary path; fd is not fetched in pi-msp
			// (ensureTool returns undefined), so this remains a no-op as upstream.
			glob: () => [],
		},
		ls: {
			async exists(absolutePath: string): Promise<boolean> {
				if (!(await isMspKernelAvailable())) {
					return pathExists(resolveToCwd(absolutePath, root));
				}
				try {
					await resolve(absolutePath);
					return true;
				} catch {
					return false;
				}
			},
			async stat(absolutePath: string) {
				return fsStat(await resolve(absolutePath));
			},
			async readdir(absolutePath: string): Promise<string[]> {
				return fsReaddir(await resolve(absolutePath));
			},
		},
	};
}
