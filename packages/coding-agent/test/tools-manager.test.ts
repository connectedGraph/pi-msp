import type * as ChildProcess from "node:child_process";
import { spawnSync } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import { ensureTool } from "../src/utils/tools-manager.ts";

vi.mock("node:child_process", async (importOriginal) => {
	const actual = await importOriginal<typeof ChildProcess>();
	return {
		...actual,
		spawnSync: vi.fn(),
	};
});

function spawnResult(error?: Error): ReturnType<typeof spawnSync> {
	const output = Buffer.alloc(0);
	return {
		pid: 0,
		output: [null, output, output],
		stdout: output,
		stderr: output,
		status: error ? 127 : 0,
		signal: null,
		error,
	};
}

describe("ensureTool", () => {
	it("returns the command when the host already provides it", async () => {
		vi.mocked(spawnSync).mockReturnValue(spawnResult());

		await expect(ensureTool("fd")).resolves.toBe("fd");
	});

	it("returns undefined when the command is unavailable", async () => {
		vi.mocked(spawnSync).mockReturnValue(spawnResult(new Error("not found")));

		await expect(ensureTool("rg")).resolves.toBeUndefined();
	});
});
