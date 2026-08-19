# MSP 设计说明:一切皆命令的模型操作系统,与普通沙箱的本质区别

> 基于上游 `nian2026/msp`(Model Shell Protocol)的定位与 pi-msp 的实践整理。
> 本文回答三个问题:MSP 的"一切皆命令"是什么?它和普通沙箱区别在哪?
> 为什么 read/write 工具可以(或不可以)被扔掉?

---

## 一、上游的定位:不是又一个沙箱,是应用的"操作系统语义层"

上游 README 的原话:

> MSP is the operating-system semantics layer inside an application: a runtime
> that turns app data, platform permissions, domain objects, user artifacts,
> external services, and product-specific actions into files, commands, streams,
> scripts, policies, and audit records that a model can operate on.
>
> That is why MSP is not a wrapper around `/bin/sh`. It is the
> operating-system semantics layer inside the app.

四句核心论断:

| 论断 | 含义 |
| :-- | :-- |
| 数据即文件 | 应用的数据/领域对象被**投影**成工作区里的文件 |
| 动作即命令 | 对数据的操作被**注册**成命令,模型用命令表达意图 |
| 权限即策略 | 不是宿主权限位,是应用自己的**策略引擎** |
| 执行即证据 | 每次执行留下**审计记录**,是模型行为的证据 |

关键:它**不是** `/bin/sh` 的包装,而是把 Unix 的"一切皆文件"推广到 AI 原生软件——
模型面对一个统一命令接口(一个 bash 工具),而不是一堆工具 schema。

## 二、一个核心洞察:可注册命令的沙箱,单命令接口

把上游的设计和实践中得到的理解合成一句话:

> **MSP 是一个"单命令接口 + 可注册命令"的模型操作环境。**
> 它收敛所有工具调用到一个 bash 工具,命令命名空间 = 应用注册的能力面。

这个形态很像"只给一个 tool search 工具的进阶版",面向的场景是:

- **有工作环境**:应用给模型一个 workspace(数据投影成 FS),模型有东西可操作;
- **不允许真实 bash**:app 内部 / 多租户 / 员工权限环境,不能暴露 `/bin/sh` 给模型;
- **不想暴露 read/write 文件工具**:按文件粒度给工具权限又碎又麻烦,策略和审计都散;
- **想要可注册能力**:app 把领域动作注册成命令(如 `sort_photos`、`update_crm_record`),
  模型用统一的命令语法调用,而不是每次新加一个工具 schema。

好处:模型侧工具面从"N 个工具"收敛到"1 个 bash 工具";应用侧所有能力、
权限、审计都收敛到一个策略/审计点。

## 三、MSP 沙箱 vs 普通沙箱:本质区别

| 维度 | 普通沙箱(Docker / bubblewrap / gVisor / Firecracker) | MSP 沙箱 |
| :-- | :-- | :-- |
| 隔离机制 | **OS 级**:命名空间 / cgroup / seccomp / VM | **语义级**:虚拟 FS 投影 + 策略引擎 |
| 跑的是什么 | **真实二进制**(ls、git、node……) | **注册的命令实现**(117 个重写 fake POSIX + 领域命令),无真实进程 |
| 文件系统 | 真实 FS(或挂载的) | **工作区投影**:根 = 应用给定的目录/数据;工作区外路径"不存在" |
| 命令来源 | 真实 PATH | 命令注册表(应用可注册) |
| 隔离方式 | 权限位 / 沙箱规则 → Permission denied | 路径不存在 → No such file or directory |
| 可扩展 | 装软件/二进制 | 注册命令(领域对象直通,无需 CLI 约定) |
| 策略/审计 | 系统权限 / 外部审计 | 应用策略引擎 + 内建审计记录 |
| 设计目的 | **安全运行不可信代码** | **给模型一个应用拥有的安全操作环境** |

一句话:**普通沙箱把"不可信的东西"关起来;MSP 把"可信的东西"造出来。**

