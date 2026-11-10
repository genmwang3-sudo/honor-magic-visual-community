# PR：feat(memory) 纯净自然引擎低内存治理移植

> 状态：已直接推送到 `main`，HEAD = `b93e766bfe8b2b42b918f36164cc132108a18b35`。
> 本文件是配套审阅说明（PR body），便于在 GitHub 新建 PR 或做代码评审时直接粘贴。

## 标题

```
feat(memory): port pure natural memory governance
```

## 摘要

把官方 MagicAnimation 的低内存机制按来源证据移植到社区版，并接上可复现的运行时对照。核心分四层：自有进程 Working Set 裁剪（P0）、系统内存列表清理（P1）、自有进程冻结/恢复（P2）、服务/迁移策略与 dry-run 计划（P3/P4）。所有主动功能默认 opt-in；P3/P4 不执行服务停启、驱动、第三方进程动作、Junction 或用户目录迁移。

## 背景与依据

官方样本 `MagicAnimation_2IN1_Setup_10.0.0.60(C233HONORSP1).exe` 经 REA 与静态分析确认：

- `MagicTaskbar.Shared.dll` 的 `AppRuntimeCoordinator` 用阈值 + 定时器对自有进程调用 `K32EmptyWorkingSet` / `SetProcessWorkingSetSize(-1,-1)`，并配合 `GC.Collect`。
- `MagicSpaceTurbo.exe::MemoryManager::ClearMemory` 动态解析 `NtSetSystemInformation`，`SystemMemoryListInformation = 0x50`，命令 `4 = MemoryPurgeStandbyList`、`2 = MemoryEmptyWorkingSets`，前置 `SeIncreaseQuotaPrivilege`、`SeProfileSingleProcessPrivilege`；`0xC0000061 = STATUS_PRIVILEGE_NOT_HELD`。
- Win11 进程冻结使用 `NtCreateProcessStateChange` / `NtChangeProcessState`。
- 服务、驱动黑名单、C 盘 Junction 迁移属于更高权限组件。

社区版按「可逆、最小可观测、自有进程优先」原则实现，不复制官方的停服务、内核驱动与第三方进程终止。

## 改动

### P0 自有进程 Working Set 裁剪（默认开启，正常启动路径自动运行）

- `src/MagicCommunity/PureNaturalEngine.cs`：深模块。启动 8/12/20/30/45/120 秒检查、周期 5 分钟、桌面交互后 12 秒检查；阈值 64/120/96 MiB；两次成功裁剪最小间隔 120 秒；节电模式暂停；`GC.Collect(Optimized)` → `K32EmptyWorkingSet` → 失败回退 `SetProcessWorkingSetSize`；日志 `pure_natural_started / trim / skip`。
- `Program.cs`：`using var pureNatural = PureNaturalEngine.Start(controller)`，桌面接管后 `RequestInteractionTrim()`。
- `CommunityPreferences.cs` / `CommunitySettingsWindow.cs`：`WorkingSetTrim` 开关（默认 true），省电页可见；`MAGICCOMMUNITY_DISABLE_WORKING_SET_TRIM=1` 环境变量关闭。
- `PureNaturalTests.cs`：10 项策略/失败恢复/禁用/Win32 API/默认配置测试。

### P1 系统内存列表清理（显式入口，默认关闭）

- `src/system-native/memory-governor.cpp/.h`：`MemoryGovernor::Clean`，`confirmed=true` 才执行；启用两个特权、`GlobalMemoryStatusEx` 前后采样、命令 4/2、NTSTATUS、`0xC0000061` 结构化回执。
- `src/MagicCommunity/PureNaturalDiagnostics.cs`：C# 侧同口径实现与 `--pure-natural-runtime-test`，可选 `--native-backend <MagicSystemNative.exe>` 走命名管道。

### P2 自有进程冻结/恢复（显式入口，默认关闭）

- `MemoryGovernor::Freeze / Resume / ResumeAll`：只接受直接子进程，核验父进程句柄绑定、完整镜像路径、创建时间 FILETIME、会话；Win11 state-change 优先，`NtSuspendProcess` / `NtResumeProcess` 回退；断开订阅时 `ResumeAll()`。
- `main.cpp`：`memory-health / memory-clean / process-freeze / process-resume` 仅在普通控制通道，Endpoint 共享一个 governor；`urgent/event/device` 通道拒绝。

### P3/P4 策略与只读执行面（dry-run）

- `PureNaturalConfig.cs`：`Magic.PureNatural.Policy/1`，默认全关、`mode=dry-run`，未知键/体积/边界校验；`Plan()` 只产出服务状态与迁移计划，不执行动作。
- `PureNaturalDiagnostics.cs`：`sc.exe query` 只读服务状态、用户目录 bounded 枚举、C 盘容量、迁移步骤清单。

### 测试、构建与采样

