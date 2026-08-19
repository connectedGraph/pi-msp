// swift-tools-version: 5.9

import PackageDescription

// pi-shell MSP kernel: vendored subset of ModelShellProxy (upstream nian2026/msp).
// Exposes a C ABI (msp_run_json / msp_free_json) so Pi can drive the MSP sandbox
// in-process via Bun FFI (no external msp-shell process). Trimmed to the shell
// runtime only — no MSPGit / MSPChat / swift-cgit2. MSPPythonRuntime +
// MSPPythonEmbeddedRuntime are vendored for the `python3` command pack.

let package = Package(
    name: "MSPKernel",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "MSPKernel", type: .dynamic, targets: ["MSPKernelShim"]),
        .library(name: "MSPPython", targets: ["MSPPythonRuntime", "MSPPythonEmbeddedRuntime"])
    ],
    targets: [
        .target(
            name: "MSPCore",
            path: "Implementations/Swift/Sources/MSPCore"
        ),
        .target(
            name: "MSPShellLanguage",
            path: "Implementations/Swift/Sources/MSPShellLanguage",
            sources: ["AST", "Conversion", "Lexer", "Parsed", "Parser", "Reconstruction", "Syntax", "Values"]
        ),
        .target(
            name: "MSPShellExpansion",
            dependencies: ["MSPShellLanguage"],
            path: "Implementations/Swift/Sources/MSPShellExpansion",
            sources: ["API", "Arithmetic", "Brace", "Effects", "FieldSplitting", "Parameters", "Pattern", "Words"]
        ),
        .target(
            name: "MSPShell",
            dependencies: ["MSPShellLanguage", "MSPShellExpansion"],
            path: "Implementations/Swift/Sources/MSPShell"
        ),
        .target(
            name: "MSPCommandKit",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPCommandKit"
        ),
        .target(
            name: "MSPExternalRunner",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPExternalRunner"
        ),
        .target(
            name: "MSPAgentBridge",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources",
            sources: [
                "MSPAgentBridge/Capabilities",
                "MSPAgentBridge/Compaction",
                "MSPAgentBridge/JSON",
                "MSPAgentBridge/Model",
                "MSPAgentBridge/Model/ResponsesStreaming",
                "MSPAgentBridge/Rendering",
                "MSPAgentBridge/Request",
                "MSPAgentBridge/Runtime",
                "Tools/MSP/exec_command/Contract",
                "Tools/MSP/exec_command/Runtime",
                "Tools/MSP/apply_patch/Contract",
                "Tools/MSP/apply_patch/Runtime",
                "Tools/MSP/write_stdin/Contract",
                "Tools/MSP/write_stdin/Runtime",
                "Tools/MSP/update_plan/Contract",
                "Tools/MSP/update_plan/Runtime"
            ]
        ),
        .target(
            name: "MSPPythonRuntime",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPPythonRuntime"
        ),
        .target(
            name: "MSPPythonEmbeddedRuntime",
            dependencies: ["MSPCore", "MSPPythonRuntime"],
            path: "Implementations/Swift/Sources/MSPPythonEmbeddedRuntime"
        ),
        .target(
            name: "MSPPOSIXCore",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPPOSIXCore",
            sources: ["Commands", "Registry", "Support"]
        ),
        .target(
            name: "MSPApple",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPApple"
        ),
        .target(
            name: "MSPPtySupport",
            path: "Implementations/Swift/Sources/MSPPtySupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ModelShellProxy",
            dependencies: [
                "MSPCore",
                "MSPShell",
                "MSPCommandKit",
                "MSPExternalRunner",
                "MSPAgentBridge",
                "MSPPOSIXCore",
                "MSPApple",
                "MSPPtySupport"
            ],
            path: "Implementations/Swift/Sources/ModelShellProxy"
        ),
        .target(
            name: "MSPKernelShim",
            dependencies: ["ModelShellProxy", "MSPPythonEmbeddedRuntime"],
            path: "Implementations/Swift/Sources/MSPKernelShim"
        )
    ]
)
