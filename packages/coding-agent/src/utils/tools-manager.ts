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
	_tool: "fd" | "rg",
	_onStatus?: (status: ToolStatus) => void,
): Promise<string | undefined> {
	// pi-msp: host tool auto-detection/download is removed entirely. The file
	// search commands (rg/find) live inside the MSP sandbox; the grep/find tools
	// route through MSP instead of spawning host binaries. Nothing is downloaded.
	return undefined;
}