- `Program.cs`：`--pure-natural-test` / `--pure-natural-config-test` / `--pure-natural-runtime-test`。
- `tools/dev/check-worktree.ps1`：纳入 `pure-natural-config-test`。
- `tools/dev/check-native-system.ps1`：新增 `-Integrated` 开关透传。
- `tools/p0/measure_process_group.py`：根进程名白名单扩展到 `MagicCommunity / MagicSystemNative / MagicNativeEntry / MagicCompositionHost`。
- `tools/dev/run-pure-natural-elevated.ps1`：高完整性上下文复跑脚本。
- `docs/pure-natural-engine.md`：设计、实测、命令、未验证项。

## 行为边界（重要）

| 层 | 接入方式 | 默认 | 生效条件 |
| --- | --- | --- | --- |
| P0 | 正常启动自动 | 开 | 无 |
| P1 | CLI / 命名管道显式 | 关 | 高完整性令牌且两个特权可启用 |
| P2 | 命名管道显式 | 关 | 仅社区版直接子进程 |
| P3/P4 | 配置 + dry-run 计划 | 关 | 不执行写操作 |

P1/P2 已实现并通过端到端运行验证，但**未接入 live desktop 的自动定时调度**；P3/P4 保持只读计划。这与官方「安装后自动停服务/驱动」不是同一自动化级别。

## 验证

```powershell
pwsh -NoProfile -File tools/dev/check-worktree.ps1
pwsh -NoProfile -File tools/dev/check-native-system.ps1 -Integrated
& tools/dotnet/dotnet.exe artifacts/pure-natural-publish/MagicCommunity.dll --root . --pure-natural-runtime-test --report artifacts/pure-natural-runtime-final-medium.json --native-backend artifacts/native-system/20261109-191954/MagicSystemNative.exe
pwsh -NoProfile -File tools/dev/run-pure-natural-elevated.ps1 -NativeBackend artifacts/native-system/20261109-191954/MagicSystemNative.exe
git -c core.whitespace=cr-at-eol diff --check
```

| 项 | 结果 |
| --- | --- |
| `check-worktree.ps1` | `exitCode=0`，8 项 `allPass=true`，stderr 空 |
| `check-native-system.ps1 -Integrated` | `exitCode=0`，`allPass=true`，207 项检查，`build.log` 无 `error C` |
| C# publish | `exitCode=0`，保留既有 `CompositionDesktopRuntime.cs:538 CS4014` warning |
| native backend | `MagicSystemNative.exe` SHA-256 `9865BA92128F68A0322510992F0995462D52294F2E003EE59037CD55764FDCEE`，构建 `exitCode=0` |
| 中完整性 runtime | `exitCode=0`，`allPass=true`；P0/P2 有效，P1 = `0xC0000061` |
| 高完整性 runtime | `exitCode=0`，`allPass=true`；P0/P1/P2 有效 |
| `diff --check` | `exitCode=0` |

## 实测内存对照

物理内存 31.29 GiB。

- 高完整性复跑：可用 22.46 → 25.50 GiB（+3.05 GiB），负载 28% → 18%。
- P1 单段：命令 4/2 均 `0x00000000`，可用 +1.50 GiB；native backend 另测得 +423.0 MiB。
- P0：384 MiB 夹具后 Working Set 降 30.8 MiB；Private Bytes / Commit 基本不变，`PageFaultCount` 上升（存在后续软缺页回读代价）。
- P2：state-change 与 `NtSuspendProcess` fallback 两条路径冻结/恢复成功，冻结窗口 CPU 增量 0 ms，恢复后子进程存活。
- 进程组只读采样：`MagicCommunity.exe / MagicSystemNative.exe / MagicNativeEntry.exe` 3 样本全部 complete；Working Set 合计约 36.53 → 36.56 MiB，Private Bytes 约 288.8 MiB。
- 中完整性下 P1 返回 `STATUS_PRIVILEGE_NOT_HELD` 为已验证事实，不把普通波动算作 P1 成功。

用户观察到「约 16G → 约 10G」与方向一致，但缺少同口径连续基准，且 P1 是系统级动作；本 PR 不把全部差额归因到社区版自动链路。

## 回滚

- 关闭 P0：设置 `MAGICCOMMUNITY_DISABLE_WORKING_SET_TRIM=1`，或在省电页关闭「工作集整理」。
- P1/P2 默认不启用，且不在启动路径自动执行。
- 整体回退：`git revert b93e766bfe8b2b42b918f36164cc132108a18b35`。
- P3/P4 未产生服务、注册表、用户目录或 Junction 写入，无需回滚。

## 未验证项 / 残留风险

- 不同 Windows 11 build 的 `NtCreateProcessStateChange` ABI 稳定性；本机已实测 state-change 与 fallback 两条路径。
- live desktop 长时 A/B、冷启动时间、软缺页回读、实际续航影响。
- P3/P4 apply 路径的真实服务停启、驱动、黑名单、Junction 与目录迁移。
- P1 生效依赖高完整性令牌；普通权限下仅返回结构化 `STATUS_PRIVILEGE_NOT_HELD`，不做隐式提权。

