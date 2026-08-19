import Foundation
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

// In-process C ABI bridge between Pi (Bun FFI) and the MSP sandbox kernel.
//
//   int  msp_run_json(const char* workspace, const char* command, char** out_json)
//   void msp_free_json(char* p)
//
// Mirrors `msp-shell --json`: runs one command in a fresh ModelShellProxy rooted
// at `workspace` and returns {"stdout","stderr","exit_code"} as a malloc'd C
// string (caller must free with msp_free_json). Returns the command exit code.

private final class MSPKernelResultBox: @unchecked Sendable {
    var exitCode: Int32 = 2
    var json = ""
}

private struct MSPKernelJSONResult: Encodable {
    let stdout: String
    let stderr: String
    let exit_code: Int32
    // MSP's own post-command state: authoritative sandbox cwd (virtual path,
    // e.g. "/" or "/sub"), from MSPCommandRuntimeStateChange.
    let cwd: String?
}

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private func encodeResult(_ stdout: String, _ stderr: String, _ exitCode: Int32, cwd: String?) -> String {
    let payload = MSPKernelJSONResult(stdout: stdout, stderr: stderr, exit_code: exitCode, cwd: cwd)
    guard let data = try? jsonEncoder.encode(payload) else {
        return "{\"stdout\":\"\",\"stderr\":\"msp-kernel: json encode failed\",\"exit_code\":2}"
    }
    return String(decoding: data, as: UTF8.self)
}

// Embedded CPython engine cache.
//
// dlopen + Py_Initialize are expensive and process-global, so we create the
// engine ONCE and reuse it across every command (the engine serializes runs
// with its own NSLock and creates a fresh sub-interpreter per run). Per-command
// engine creation would re-dlopen libpython on every bash tool call.
//
// libpython resolution order (first match wins):
//   1. $MSP_PYTHON_LIB      — explicit path
//   2. <exe>/python/lib/libpython3.14.so — bundled alongside pi-shell (P3)
//   3. system libpython3.14.so — /usr/lib/x86_64-linux-gnu, then /usr/lib
// pythonHome resolution order:
//   1. $MSP_PYTHON_HOME     — explicit stdlib root
//   2. <exe>/python — bundled root (its lib/python3.14 is the stdlib)
private let pythonEngineCreationLock = NSLock()
private var cachedPythonEngine: MSPCPythonEngine?

private func executableDirectoryURL() -> URL? {
    guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else {
        return nil
    }
    let path = argv0.hasPrefix("/") ? argv0 : FileManager.default.currentDirectoryPath + "/" + argv0
    return URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
}

private func bundledPythonDirectoryURL() -> URL? {
    executableDirectoryURL()?.appendingPathComponent("python", isDirectory: true)
}

private func resolvePythonLibrary() -> MSPCPythonLibrary {
    let environment = ProcessInfo.processInfo.environment
    if let value = environment["MSP_PYTHON_LIB"], !value.isEmpty {
        return .path(URL(fileURLWithPath: value))
    }
    if let bundled = bundledPythonDirectoryURL()?
        .appendingPathComponent("lib", isDirectory: true)
        .appendingPathComponent("libpython3.14.so"),
       FileManager.default.fileExists(atPath: bundled.path) {
        return .path(bundled)
    }
    for candidate in [
        "/usr/lib/x86_64-linux-gnu/libpython3.14.so",
        "/usr/lib/libpython3.14.so",
        "/usr/lib/x86_64-linux-gnu/libpython3.14.so.1.0",
    ] {
        if FileManager.default.fileExists(atPath: candidate) {
            return .path(URL(fileURLWithPath: candidate))
        }
    }
    // Let the engine report a precise error when python is actually invoked.
    return .path(URL(fileURLWithPath: "/usr/lib/x86_64-linux-gnu/libpython3.14.so"))
}

private func resolvePythonHomeURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let value = environment["MSP_PYTHON_HOME"], !value.isEmpty {
        return URL(fileURLWithPath: value)
    }
    if let bundled = bundledPythonDirectoryURL()?.appendingPathComponent("lib", isDirectory: true),
       FileManager.default.fileExists(atPath: bundled.appendingPathComponent("python3.14", isDirectory: true).path) {
        // Home is the bundle ROOT; CPython's getpath needs <home>/lib/python3.14.
        return bundled.deletingLastPathComponent()
    }
    return nil
}

/// Globally cached MS-Python engine, created lazily under a lock so concurrent
/// commands dlopen libpython exactly once. Absent libpython → throws; callers
/// treat python as optional.
private func resolvedPythonEngine() throws -> MSPCPythonEngine {
    pythonEngineCreationLock.lock()
    defer { pythonEngineCreationLock.unlock() }
    if let cachedPythonEngine {
        return cachedPythonEngine
    }
    let engine = try MSPCPythonEngine(
        library: resolvePythonLibrary(),
        pythonHomeURL: resolvePythonHomeURL()
    )
    cachedPythonEngine = engine
    return engine
}

@_cdecl("msp_run_json")
public func mspRunJSON(
    _ workspace: UnsafePointer<CChar>?,
    _ command: UnsafePointer<CChar>?,
    _ outJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let workspace, let command, let outJSON else {
        return 2
    }
    let workspacePath = String(cString: workspace)
    let commandString = String(cString: command)

    let box = MSPKernelResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        do {
            let workspaceURL = URL(fileURLWithPath: workspacePath)
            let workspaceObject = try MSPAppleWorkspace(rootURL: workspaceURL)
            let proxy = ModelShellProxy(configuration: MSPConfiguration(workspace: workspaceObject))
            _ = try proxy.enable(.posixCore)
            // Python is optional: if libpython can't be loaded the sandbox still
            // works, `python`/`python3` just stay unregistered and the shell
            // reports "command not found".
            if let engine = try? resolvedPythonEngine() {
                _ = try proxy.enable(
                    MSPPythonCommandPack(runtime: MSPPythonEmbeddedRuntime(engine: engine))
                )
            }
            // MSP's own agent feedback path: the exec_command bridge
            // (MSPExecCommandBridge / MSPCommandResult). The JSON below is only
            // the FFI marshaling envelope; the fields are MSP's native result.
            let bridge = proxy.execCommandBridge()
            let call = MSPExecCommandCall(cmd: commandString)
            let result = await bridge.run(call)
            box.exitCode = result.exitCode
            box.json = encodeResult(
                String(decoding: result.stdoutData, as: UTF8.self),
                String(decoding: result.stderrData, as: UTF8.self),
                result.exitCode,
                cwd: result.stateChange?.currentDirectory
            )
        } catch {
            box.exitCode = 2
            let message = "\(error)"
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            box.json = "{\"stdout\":\"\",\"stderr\":\"msp-kernel: \(message)\",\"exit_code\":2}"
        }
    }
    semaphore.wait()

    box.json.withCString { buffer in
        outJSON.pointee = strdup(buffer)
    }
    return box.exitCode
}

@_cdecl("msp_free_json")
public func mspFreeJSON(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
