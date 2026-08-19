# msp-kernel — MSP 沙箱内核(pi-shell 的进程内执行内核)

把上游 `nian2026/msp`(ModelShellProxy)的 shell 运行时**打包进 Pi 源码**,编译成 C ABI 共享库
`libMSPKernel.so`,供 pi-shell 通过 **Bun FFI `dlopen` 进程内加载**。命令在 MSP 沙箱虚拟 FS 上执行,
不 spawn 任何外部进程(区别于"Pi 关联启动 msp-shell"的方案)。内核内嵌 CPython,沙箱内
`python`/`python3` 是**拦截层**命令(文件访问走虚拟 FS broker,网络是真实网络)。

## 目录

```
packages/msp-kernel/
├── swift/                         # vendored Swift 包(裁剪自 nian2026/msp)
│   ├── Package.swift              # 裁剪:仅 shell 运行所需的 13 个模块 + MSPKernelShim
│   └── Implementations/Swift/Sources/
│       ├── MSPCore MSPShellLanguage MSPShellExpansion MSPShell
│       ├── MSPCommandKit MSPExternalRunner MSPAgentBridge MSPPOSIXCore
│       ├── MSPApple MSPPtySupport ModelShellProxy
│       ├── MSPPythonRuntime MSPPythonEmbeddedRuntime   # 嵌入式 CPython(拦截层)
│       ├── MSPKernelShim/         # C ABI shim(本仓库新增)
│       └── Tools/MSP/             # MSPAgentBridge 的 exec_command/apply_patch 等
├── build.sh                       # swift build → libMSPKernel.so
├── bundle-python.sh               # 生成自包含 python 运行时 → <deliverable>/python/
└── README.md
```

> 裁剪说明:去掉 MSPGit(swift-cgit2 依赖)、MSPChat、CLI 等;**MSPPythonRuntime +
> MSPPythonEmbeddedRuntime 保留**(2026-08 接入嵌入式 CPython)。上游仓库仍是 canonical,
> 这里只是 pi-shell 构建用的副本。

## C ABI

```c
int  msp_run_json(const char* workspace, const char* command, char** out_json);
void msp_free_json(char* p);
```

`msp_run_json` 以 `workspace` 为沙箱根,执行单条 `command`,把
`{"stdout","stderr","exit_code"}` 写入 `out_json`(malloc,需 `msp_free_json` 释放),返回命令退出码。

## Python 嵌入与捆绑

- shim(`MSPKernelShim`)**全局缓存单个 `MSPCPythonEngine`**(dlopen 一次 + `Py_Initialize` 一次,
  engine 自带 NSLock 串行),每条命令注册 `python`/`python3` 命令。
- libpython 解析顺序:`$MSP_PYTHON_LIB` → `<exe>/python/lib/libpython3.x.so`(捆绑)→ 系统路径。
  pythonHome:`$MSP_PYTHON_HOME` → `<exe>/python`(捆绑根,内含 `lib/python3.x`)。
- 捆绑:`bash bundle-python.sh <deliverable-dir>` → 在二进制旁生成 `python/`(root 布局:
  `lib/libpython3.x.so(.1.0)` + `lib/python3.x/` stdlib)。**宿主无 python 也能跑**。

## 构建

```bash
# WSL Ubuntu(需 Swift 5.9+)
bash packages/msp-kernel/build.sh
# 产物: packages/msp-kernel/swift/.build/release/libMSPKernel.so
# 捆绑(可选,交付时): bash packages/msp-kernel/bundle-python.sh <deliverable-dir>
```

## Pi 侧接入

`packages/coding-agent/src/core/msp-runtime.ts`(`bun:ffi`)加载 `.so` 并暴露 `mspRunJson(workspace, command)`;
`packages/coding-agent/src/core/tools/bash.ts` 的 `createLocalBashOperations` 在内核可用时把 `exec` 改走
`mspRunJson`,并做**动态工作区映射**(agent `cd` 到哪个目录,那条命令的沙箱根就是哪个目录)。

## 已知边界 / 限制

- **命令事务模型:无持久进程、无持久会话。** 嵌入式 python 是**每条命令一个新子解释器**
  (`Py_NewInterpreter` … `Py_EndInterpreter`),命令返回即销毁。因此:
  - 起不了常驻服务:python 里 `bind`/`listen` 挂的端口,命令一结束就没了(实测:运行期间可连,
    结束后 `Connection refused`);
  - 跨命令无状态:全局变量、线程、`sys.modules` 缓存、打开的文件/socket 都不跨命令保留;
  - 想跑长驻服务需新机制(如引擎内保留长命子解释器的后台会话),当前不支持。
- **网络 = 真实网络(全放)**:python 的 socket/urllib 直接走宿主网络栈,DNS/公网 HTTPS 实测通;
  沙箱不建虚拟网段、不拦流量。但 shell 命令层没有 `curl`/`wget`/`ping`(fake POSIX 未注册),
  模型联网只能走 python。
- **无实时流式输出**:FFI 阻塞式,命令结束一次返回;交互式/PTY 命令不支持。
- **pip / C 扩展不承诺**:numpy 等 C 扩展直接调系统 open 会绕开 VFS broker(宿主文件访问风险)。
  v1 只用系统 stdlib。
- **CPython 崩溃同归于尽**:进程内嵌入,python 层段错误会崩整个 pi-shell。
