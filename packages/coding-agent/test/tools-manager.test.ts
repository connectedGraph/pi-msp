import { describe, expect, it } from "vitest";
import { ensureTool } from "../src/utils/tools-manager.ts";

describe("ensureTool", () => {
	it("returns no host tool path", async () => {
		const result = await ensureTool("fd");

		expect(result).toBeUndefined();
	});
});
