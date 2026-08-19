# pi-msp — 模型操作系统沙箱里的 pi

pi-msp 把 [pi](https://github.com/connectedGraph/pi)（本地 AI 模型驱动的 coding agent）装进一个**进程内 MSP 沙箱内核**，让模型看到的是一个"应用拥有的操作系统语义层"，而不是宿主机器的真实文件系统。

它解决的问题：编码 agent 通常让模型自由使用 `read`/`edit`/`bash` 等工具——bash 能跑到宿主任意目录、读写任意文件。pi-msp 把命令执行收敛到 MSP 虚拟 FS，工作区外对模型来说**不存在**；同时保留 pi 结构化工具的智能（截断、diff、图像处理）。

> 内核基于上游 [nian2026/msp](https://github.com/nian2026/msp)（Model Shell Protocol）裁剪编译。本文档只描述 pi-msp 的做法，不代表上游立场。

## 它是什么

一句话：

> **MSP 是一个"单命令接口 + 可注册命令"的模型操作环境。** 它收敛工具调用到一个 bash 工具，命令命名空间 = 应用注册的能力面。

- **数据即文件** — 应用的工作目录被投影成虚拟 FS 的根 `/`。
- **动作即命令** — 模型用命令表达意图，命令是注册的（fake POSIX + 领域命令），不是真实二进制。
- **权限即策略** — 工作区外的路径"不存在"，谈不上越权。
- **执行即证据** — 每次命令执行都过内核，策略与审计收敛到单点。

## 架构

```
+--------------------------------------------------------------+
| pi-msp (bun 编译的 standalone 二进制)                          |
|   coding-agent: read/edit/write/ls/grep/find + bash 工具       |
|     └─ read/edit/write/ls 工具 → msp-file-operations.ts       │
|          └─ resolveSandboxed: 路径出工作区 → "Path not found"  │
|     └─ bash 工具 → msp-runtime.ts (bun:ffi dlopen)            │
|          └─ mspRunJson(workspace, command)                    │
+----------------------------+---------------------------------+
                             │ 进程内 FFI（无外部进程）
+----------------------------v---------------------------------+
| libMSPKernel.so (Swift 编译, packages/msp-kernel)             |
|   MSPAppleWorkspace(rootURL: workspace) → 虚拟 FS, 根 = /     |
|   .posixCore: 117 个 fake POSIX 命令 (ls/find/rg/cat/...)    |
|   MSPPythonCommandPack: 嵌入式 CPython (python3 拦截层)        |
+--------------------------------------------------------------+
```

- **bash 工具**：命令进 `mspRunJson`，在内核虚拟 FS 上执行。内核把传入的 `workspace` 目录映射成根 `/`——GNU 命令和 Python 共享同一个映射。工作区外路径 `cat /etc/passwd` 返回 `No such file or directory`。
- **read/edit/write/ls 工具**：仍是 pi 宿主工具（fs/promises Buffer，二进制/图像/截断/diff 不受影响），但路径先过 `resolveSandboxed`（canonicalize symlink + 判工作区前缀），出界抛 `Path not found`。与 bash 的沙箱边界一致。
- **grep/find 工具**：宿主 rg/fd 不再下载（搜索在沙箱内经 bash 的 `rg`/`find` 兜底）。
- **提示词虚拟化**：MSP 环境里 `Current working directory: /`，与模型在 bash 里 `pwd` 看到的根一致，不暴露真实宿主路径。

## 构建

前置：WSL Ubuntu + Swift 5.9+、Bun、Node 22+。

```bash
# 1. 编 MSP 内核（Swift → libMSPKernel.so）
bash packages/msp-kernel/build.sh

# 2. 编 workspace 包 + coding-agent
npm install --ignore-scripts
npm run build

# 3. 编 pi-msp standalone 二进制（bun compile）
cd packages/coding-agent
bun build --compile --no-compile-autoload-bunfig \
  ./dist/bun/cli.js ./src/utils/image-resize-worker.ts \
  --outfile dist/pi-msp
cp ../msp-kernel/swift/.build/*/libMSPKernel.so dist/

# 4. 捆绑 CPython（宿主无 python 也能跑）
bash ../msp-kernel/bundle-python.sh dist
```

交付物（自包含，拷走即用）：

```
dist/
├── pi-msp              # bun 编译二进制
├── libMSPKernel.so     # MSP 内核
└── python/             # 捆绑 CPython (libpython + stdlib)
```

## 安装

```bash
bash scripts/install-pi-msp.sh
# → 装到 ~/.pi-msp，软链 ~/.local/bin/pi-msp
# 自定义：--prefix <dir> --bin-dir <dir> --from <source-dir>
```

## 使用

从任意目录启动，该目录自动成为沙箱根：

```bash
cd ~/my-project
pi-msp
```

- 模型 `pwd` → `/`；`cat /etc/passwd` → `No such file or directory`。
- `read /etc/passwd` → `Path not found`（工具边界）。
- python 在沙箱内可跑，文件访问走虚拟 FS broker，网络是真实网络。

## 已知边界

- **无持久进程 / 无持久会话**：嵌入式 python 每条命令一个新子解释器，命令返回即销毁。起不了常驻服务，跨命令无状态。
- **网络 = 真实网络（全放）**：不建虚拟网段；shell 命令层无 curl/wget/ping，模型联网走 python。
- **exec 默认 yield 10s**：慢命令到点截断，**输出丢失但副作用保留**（FFI 阻塞式，TS 侧超时杀不掉内核里正在跑的命令）。全盘 `find /` 在跨 VM 的 `/mnt/d` 上必撞此限。
- **无实时流式输出**：FFI 阻塞式。
- **pip / C 扩展不承诺**：C 扩展绕 VFS broker，有宿主访问风险。

## 许可证

MIT。pi 部分源自 [earendil-works/pi](https://github.com/earendil-works/pi)，MSP 内核源自 [nian2026/msp](https://github.com/nian2026/msp)。
