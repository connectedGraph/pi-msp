import { accessSync, constants } from "node:fs";
import { access } from "node:fs/promises";
import { canonicalizePath, getCwdRelativePath, normalizePath, resolvePath } from "../../utils/paths.ts";

const NARROW_NO_BREAK_SPACE = "\u202F";

function tryMacOSScreenshotPath(filePath: string): string {
	return filePath.replace(/ (AM|PM)\./gi, `${NARROW_NO_BREAK_SPACE}$1.`);
}

function tryNFDVariant(filePath: string): string {
	// macOS stores filenames in NFD (decomposed) form, try converting user input to NFD
	return filePath.normalize("NFD");
}

function tryCurlyQuoteVariant(filePath: string): string {
	// macOS uses U+2019 (right single quotation mark) in screenshot names like "Capture d'écran"
	// Users typically type U+0027 (straight apostrophe)
	return filePath.replace(/'/g, "\u2019");
}

function fileExists(filePath: string): boolean {
	try {
		accessSync(filePath, constants.F_OK);
		return true;
	} catch {
		return false;
	}
}

export async function pathExists(filePath: string): Promise<boolean> {
	try {
		await access(filePath, constants.F_OK);
		return true;
	} catch {
		return false;
	}
}

export function expandPath(filePath: string): string {
	return normalizePath(filePath, { normalizeUnicodeSpaces: true, stripAtPrefix: true });
}

/**
 * Resolve a path relative to the given cwd.
 * Handles ~ expansion and absolute paths.
 */
export function resolveToCwd(filePath: string, cwd: string): string {
	return resolvePath(filePath, cwd, { normalizeUnicodeSpaces: true, stripAtPrefix: true });
}

/**
 * Verify an already-resolved absolute path is inside `workspaceRoot`, following
 * symlinks first so a link pointing outside the workspace is rejected. Throws a
 * "Path not found" error otherwise — the same wording ls uses and the same
 * "does not exist" semantics the MSP sandbox exposes. No mention of being
 * outside the workspace: the path simply does not exist for the caller.
 *
 * `originalForMessage` is the path shown in the error (typically the raw,
 * un-canonicalized input) so diagnostics stay readable.
 */
export function assertInsideWorkspace(absolutePath: string, workspaceRoot: string, originalForMessage: string): void {
	const canonical = canonicalizePath(absolutePath);
	// canonicalizePath falls back to the raw path when the target does not exist
	// yet (e.g. a file write is about to create it). getCwdRelativePath handles
	// that case lexically: a not-yet-existing path under the workspace still
	// resolves to a relative path that does not start with "..".
	const rel = getCwdRelativePath(canonical, workspaceRoot);
	if (rel === undefined) {
		throw new Error(`Path not found: ${originalForMessage}`);
	}
}

/**
 * Resolve a path against `cwd` and enforce that it lies inside `workspaceRoot`.
 * Used by the MSP-backed file operations (read/edit/write/ls) so the structured
 * tools share the same workspace boundary the MSP bash sandbox already
 * enforces — `cd /etc && cat passwd` is no more reachable via `read` than via
 * bash. This always enforces the boundary; the kernel-availability fallback to
 * plain host resolution lives in msp-file-operations, which calls resolveToCwd
 * (not this) when the kernel is unavailable.
 */
export function resolveSandboxed(filePath: string, cwd: string, workspaceRoot: string): string {
	const resolved = resolveToCwd(filePath, cwd);
	assertInsideWorkspace(resolved, workspaceRoot, filePath);
	return canonicalizePath(resolved);
}

export function resolveReadPath(filePath: string, cwd: string): string {
	const resolved = resolveToCwd(filePath, cwd);

	if (fileExists(resolved)) {
		return resolved;
	}

	// Try macOS AM/PM variant (narrow no-break space before AM/PM)
	const amPmVariant = tryMacOSScreenshotPath(resolved);
	if (amPmVariant !== resolved && fileExists(amPmVariant)) {
		return amPmVariant;
	}

	// Try NFD variant (macOS stores filenames in NFD form)
	const nfdVariant = tryNFDVariant(resolved);
	if (nfdVariant !== resolved && fileExists(nfdVariant)) {
		return nfdVariant;
	}

	// Try curly quote variant (macOS uses U+2019 in screenshot names)
	const curlyVariant = tryCurlyQuoteVariant(resolved);
	if (curlyVariant !== resolved && fileExists(curlyVariant)) {
		return curlyVariant;
	}

	// Try combined NFD + curly quote (for French macOS screenshots like "Capture d'écran")
	const nfdCurlyVariant = tryCurlyQuoteVariant(nfdVariant);
	if (nfdCurlyVariant !== resolved && fileExists(nfdCurlyVariant)) {
		return nfdCurlyVariant;
	}

	return resolved;
}

export async function resolveReadPathAsync(filePath: string, cwd: string): Promise<string> {
	const resolved = resolveToCwd(filePath, cwd);

	if (await pathExists(resolved)) {
		return resolved;
	}

	// Try macOS AM/PM variant (narrow no-break space before AM/PM)
	const amPmVariant = tryMacOSScreenshotPath(resolved);
	if (amPmVariant !== resolved && (await pathExists(amPmVariant))) {
		return amPmVariant;
	}

	// Try NFD variant (macOS stores filenames in NFD form)
	const nfdVariant = tryNFDVariant(resolved);
	if (nfdVariant !== resolved && (await pathExists(nfdVariant))) {
		return nfdVariant;
	}

	// Try curly quote variant (macOS uses U+2019 in screenshot names)
	const curlyVariant = tryCurlyQuoteVariant(resolved);
	if (curlyVariant !== resolved && (await pathExists(curlyVariant))) {
		return curlyVariant;
	}

	// Try combined NFD + curly quote (for French macOS screenshots like "Capture d'écran")
	const nfdCurlyVariant = tryCurlyQuoteVariant(nfdVariant);
	if (nfdCurlyVariant !== resolved && (await pathExists(nfdCurlyVariant))) {
		return nfdCurlyVariant;
	}

	return resolved;
}