- 普通沙箱的隔离是**防御性**的:真实代码真实跑,靠 OS 边界挡住越权。
- MSP 的隔离是**构造性**的:模型能操作的,是应用刻意投影出来的那一小块;
  应用没投影的,对模型来说**根本不存在**,谈不上越权。
  所以 MSP 不需要 OS 级防御,它从根上就是"应用说了算"。

两者也有关联:MSP 的宿主桥接层(`MSPHostProcessExternalRunner`,上游已写好未接线)
就是在 MSP 语义沙箱里**拉真实二进制**(git/node/python)跑,属于"把普通沙箱的
能力借进来,但路径仍经 MSP 虚拟化 + sanitize"。

## 四、read/write 工具的去留:为什么"扔了"是有道理的,但编码是真实的坎

上游的"一切皆命令"主张:读写文件也走 shell(`cat` / `echo` / 重定向 / `apply_patch`),
不需要单独的 read_file / write_file 工具。这在 MSP 内部是成立的——
`cat`/`echo`/`> file` 都是注册命令,策略和审计天然覆盖。

**但"把 read/write 工具扔掉"有一个真实的坎:编码。**

- 文本:cat/echo/重定向没问题;
- **二进制 / 非 UTF-8**:MSP 的 `cat` 走 UTF-8 文本通道,直接 `cat` 二进制会乱;
  需要 base64 中间层(`base64` 是内建命令),或按 mimeType 结构化读取;
- 编辑大文件 / 精确补丁:shell 的 `sed`/`apply_patch` 可以,但按行语义、
  上下文 diff 比专用编辑工具脆弱。

所以取舍不是"扔 vs 不扔",而是:

1. **纯命令面**(上游主张):工具面 = 1 个 bash,读写全走 shell;
   代价是编码/编辑精度需要命令层补(apply_patch、base64)。
2. **混合面**(pi-msp 现状):bash 走 MSP 沙箱,read/edit/write 仍是 pi 的宿主工具
   (真实 FS,和沙箱同根,一致)。模型有更稳的读写通道,但工具面不是 1 个。
3. **收敛面**(可能的方向):保留极少数结构化工具(read 支持 mimeType/base64),
   其余全收敛到命令。

## 五、pi-msp 现状与后续

**现状**
- bash 执行 → MSP 内核(`mspRunJson`,进程内 FFI),工作区虚拟 FS,路径隔离;
- **文件工具已带工作区边界**(2026-08):read/edit/write/ls 经 `msp-file-operations.ts`
  注入 `createAllToolDefinitions` 的 operations 层,路径先过 `resolveSandboxed`
  (canonicalize symlink + 判工作区前缀),出界即 `Path not found`——与 bash 的
  `No such file or directory` 语义对齐。I/O 通道不变(仍宿主 fs/promises Buffer),
  二进制/图像/截断/diff 不受影响。**池子层注入,coding 与只读模式共用**:
  `_buildRuntime` 一次构造全部工具 definitions(含 operations),激活集
  (`activeToolNames`)决定启用哪些——所以只读模式激活的 read/ls 同样带边界;
- grep/find **未注入边界**(当前不可用:宿主 rg/fd 被收回,`ensureTool` 返回 undefined,
  grep/find 到不了 operations 直接 reject);只读搜索由 agent 用 bash 的 `rg`/`find`
  走 MSP 内核兜底。**rg/fd 属只读模式功能,收回疑似误操作,后续可恢复**;
- MSP 内核:117 个 fake POSIX 命令 + 虚拟 FS + 动态工作区映射;
- 内嵌 CPython:`python`/`python3` 是**拦截层**命令(文件走虚拟 FS broker、网络是真网络),
  libpython + stdlib 自捆绑在交付目录,宿主无 python 也能跑。

**已知边界(命令事务模型)**
- **无持久进程 / 无持久会话。** 嵌入式 python 每条命令一个新子解释器
  (`Py_NewInterpreter` … `Py_EndInterpreter`),命令返回即销毁。**起不了常驻服务**:
  脚本里 `bind`/`listen` 挂的端口命令一结束就没了(实测:运行期间可连,结束后
  `Connection refused`);全局变量/线程/模块缓存也不跨命令保留。
