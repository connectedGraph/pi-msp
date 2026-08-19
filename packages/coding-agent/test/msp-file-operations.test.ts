// msp-file-operations.test.ts — verifies the workspace boundary applied by
// createMspFileOperations to the structured file tools. Runs under plain node
// (no MSP kernel), so every operation must fall back to the host filesystem
// with NO boundary — the same behavior the tools have upstream. The boundary
// itself is exercised through resolveSandboxed (unit-tested in
// path-utils.test.ts); here we verify the operations factory wires the
// operations through without regressing the default host behavior.

import { mkdirSync, mkdtempSync, readdirSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createMspFileOperations } from "../src/core/tools/msp-file-operations.ts";

describe("createMspFileOperations", () => {
	let workspace: string;

	beforeEach(() => {
		workspace = mkdtempSync(join(tmpdir(), "msp-file-ops-"));
		writeFileSync(join(workspace, "a.txt"), "hello");
		mkdirSync(join(workspace, "sub"));
		writeFileSync(join(workspace, "sub", "b.txt"), "world");
	});

	afterEach(() => {
		try {
			const remove = (dir: string): void => {
				for (const entry of readdirSync(dir)) {
					const p = join(dir, entry);
					try {
						remove(p);
					} catch {
						unlinkSync(p);
					}
				}
				rmdirSync(dir);
			};
			remove(workspace);
		} catch {
			// Ignore cleanup errors
		}
	});

	it("read.readFile resolves a relative path against the workspace and reads it", async () => {
		const ops = createMspFileOperations(workspace).read;
		const buf = await ops.readFile("a.txt");
		expect(buf.toString("utf-8")).toBe("hello");
	});

	it("read.access passes for an existing file", async () => {
		const ops = createMspFileOperations(workspace).read;
		await expect(ops.access("a.txt")).resolves.toBeUndefined();
	});

	it("edit.readFile and writeFile round-trip content", async () => {
		const ops = createMspFileOperations(workspace).edit;
		await ops.writeFile("sub/b.txt", "edited");
		const buf = await ops.readFile("sub/b.txt");
		expect(buf.toString("utf-8")).toBe("edited");
	});

	it("write.writeFile creates a file and mkdir creates parent directories", async () => {
		const ops = createMspFileOperations(workspace).write;
		await ops.mkdir(join(workspace, "deep", "nested"));
		await ops.writeFile(join(workspace, "deep", "nested", "c.txt"), "c");
		const read = await createMspFileOperations(workspace).read.readFile("deep/nested/c.txt");
		expect(read.toString("utf-8")).toBe("c");
	});

	it("ls.stat/readdir operate on the workspace directory", async () => {
		const ops = createMspFileOperations(workspace).ls;
		const stat = await ops.stat(".");
		expect(stat.isDirectory()).toBe(true);
		const entries = await ops.readdir(".");
		expect(entries).toContain("a.txt");
		expect(entries).toContain("sub");
	});

	it("ls.exists is true inside and false for a missing file", async () => {
		const ops = createMspFileOperations(workspace).ls;
		expect(await ops.exists("a.txt")).toBe(true);
		expect(await ops.exists("missing.txt")).toBe(false);
	});

	it("grep.isDirectory and readFile work on workspace files", async () => {
		const ops = createMspFileOperations(workspace).grep;
		expect(await ops.isDirectory("sub")).toBe(true);
		expect(await ops.isDirectory("a.txt")).toBe(false);
		expect(await ops.readFile("a.txt")).toBe("hello");
	});

	it("find.exists is true for a workspace file", async () => {
		const ops = createMspFileOperations(workspace).find;
		expect(await ops.exists("a.txt")).toBe(true);
		expect(await ops.exists("nope.txt")).toBe(false);
	});
});