## 提交

- `b93e766 feat(memory): port pure natural memory governance`（17 files, +1901 / -6）
- 父提交 `6688b3b chore: refresh public update manifest`
- 远端 `origin/main` = `b93e766`


---

## 更新（调度补齐与 P3/P4 可执行化）

后续提交 `5d8fc30 feat(memory): schedule memory clean and execute service and migration controls` 关闭了此前的两个缺口。

### 官方调度取证

| 能力 | 官方自动定时 | 证据 |
| --- | --- | --- |
| P0 工作集裁剪 | 有 | `StartupWorkingSetTrimDelays` + `DispatcherTimer` 5 分钟 + `_interactionTrimTimer` |
| P1 系统内存列表清理 | 未发现独立定时器 | `MemoryManager::ClearMemory` 为一次 CleanMode 动作 |
| P2 进程冻结 | 未发现独立定时器 | `SuspendPidList`/`EnumIconicAndVisiblePid` 枚举驱动 |
| P3 停服务 | 执行，非定时 | `ServiceManagerCfg.dat` XOR 0x80 → `SysMain`/`whesvc` stopped |
| P4 目录迁移 | 执行，非定时 | `DiskManager` 的 `CreateJunction`/`HandleBatchMoveAction` |

结论：官方只对 P0 做了自动定时；P1/P2 是一次性动作。社区版按需求在 P1/P2 上补了显式定时器，默认关闭。

### 新增模块

- `PureNaturalNative.cs`：唯一持有两个特权、`NtSetSystemInformation`、`NtSuspendProcess`/`NtResumeProcess`、自带子进程枚举的深模块；诊断与调度共用，杜绝行为分叉。
- `PureNaturalScheduler.cs`：P1/P2 定时器。`systemCleanIntervalMs` 默认 30 分钟（1 分钟–24 小时），`ownedFreezeIntervalMs` 默认 10 分钟；`freezePids` 只作为自有子进程的子集筛选；`Dispose` 恢复全部冻结进程；`MAGICCOMMUNITY_DISABLE_PURE_NATURAL_SCHEDULE=1` 可整体关闭。
- `PureNaturalOperations.cs`：P3/P4 执行器。`IPureNaturalActions` 缝隙 + Windows 适配器；dry-run 默认，`mode=apply` 才执行；Junction 失败自动移回；回执含 before/after 与 rollback 条目；`Rollback` 恢复服务、删 Junction、移回目录。
- `PureNaturalOperationsTests.cs` / `PureNaturalSchedulerTests.cs`：10 + 7 项隔离测试（注入时钟与 fake 适配器，无真实服务/目录动作）。
- `PureNaturalMigrationFixture.cs`：真实文件系统验证 P4（隔离 artifacts 目录，不碰用户 profile）。
- `PureNaturalServiceFixture.cs`：真实服务只读查询 + 非管理员停服务拒绝路径验证。

### 新增 CLI

```text
--pure-natural-operations-test     隔离 P3/P4 适配器测试
--pure-natural-schedule-test       隔离调度测试
--pure-natural-migration-fixture   真实文件系统迁移/回滚夹具
--pure-natural-service-fixture     真实服务状态与拒绝路径夹具
--pure-natural-apply               需 mode=apply，执行服务停启与目录迁移
--pure-natural-rollback --receipt  按回执回滚
```

### 新增验证

| 项 | 结果 |
| --- | --- |
| `check-worktree.ps1` | `exitCode=0`，12 项测试全部 `allPass=true` |
| P4 真实夹具 | `movedExists` / `junctionIsLink` / `readableThroughJunction` / `restored` / `targetCleared` 全部 true |
| P3 非管理员 | `whesvc` `Changed=false`、before/after `RUNNING`、`ExitCode=5`，结构化拒绝而非异常 |
| 诊断复用原生模块 | `--pure-natural-runtime-test` `allPass=true`，P0/P2 有效，P1 中完整性仍 `0xC0000061` |
| `diff --check` | `exitCode=0` |
| 推送 | `c299fc5..5d8fc30`，`PUSH_EXIT=0`，远端 `main` = `5d8fc30` |

### 仍然保留的边界

- P1 在普通权限下返回 `STATUS_PRIVILEGE_NOT_HELD`；P3 停服务需要管理员令牌。两者都不隐式提权。
- P2 只冻结本进程的直接子进程，永不接受任意进程名。
- P4 只迁移策略里列出的已知目录，需要显式 `migrationTargetRoot`；默认 dry-run。
- 内核驱动（`MonProcessControl.sys` 等价物）与第三方进程黑名单/终止仍未实现；官方这部分是独立签名驱动。