- **网络 = 真实网络(全放)**:不建虚拟网段、不拦流量;但 shell 命令层没有
  `curl`/`wget`/`ping`(fake POSIX 未注册),模型联网只能走 python。
- **无实时流式输出**(FFI 阻塞式);**pip / C 扩展不承诺**(C 扩展绕 VFS broker,有宿主访问风险)。
- **exec 默认 yield 10 秒 + 输出截断丢失**。MSP 命令执行按
  `MSPExecCommandYieldPolicy.defaultExecYieldTimeMilliseconds = 10_000` 等命令完成,
  到点即 `consumeRead` 拿走**当前已收集的输出**;后台命令线程仍继续跑,但结果不再回来。
  表现为:慢命令**恰好 10s 整返回、stdout 为空、副作用保留**(如 `find /` 全盘遍历、
  python 写文件)。这是"FFI 阻塞不可中断"在命令级的根因——TS 侧超时/abort 只能丢结果,
  **杀不掉内核里正在跑的命令**。
- **虚拟 FS 跨 VM 慢**:投影源是 `/mnt/d`(Windows 盘,9p/DRVFS),**每个 readdir/stat 都跨
  Linux↔Windows VM 边界**,单个 stat 毫秒级。monorepo 级 node_modules 数万文件,`find /`
  全盘遍历必然撞 10s。**重 I/O 搜索(全盘 find/os.walk)不该走内核**。

**待修(2026-08 实测发现,按影响排序)**
1. **exec 10s 截断返回空输出**(真实 bug):慢命令(全盘 find、重 python)到 10s yield 被
   `consumeRead` 截断,stdout 为空、rc=0、副作用保留——对模型表现为"命令无输出却已执行"。
   修法二选一或都做:
   a) 截断时**保留已收集的部分输出**(find 目前是攒完才写,应改成流式写或截断回传已收集部分);
   b) 调大/可配 `execYieldTimeMilliseconds`(默认 10s 面向快命令,`mspRunJson` 调用方可传)。
2. **跨 VM 慢**:虚拟 FS stat 毫秒级,全盘遍历必撞上限。修法:内核给 VFS 加**目录/文件数量
   投影上限**或**浅层优先**,或对 `/mnt/d` 走批量 stat;否则重 I/O 搜索只能走宿主 rg/fd
   (见"可能的后续 2")。

**可能的后续(按价值排序)**
1. **宿主桥接**:接 `MSPHostProcessExternalRunner`,让 git/node/npm 在 MSP 沙箱里
   以真实进程跑(路径虚拟化 + 输出 sanitize)——这是"继续桥接"的主线;
2. **只读搜索工具**:grep/find/ls 是只读模式功能,不是完全访问模式。rg/fd 被收回疑似
   误操作,**后续可恢复下载**;但更彻底的方向是**用 MSP bash 的 `rg`/`find`/`ls`
   命令替代宿主 rg/fd 工具**——命令面统一、天然带工作区边界,无需宿主二进制。
   **但 2026-08 实测发现反例**:内核 `find /` 因 10s yield + 跨 VM 慢会截断返回空输出,
   而宿主 rg/fd 无此上限、直跑到底。故**重 I/O 搜索该走宿主工具**;若坚持命令面统一,
   需先解内核的跨 VM 慢与 10s 截断(见已知边界)。若走宿主 rg/fd,可评估 drop
   grep/find/ls 工具本体(只保留 read);
3. **收敛工具面**:评估是否 drop read/edit/write,或保留 read 但走 mimeType/base64;
4. **注册领域命令**:在 MSP 内核注册应用专属命令,把"一切皆命令"做实;
5. **流式输出**:FFI 阻塞式改流式,让长命令不冻结 TUI。

---

*本文为 pi-msp 项目的设计理解文档,不代表上游 nian2026/msp 的官方立场。*
