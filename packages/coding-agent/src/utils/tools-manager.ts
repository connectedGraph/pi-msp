import { spawnSync } from "child_process";

export interface ToolStatus {
	type: "info" | "warning";
	message: string;
}

/**
 * Ensure a tool is available, downloading if necessary.
 * Reports progress through `onStatus`; status messages are otherwise silent.
 * Returns the tool path, or undefined if unavailable.
 */
export async function ensureTool(
	tool: "fd" | "rg",
	_onStatus?: (status: ToolStatus) => void,
): Promise<string | undefined> {
	// pi-msp keeps search binaries outside its release payload. Use a command
	// only when the host already provides it; never download or install one.
	const command = tool === "fd" ? "fd" : "rg";
	const result = spawnSync(command, ["--version"], { stdio: "pipe" });
	return result.error === null || result.error === undefined ? command : undefined;
}
