# embedded-workspace-init Skill 设计交接

## 状态

- 本目录保存已经讨论确认的 Skill 设计，不是已安装或可直接调用的 Skill。
- 实际 Skill 已实现，本文件继续作为其设计、维护和验收依据。
- Skill 名称：`embedded-workspace-init`。
- 调用方式：仅显式调用，关闭隐式调用。
- 本 Skill 负责初始化和刷新工作区，不负责日常功能开发。
- 本文件只作为设计、实现和验收依据，不复制到实际 Skill 或已初始化工作区，也不作为普通任务的必读上下文。

实际 Skill 的 `agents/openai.yaml` 设置：

```yaml
policy:
  allow_implicit_invocation: false
```

## 目标

为一个可能包含单个或多个 MCU、多个 IDE 工程、公共代码、理论资料和验证内容的嵌入式产品建立 Agent 工作区。

初始化后应达到以下结果：

- 用户继续在原有 IDE 和编辑器中维护自己的权威工程。
- 用户权威工程与纯净 Agent 工作区始终位于两个互不包含的真实目录中。
- Agent 默认只读用户权威工程，在工作区受管副本中开发、构建和验证。
- 不要求用户工程采用固定源码结构，也不重组 IDE 生成的工程。
- 多个对话可以通过独立 workstream 并行工作。
- 后续出现新 MCU 工程时自动登记并纳入对应源组私有 Git。
- Agent 与用户工程通过用户同步基线进行三方比较，仅在用户明确表达发布意图时写回。
- 普通 Agent 即使没有专门的日常开发 Skill，也能通过根 `AGENTS.md` 正常工作。
- 工作区提供独立的参考工程目录，供 Agent 按需查阅和比较，但不参与用户工程同步。
- 工作区提供持久项目知识层，区分产品定义、当前方案、开发路径、版本边界和任务过程。
- 已初始化工作区能够受控进化：项目事实自动适配，规则和结构只在用户确认具体计划后迁移。
- 工作区根目录保持整洁，所有工具、脚本、日志和其他产物分类存放并具有说明。
- 工作区使用 Agent 管理 Git、源组私有 Git 和可选的用户工程 Git 分离管理不同内容。
- 根目录生成面向用户的中文使用手册，隐藏内部复杂度。
- 非空旧 Agent 工作区迁移到新的纯净路径后保持原样，默认登记为 Agent 可按需读取的外部历史参考；用户可明确不登记历史绑定，不再为迁移重复创建备份副本。
- 初始化时建立完整的固定目录骨架和职责 README；项目知识正文、参考工程实例、workstream 实例、证据、日志、恢复快照和迁移记录只在对应操作实际发生时生成。

## 不做的事情

- 不规定 `bsp/`、`drivers/`、`middleware/`、`app/` 等源码布局。
- 不将现有工程转换为 CMake、PlatformIO 或其他构建体系。
- 不为了统一管理而移动、重命名或重组用户工程。
- 不在用户权威工程内部建立 Agent 工作区，也不提供兼容模式。
- 不自动修复初始化时发现的源码或构建错误。
- 不自动安装或升级 IDE、工具链、SDK、Pack、许可证或依赖。
- 不在初始化阶段烧录、擦除、调试或操作板卡。
- 不提供后台实时文件监控；自动响应发生在下一次 Agent 任务中。
- 不创建专用 Windows 账户、NTFS ACL、虚拟机或独立 Publisher。
- 不承诺操作系统级绝对隔离；采用工作副本、路径检查、Git 和备份形成软隔离。
- 不实现板卡资源锁或持久化硬件租约。
- 不强制完整分层测试流水线，不为了形式引入测试框架或模拟器。
- 不创建专用 Git 提交 Skill；提交规则由 `AGENTS.md` 约束。
- 不在原路径交换或重组非空旧 Agent 工作区，也不为迁移再复制一份内容相同的初始化备份。
- 不为尚未出现的任意未来版本预先实现通用迁移引擎；保留版本字段，出现真实版本变化后再增加该版本的确定性迁移规则。

## 轻量化边界

轻量化保留全部已确认的用户能力，只允许以下明确调整：机器状态统一为 JSON/JSONL；删除可重建的 `sync-state/workstreams/` 缓存；将详细运行规则改为按场景读取；合并重复说明和验收索引；完整预建固定目录骨架但按需生成动态内容；未来 schema 迁移按真实版本实现。除此以外的功能或安全机制不得以“精简”为由删除，必须先提出具体变更并再次取得用户确认。

路径隔离、`read-only`、工作区状态门禁、三套 Git、用户/任务/构建基线、可逆映射、文件索引、字段元数据、工作区 Mutex、锁内重读、结构化命令、发布清单、恢复快照、写前哈希、原子替换、安全回滚、构建副作用分类、敏感凭据过滤、法律文件保留和旧规则归档优先于所有大小或文件数量目标。发生冲突时保留安全机制，先调整本规范，不能通过压缩措辞改变其语义。

## 核心术语

### 用户权威工程

用户日常使用 IDE 和其他编辑器维护的原始工程。它始终位于纯净 Agent 工作区之外，可以包含一个或多个分散路径。本 Skill 及其管理的 Codex Agent 默认只读，只有明确发布或单独授权用户 Git 操作才可写入；用户本人、IDE 和编辑器内 Agent 插件仍可在 Skill 之外直接维护该工程。

### 权威源组

需要保持相对路径、共享代码或共同生成配置的一组用户工程路径。每个源组使用稳定的 `source-id`。

### 目标

一个可识别、构建或验证的 MCU 工程，使用稳定且人类可读的 `target-id`。一个源组可以包含多个目标；相同 MCU 型号也可以有多个目标。

### 集成副本

`sources/<source-id>/integration/` 中的 Agent 受管副本。它保持用户源组必要的目录拓扑，并由源组私有 Git 管理。

### Workstream

一个逻辑开发任务及其独立工作副本，位于 `work/<workstream-id>/`。一个 workstream 可以同时涉及多个目标、模块和源组；对话绑定仅用于辅助续接，不作为识别 workstream 的硬依赖。

### 用户同步基线

用户权威工程与源组私有 Git 中最后一次内容一致的完整受管状态，由可取回内容的不可变提交表示。它用于比较“用户同步基线、用户当前工程、Agent 当前 workstream”并检测冲突，与构建是否成功无关。

### Workstream Git 基线

- `user_baseline_commit`：当前 workstream 用于三方比较的用户同步基线。
- `task_base_commit`：workstream 分支实际创建点，可以包含已固定到具体提交的其他 workstream 依赖。
- `head_commit`：发布前冻结的当前 workstream 状态。

发布范围由 `task_base_commit` 到 `head_commit` 的差异和固定提交的显式依赖闭包确定；三方冲突判断使用 `user_baseline_commit` 中的用户内容。

### 构建基线

每个目标和稳定 `build-id` 最近一次实际构建成功的提交和证据，记录在 `build_baselines` 中。一个目标可以包含 Debug、Release 或其他多个构建配置；没有成功构建过时对应值为 `null`。构建基线只说明验证状态，不能代替用户同步基线，也不能决定三方同步是否可用。

### 参考工程

放在 `reference-projects/` 中、仅供阅读、比较和借鉴的工程快照。参考工程不是用户权威工程、受管源组、构建目标或发布对象，Agent 不在其中直接开发。

### 旧工作区参考

迁移前的非空旧 Agent 工作区。它保留在原路径，默认登记为可按需读取的历史参考；用户明确选择 `RegisterLegacyWorkspace: false` 时不登记该历史路径。已登记时 Agent 可以按任务需要读取其中的代码、文档、方案和历史状态，但不得把其中的旧规则作为当前指令，也不得对整棵旧目录自动执行目标登记、同步、构建或发布。它不是 `reference-projects/` 中经过包装的普通参考工程。

### 管理根目录

独立纯净 Agent 工作区的根目录，也是 Codex 日常任务唯一允许打开的项目入口。固定记录为 `layout_mode: pure` 和 `managed_root: .`。

## 建议调用

首次初始化示例：

```text
$embedded-workspace-init 使用这些用户工程路径初始化当前嵌入式工作区：<paths>。保持原有 IDE 工程结构不变。
```

显式重新扫描示例：

```text
$embedded-workspace-init 重新扫描并补充登记新增的 MCU 工程，保留已有确认信息。
```

增加外部分散工程示例：

```text
$embedded-workspace-init 将 <path> 作为新的用户权威源加入当前工作区。
```

初始化已有工作区示例：

```text
$embedded-workspace-init 检查当前已有工程并制定外部纯净 Agent 工作区初始化方案；确认前不要修改任何内容。
```

添加参考工程示例：

```text
$embedded-workspace-init 将 <path-or-url> 导入为参考工程，仅供 Agent 查阅，不作为开发或发布目标。
```

## 强制纯净布局与迁移

同一个 Skill 支持首次初始化、中途初始化、重新扫描和受控升级，但只支持独立的纯净 Agent 工作区：

```json
{
  "layout_mode": "pure",
  "managed_root": "."
}
```

初始化前解析 Agent 工作区、所有用户源路径、符号链接和 junction 的真实路径，并强制满足：

- Agent 工作区不能位于任何用户权威工程内部。
- 用户权威工程不能位于 Agent 工作区内部。
- 二者不能通过符号链接、junction 或路径映射形成直接或间接包含关系。
- 用户权威工程不能直接充当 `sources/<source-id>/integration/`。
- Codex 日常任务必须在纯净 Agent 工作区根目录的 `Local` 环境运行，不能对管理根目录使用 Codex-managed 或 permanent worktree，也不能直接把用户工程、`integration/` 或 linked worktree 添加为 Codex 项目。

第一版运行边界：

- 仅支持同一台 Windows 主机上的本地工作区和本地管理脚本，不承诺跨主机、网络共享目录或 WSL 与 Windows 并发访问时的互斥一致性。
- 初始化计划阶段只读解析候选工作区真实根路径；用户确认后，在 `workspace_state: initializing` 阶段将该路径写入本机配置，并在切换为 `active` 前重新校验。只有已经激活的工作区在普通任务开始时才要求本机配置必须存在且当前真实根路径与记录值一致；不一致时只报告并停止写入。
- 初始化和日常检查必须实际读取所有已登记用户源和旧工作区参考路径。路径不存在或当前权限不可读时列出具体路径并停止对应操作，不自动修改系统权限。
- 第一版要求同一用户权威源同时只归属于一个 `workspace_state: active` 的 Agent 工作区。初始化计划必须声明这一限制；发现已知冲突时停止，不引入跨工作区锁或全局注册表。
- Codex-managed worktree 只检出 Agent 管理 Git 跟踪的内容，而源码副本、本机配置和同步状态均被该 Git 忽略，因此不得使用 `.worktreeinclude` 绕过本限制复制整套受管状态。

任何一项无法证明满足时，只报告解析结果并停止，不创建目录、配置、Git、备份或构建输出。

### 初始化路由

- 当前目录是全新空目录：用户明确调用初始化后可以直接建立纯净 Agent 工作区。
- 当前目录是已有效初始化的纯净 Agent 工作区：沿用 `workspace.json`，只执行请求范围内的幂等刷新或受控升级。
- 当前目录是非空且未初始化的候选 Agent 工作区或旧 Agent 工作区：先只读盘点并展示迁移计划，确认前零写入。
- 当前目录是用户权威工程或包含任一用户权威路径：不得在其中创建 Agent 管理子目录；只读盘点后建议一个外部空目录作为新的纯净 Agent 工作区，展示路径和完整计划并等待确认。

建议的外部路径只是计划的一部分，不能自行假定固定盘符或父目录。目标目录必须是全新空目录，或已经由本 Skill 有效初始化的纯净 Agent 工作区；其他非空目录只能先进入迁移计划流程。

为当前用户工程建立外部 Agent 工作区时：

1. 只读盘点用户工程和候选 Agent 工作区。
2. 展示外部 Agent 工作区路径、源组、可逆映射、过滤项、三套 Git 边界、验证和回滚方法，然后停止等待用户确认。
3. 用户确认完整计划后重新检查状态；发生实质变化时更新计划并再次确认。
4. 在外部空目录创建纯净 Agent 工作区，将用户已保存内容导入各源组集成副本。
5. 创建 Agent 管理 Git、源组私有 Git、用户同步基线及必要配置。
6. 验证副本、映射、Git 边界、配置和安全构建入口，并确认用户工程没有因布局初始化被修改。
7. 要求用户以后从新的纯净 Agent 工作区根目录启动 Codex 任务。

布局初始化不得在用户权威工程中新增 `AGENTS.md`、`README.md`、`USER_GUIDE.md`、`.gitignore`、Agent 副本或其他管理文件。用户另行确认“为用户工程启用 Git”时，才允许通过独立的用户 Git 流程创建 `.git` 和必要 `.gitignore`，不得把这项写入夹带进布局初始化。

### 非空 Agent 工作区迁移

非空候选或旧 Agent 工作区采用“新路径建立、旧路径保留、验证后启用”：

1. 只读盘点现有文件、目录、Git、未提交状态、工程入口、链接和说明文件。
2. 展示旧工作区真实路径、新的最终工作区路径、分类映射、排除项、Git 边界、将复制或保留的内容以及验证方法，然后停止等待用户确认。
3. 用户未回应、拒绝或取消时零写入结束；只确认部分内容时先生成新计划，不自行实施部分迁移。
4. 用户确认完整计划后重新检查当前状态；发生实质变化时更新计划并再次确认。
5. 提醒用户保存相关编辑器内容，并在复制期间暂停写入旧工作区。
6. 确认新路径是全新空目录，且与旧工作区和所有用户权威路径的真实路径互不包含；在新路径创建 `workspace_state: initializing` 的标准结构。
7. 直接从保持原样的旧工作区按明确分类映射复制内容，不创建第二份初始化备份。普通资料映射可明确指定 `action: preserve-only`，该项只留在旧路径，不迁入。无法可靠分类的内容只进入迁移待确认清单，不擅自删除、改名或归类。
8. 复制期间检测源文件是否发生变化；发现变化时停止复制并保留新目录的 `initializing` 状态，重新盘点后再执行，不把不一致副本启用为工作区。
9. 检查文件清单、Git 边界、相对路径、敏感内容、工程识别和可用构建入口，并确认旧工作区没有被修改。
10. 全部验证通过后原子更新为 `workspace_state: active`，记录 `migrated_from`、迁移时间和初始化报告，并要求用户从新路径重新打开 Codex。
11. 验证失败时旧工作区继续可用，新目录保留为未完成候选；初始化系统不交换、移动、重命名或删除旧工作区。

旧工作区保留为迁移来源，默认作为外部历史参考；不再生成 `<workspace>.pre-init-backup-*` 包装目录：

- Agent 可以从新工作区按需只读检查旧工作区中的代码、文档、方案和历史状态，但不默认遍历整棵目录。
- 旧工作区不登记为普通参考工程，也不自动参与目标发现、参考工程发现、构建、导入或发布。
- 旧工作区中的 `AGENTS.md`、`AGENTS.override.md` 和 fallback 文件只作为历史内容；不得从旧路径启动 Codex，也不得把它们加载为新工作区的当前指令。
- 需要修改或构建旧内容时，将所需内容复制到当前 workstream 的 `reference-copies/`，不直接写旧工作区。
- 如果旧目录或其子目录仍是用户日常维护的权威工程，对应路径继续按已确认映射作为用户权威源；只有旧的 Agent 管理外壳和不再使用的内容属于旧工作区参考。
- 新工作区的 `workspace-management/migration/initialization-report.md` 记录旧路径、分类映射、验证结果、保留项和未执行事项。

用户明确不保留旧管理机制时，迁移计划允许分别设置 `LegacyRuleDisposition: preserve-only` 和 `RegisterLegacyWorkspace: false`：前者不复制旧规则正文或生成旧规则归档清单，后者不把旧路径登记为后续可访问的历史绑定。默认值分别为 `archive` 和 `true`，兼容原流程；新增选择纳入批准载荷和摘要，旧载荷缺少这些字段时沿用默认值。未登记历史路径不删除迁移来源身份、时间和初始化报告。旧管理对话和资料不是必迁内容，可以通过明确的 `preserve-only` 映射排除；新工作区自身的固定管理目录和工具仍须创建。

### 旧规则归档

纯净 Agent 工作区只保留一个生效的根 `AGENTS.md`，不在 `integration/` 或 linked worktree 中额外生成 `AGENTS.md` 或 `AGENTS.override.md`。用户工程本身已有的同名文件作为用户内容原样导入和保护，但不得据此从副本目录单独启动 Codex。

迁移旧 Agent 工作区时：

- 默认将旧工作区中的 `AGENTS.md`、`AGENTS.override.md` 和当前配置列出的 fallback 指令文件逐字节复制到新工作区的 `workspace-management/history/legacy-instructions/`，不得在原文中插入元数据，也不得修改旧路径中的原文件。明确批准 `LegacyRuleDisposition: preserve-only` 时不复制规则正文或归档清单，旧规则仅保留在原路径。
- 归档文件名包含原类型、时间戳和短哈希，避免重名；独立 `manifest.json` 记录原路径、归档路径、归档日期、完整 SHA-256 和原文件是否曾生效。
- 归档名称必须再次检查，不得等于任何当前有效的 fallback 指令文件名。
- 新根 `AGENTS.md` 只记录归档位置和“仅供迁移审计、不再作为指令、除非用户明确要求否则不要加载”，不复制旧规则正文。
- 先验证批准的旧规则处置和新根规则，再启用新工作区；旧规则只会在错误地从旧路径启动 Codex 时继续生效，因此用户手册必须禁止把旧工作区作为日常 Codex 项目打开。
- 外部用户权威工程中的 `AGENTS.md`、`AGENTS.override.md` 或 fallback 文件保持原路径和内容，不移动、不改名、不修改。

### 已有工作区通用保护

- 初始化已开发到一半的工程时，将当前已保存内容视为导入基线，不把编译失败视为初始化失败。
- 不自动认领或提交用户已有改动，不为了验证重新生成或修复业务源码。
- `sources/`、`work/`、`reference-projects/`、`project-docs/` 或 `workspace-management/` 已有其他用途时，不得自动认领或覆盖。
- 已有 Git 只识别和保护，不创建错误嵌套仓库、不改写历史、不夹带既有修改。
- 已初始化工作区再次调用时保持幂等，只修复缺失内容、刷新事实或执行经过确认的迁移。
- `workspace_state: initializing` 的候选工作区只允许继续初始化、只读检查或放弃候选，不允许日常开发、导入或发布；只有 `active` 工作区可以进入正常任务。

## 多权威源和源组判断

- 多个 MCU 工程位于同一个合理产品目录时，整体建立一个源组副本。
- 分散且相互独立的工程分别登记为不同源组并分别建立副本。
- 分散目录存在共享代码、相对路径依赖或共同生成器配置时，优先保持原有相对拓扑并作为同一逻辑源组处理。
- 如果维持相对关系需要复制一个包含大量无关内容的上级目录，使用多个路径映射复刻必要拓扑，不复制整个无关父目录。
- 不为管理方便改变用户原有路径、目录名或工程关系。
- 每个映射使用稳定 `mapping-id`。可移植的 `mapping-id`、`integration-subpath`、类型和映射版本写入 `targets.json`；对应的用户绝对 `source-path` 只写入被 Agent 管理 Git 忽略的 `targets.local.json`。
- 第一版只支持目录映射。单文件映射只有出现真实需求后再扩展。
- 初始化、导入和发布前校验所有真实源路径、集成路径和映射目标互不递归包含；同一源组内的 `integration-subpath` 不得重叠。凡纳入用户同步范围的集成文件，都必须能唯一反向解析到一个 `mapping-id` 和用户相对路径；`agent-created` 或没有用户权威源的 `reference-promoted` 源组可以使用空映射，不适用此要求。
- 映射变化时递增 `mapping_revision` 并更新摘要；旧 workstream 或发布事务引用其他版本时停止发布，先执行经过确认的映射迁移。
- 副本路径优先使用较短、纯 ASCII、无特殊字符的路径，以兼容旧工具链。

正式源组还应区分来源：

- `user-imported`：存在外部用户权威源，使用可逆映射和三方同步。
- `agent-created`：由 Agent 在纯净工作区内新建，`user_source: none`、`sync_strategy: none`，不执行用户导入、发布或用户 Git 询问。
- `reference-promoted`：由参考工程明确提升而来；是否存在用户权威源由 `user_source` 独立表达。

用户以后为 Agent 自建工程指定权威路径时，必须经过受控配置迁移、建立映射和首次用户同步基线后，才能启用导入或发布。

## 初始化流程

1. 检查当前执行环境、当前目录、候选 Agent 工作区、所有用户路径、规则文件、Git 和未提交状态；外层 Codex worktree、不可读外部路径或已知的多活工作区冲突先报告并停止对应操作。
2. 获取用户提供的权威工程路径；不递归扫描整台电脑寻找工程。
3. 解析真实路径并验证强制纯净布局；当前目录属于用户工程时只提出外部 Agent 工作区方案。
4. 首次接入非空目录或需要策略、结构、映射或 schema 迁移时只读展示具体计划；用户确认后才写入。纯事实重新扫描不走迁移流程。
5. 识别源组、可逆映射、三套 Git 边界、共享路径和嵌套仓库。
6. 扫描疑似敏感文件、授权凭据和应排除的可重建缓存。
7. 新工作区先标记为 `workspace_state: initializing`，将已经确认的真实根路径写入 `targets.local.json`，再创建或确认 Agent 管理 Git；按源组创建集成副本并保持必要拓扑。
8. 为每个源组自动建立或确认源组私有 Git；`user-imported` 源组创建可取回内容的首次用户同步基线，其他正式源组创建初始代码基线。
9. 发现 MCU 工程，生成稳定 `target-id` 并写入目标配置和最小字段元数据。
10. 识别或导入用户明确提供的参考工程，并与开发源严格区分。
11. 识别 IDE、生成器、构建配置、工具链、产物和可用验证入口。
12. 在安全条件满足时尝试一次普通初始构建验证，单独记录构建结果和构建基线。
13. 独立询问用户是否为没有 Git 的权威工程创建用户 Git；未确认时不修改用户工程，也不阻塞 Agent 工作区初始化。
14. 生成唯一根规则、概览、用户手册、完整固定目录骨架、职责 README、运行期指南、JSON schema、项目知识模板和确定性管理脚本；没有真实内容时不创建项目知识正文、参考工程、workstream、证据、日志或恢复实例。
15. 验证 JSON 可读且符合 schema、三套 Git 边界有效、固定骨架完整、指南路由有效、根规则唯一且用户工程未被意外修改；全部通过后才原子更新为 `workspace_state: active`。

## 后续新 MCU 工程

源组私有 Git 是持续约束，不是初始化时的一次性动作。

触发规则：

- Agent 创建、导入或复制新 MCU 工程后立即识别来源并登记。
- 用户在已登记源路径中通过 IDE 创建新工程后，下一次 Agent 任务开始时自动发现并登记。
- 新工程位于未登记的外部路径时，Agent 只有在用户提供该路径或任务明确访问该路径后才能发现；不得扫描整块磁盘。
- 用户可以随时显式调用重新扫描作为兜底。

自动处理：

- 新工程属于已有用户源组：通过既有映射纳入集成副本和源组私有 Git，不创建嵌套 `.git`。
- 新工程位于新的外部用户路径：只有用户提供或任务明确访问该路径后才建立候选映射；路径关系明确时创建 `user-imported` 源组和私有 Git。
- Agent 在工作区内新建的正式工程：创建或纳入 `agent-created` 源组和源组私有 Git，不虚构用户权威路径。
- 新工程与已有目录共享依赖：保持相对拓扑后纳入同一源组。
- Agent 根据工程名称或用途生成稳定且人类可读的 `target-id`，重名时追加最小可用序号。
- `target-id` 写入后不随目录重命名自动变化；显示名称可以更新。
- 用户导入工程创建首次用户同步基线后再允许 Agent 修改；Agent 自建工程创建初始私有 Git 基线后再修改。

存在下列歧义时，只建立待确认候选，不正式登记：

- 无法判断是新工程、备份、复制品还是厂商示例。
- 存在嵌套工程入口或嵌套 Git。
- 已登记工程疑似移动、拆分或合并。
- 新扫描结果与已确认的 MCU、构建命令或生成代码边界冲突。
- 无法唯一确定源组来源、映射或是否存在用户权威源。

## 幂等要求

- 已存在的文件、目录和私有 Git 不重复初始化。
- 已登记且没有变化的目标不重写配置、不创建空提交。
- 已确认或已验证字段不被启发式结果静默覆盖。
- 新扫描只补充缺失信息或追加新对象。
- 消失或移动的工程标记为待确认，不直接删除记录。
- 构建命令、工具链或其依赖变化时保留旧信息、将相关验证状态标为 `stale` 并报告差异。
- 映射内容没有变化时不递增 `mapping_revision`；映射变化必须保留旧版本引用并走受控迁移。
- 人工维护的配置发生并发变化时重新读取，不能覆盖。

## 三套 Git 必须分离

### 用户权威工程 Git

用户工程 Git 是可选的，由用户决定是否创建以及何时提交。

- 已存在 Git：识别并保护现状，不自动提交普通开发改动。
- 不存在 Git：展示建议的仓库边界，并询问一次是否初始化和创建首次基线。
- 用户同意：创建针对实际 IDE 的 `.gitignore`，检查纳入范围，并创建首次基线提交。
- 用户拒绝：记录 `user_git: disabled`。
- 用户未回应：记录 `user_git: deferred`，继续其余初始化，不阻塞。
- 后续用户要求启用时，重新扫描后只补 Git 部分。
- 用户工程 Git 为 `deferred` 时，只有实际修改或发布到用户工程的任务结束后提醒：`Git 已暂缓，当前没有完整版本回退保障。`
- 纯读取、理论讨论或只修改 Agent 副本时不提示。
- 发布到用户工程默认只改变工作树，不自动提交；只有用户明确要求提交时才提交。

初始化用户 Git 前必须检查：

- 嵌套 `.git`、submodule、worktree 和 Git LFS。
- 合理的仓库根目录，不能为了多 MCU 建立覆盖大量无关文件的上层仓库。
- IDE 缓存、构建产物、本机状态和敏感内容。
- 将纳入和排除的内容摘要。

发现仓库边界歧义时暂停用户 Git 部分，不影响其他初始化。

首次基线提交建议：

```text
chore: establish embedded project baseline
```

它只表示当前已保存工程状态，不表示功能完成。

### Agent 管理 Git

纯净 Agent 工作区根目录自动建立一个 Agent 管理 Git，不再单独询问用户。它只管理工作区规则和元数据：

- 根 `AGENTS.md`、`README.md` 和 `USER_GUIDE.md`。
- `project-docs/`、参考工程包装说明和索引。
- 固定目录骨架及其职责 `README.md`。
- 可移植配置、运行指南、JSON schema、管理工具、模板、迁移历史、workstream 的 `README.md` 与 `workstream.json`。

它必须忽略由其他仓库或本机状态负责的内容：

- `sources/*/integration/`。
- `work/*/sources/` 和 `work/*/reference-copies/`。
- `reference-projects/*/project/`。
- `targets.local.json`。
- `workspace-management/sync-state/` 中除固定骨架 `README.md` 外的动态状态和索引。
- `workspace-management/evidence/`、`workspace-management/recovery/` 和 `workspace-management/ide-workspaces/` 中除各自固定骨架 `README.md` 外的证据、恢复快照和 IDE workspace 状态。
- 构建产物、下载内容、大型日志及明确的任务临时文件。

`.gitignore` 必须先允许 Git 遍历上述固定骨架目录，再重新纳入根级及 `sync-state/sources/`、`sync-state/indexes/`、`sync-state/transactions/` 中的 `README.md`；不能只写深层否定规则而让父目录仍被整体排除。动态内容保持忽略，职责 README 必须由 Agent 管理 Git 跟踪。

有长期价值的小型任务脚本可以纳入管理 Git；临时生成物不得借此进入历史。管理 Git 不配置可写推送流程，不包含用户权威工程或源组代码。

管理 Git 自动创建内部检查点，但不对每次文字编辑提交：

- 初始化、事实刷新、workstream 创建或进入终态、经过确认的策略迁移成功后，各创建一个只包含该次管理操作的逻辑提交。
- 进行中的 workstream 状态和 README 可以在同一任务内多次更新，只在暂停、交接或完成时统一形成检查点。
- 提交前重新读取状态并只暂存本次管理操作涉及的明确路径，禁止 `git add .`、`git add -A` 和 `git commit -a`。
- 管理操作失败时不创建成功检查点；已有无关未提交内容不被认领、暂存或覆盖。
- 该自动检查点只属于 Agent 管理 Git，不改变用户工程 Git 的显式提交规则。

### 源组私有 Git

源组私有 Git 是强制且自动维护的工作区内部机制，不再单独询问用户。

- 每个受管源组始终必须由独立的源组私有 Git 覆盖。
- 用户源组对应单个 Git 仓库时，优先建立不共享对象库的独立本地 clone，并导入用户当前已保存的 dirty 和必要 untracked 内容。
- 用户源组没有 Git，或由多个路径映射组成时，在保持拓扑的集成副本内初始化私有 Git。
- `user-imported` 源组自动创建用户同步基线、稳定基线 ref 和必要检查点；没有用户权威源的源组只创建初始代码基线和任务检查点。
- 自动为不同 workstream 创建分支和 linked worktree，固定放在 `work/<workstream-id>/sources/<source-id>/`。
- 不配置可写推送流程，不把内部提交推送或写入用户工程 Git。
- 新增 MCU 工程时自动纳入相应私有 Git并创建导入提交。
- 源组私有 Git 只承诺恢复已纳管、已导入且未被过滤的内容，不能替代用户工程自身的完整版本保障。
- 可修改的任务参考副本可以使用同类的临时私有 Git，但不属于任何用户源组，也不参与发布。

第一版不自动纳管 submodule、嵌套 Git、既有 linked worktree 或 Git LFS 源：

- 发现任一结构时暂停受影响源组，展示仓库拓扑和检测依据，不影响其他明确独立的源组。
- 不复制 `.git` 元数据、不展平仓库、不自行初始化覆盖它们，也不改写或合并既有历史。
- 用户可以确认将独立仓库拆成不同源组，或将该源组标记为暂不纳管；未确认前不建立错误的私有 Git 和用户同步基线。
- 第一版不声称能够同步或逐字节恢复 LFS 对象；只有用户先将其转换为受支持的普通文件布局，或后续明确扩展策略后才能纳管。

### Git 命令路由

所有受管 Git 操作必须显式选择仓库，不能依赖进程当前目录或裸 `git` 命令猜测：

```text
git -C <managed-root> ...
git -C work/<workstream-id>/sources/<source-id> ...
git -C <user-authority-path> ...   # 仅在用户明确授权的流程中
```

- 共享 PowerShell 模块提供统一的 Git 调用函数，要求调用方传入仓库类型和规范化真实路径，并在执行前校验归属。
- 根目录 Git只代表 Agent 管理 Git；根目录的 `status`、`diff` 或 Codex 内置仓库审查结果不得被解释为全部源码状态。
- 源码状态、提交和审查按当前 workstream 的每个源组私有 Git 分别执行，多源结果再由脚本汇总。
- 用户工程 Git 命令只在用户 Git 初始化、显式提交或发布检查等已授权流程中运行，不能由源组私有 Git 操作间接触发。
- 公共进程运行器启动 Git 时清除继承的仓库、工作树、索引、对象库、命名空间及临时配置定位变量，防止 `GIT_DIR`、`GIT_INDEX_FILE` 等把操作引向错误位置。调用方通过 `Environment` 明确传入的环境值随后生效，允许保存机制使用独立临时索引。

推荐配置语义：

```json
{
  "git": {
    "user_source": {
      "status": "deferred",
      "auto_commit": false
    },
    "management": {
      "status": "enabled",
      "auto_checkpoints": true,
      "push": "disabled"
    },
    "source_copy": {
      "status": "enabled",
      "auto_baseline": true,
      "auto_checkpoints": true,
      "push": "disabled"
    }
  }
}
```

### 内部用户直接修改的保留与恢复

Agent 工作区内部由 Agent 管理；用户直接修改内部受管文件与修改外部权威工程使用不同流程。Agent 写入前建立相关检查点，发现内部用户修改时先保存独立的 Agent 改动。不能仅凭 Git dirty 状态认定全部修改归属；同一文件混有 Agent 和用户修改时先分离，不得整份回退。

使用 `preserve-user-changes.ps1`，以 `WorkspaceRoot`、已登记内部 `RepositoryRelative` 和明确的 `RelativePaths` 生成零写入计划，再以 `-Apply -ExpectedPlanDigest <digest>` 应用。内部规则已允许该操作，无须反复确认；用户要求只读时仍然零写入。

执行必须遵守：

- 仅限管理根、已登记源组 integration 或 workstream 源副本；不得作用于外部用户 Git、参考正文或其他未登记仓库。
- 暂存区相对 HEAD 的差异和磁盘相对 HEAD 的差异分别检测；用户暂存后将磁盘改回 HEAD 的情况也必须保留。
- 在工作区 Mutex 下锁内重读，核对 HEAD、文件范围、暂存条目、文件哈希和计划摘要。
- 使用独立临时 Git 索引，将选定暂存区和磁盘内容分别保存为提交，通过可达 `preserved-user/*` 分支保留；新增、删除和二进制文件适用。
- 保存验证成功且现场未漂移后，仅恢复选定文件和暂存区条目到不变的 Agent HEAD，不切换保存分支、不回退整个仓库、不暂存或恢复无关文件，也不自动合并保存的用户修改。
- 保存失败禁止恢复；保存后发现漂移或恢复失败时保留分支并停止相关操作。继续任务后向用户报告分支、两个提交、文件范围及恢复结果。
- Git 忽略的本机配置和运行状态通过对应恢复机制及验证快照保留，不强制提交；秘密不得进入保存 Git。明确要求的策略或配置变更走受管操作，不作为误改丢弃。

外部用户权威工程中的用户本人、IDE 和编辑器内 Agent 插件修改仍以已保存磁盘内容为准，通过受管导入、用户同步基线三方比较和冲突处理进入工作区。未保存的编辑器缓冲区不可见，不使用内部保存机制处理外部修改。

## 共享管理状态并发控制

所有会改变工作区共享状态的管理脚本共用一把工作区级 Windows Named Mutex。锁名由工作区真实路径的规范化表示计算 SHA-256 后生成，例如：

```text
Local\embedded-workspace-init-<path-sha256-prefix>
```

规范化路径必须先解析符号链接和 junction，统一大小写、分隔符和末尾分隔符；同一真实工作区不能因不同路径写法得到不同锁。

锁保护：

- `workspace.json`、`targets.json`、`targets.local.json` 和共享索引。
- Agent 管理 Git，以及源组分支、worktree、基线和稳定 ref 的创建或更新。
- source、target、mapping 登记和迁移。
- 用户同步基线、共享同步状态和发布事务。
- 对用户权威工程的发布写入及其恢复状态。

不同 workstream 的源码编辑、构建、测试和只读扫描不需要取得该锁。

管理脚本按以下顺序工作：

```text
只读扫描并生成计划
→ 获取工作区 Mutex
→ 重新读取共享状态和计划涉及的文件
→ 确认计划仍然适用
→ 执行配置或 Git 操作
→ 验证结果
→ 释放 Mutex
```

- 等待超时就结束本次写入并报告资源忙，不创建持久锁文件，也不强行抢锁。
- 锁内重新读取是强制步骤，不能继续使用锁外的旧 JSON、Git 状态或哈希。
- JSON、JSONL 和清单先写同目录临时文件，解析并验证通过后再原子替换。
- 同一进程不得嵌套申请另一把工作区管理锁；第一版不拆分源组锁或发布锁。
- 互斥锁只能协调遵守协议的脚本，不能阻止用户直接编辑文件；因此所有关键写入仍必须执行哈希前置校验。

## 多对话并行

一个公共集成副本只用于汇总，不直接作为所有对话的共同写入目录。

```text
用户权威源
    -> sources/<source-id>/integration/
    -> work/<workstream-id>/sources/<source-id>/
```

- 每个独立逻辑任务使用独立 workstream、私有 Git 分支、worktree 和构建输出。
- 新逻辑任务默认创建新 workstream；用户明确续接已有任务，或运行环境能够唯一识别已有绑定时才复用。
- 一个 workstream 可以同时挂载多个源组的 worktree。
- 不同 workstream 不直接写同一物理源码文件。
- 新任务、范围扩大、构建前和发布前读取其他活动或仍有未处置改动的 workstream；写入路径范围重叠时先协调。
- 同一对话中的子 Agent 由主 Agent 分配边界，同一文件同时只能有一个写入者。
- workstream 可以合入集成副本进行汇总验证，但集成副本不能作为发布差异来源；发布必须绑定明确的 workstream 提交和固定提交的依赖闭包。
- 不使用容易因异常退出而遗留的手工锁文件。
- 所有 Codex 任务必须在纯净 Agent 工作区根的 `Local` 环境启动。`integration/` 和 linked worktree 不得单独添加、保存或打开为 Codex 项目；进入子目录修改或构建不改变任务启动时已加载的根规则。
- 初始化系统不在 `integration/` 或 worktree 中额外生成规则文件。用户工程原有的 `AGENTS.md` 等同名文件作为工程内容原样保护，但不属于本系统的生效规则。

## Workstream 状态记录

每个 workstream 使用机器清单和人类状态快照，不采用不断追加的聊天流水日志：

```text
work/<workstream-id>/
|-- workstream.json
|-- README.md
|-- sources/
|   `-- <source-id>/
|-- reference-copies/
|-- tools/
`-- artifacts/
```

`workstream.json` 是唯一机器事实源，至少记录：

```json
{
  "schema": 1,
  "id": "20260910-motor-stall-a13f",
  "status": "active",
  "title": "motor stall protection",
  "conversation": {
    "primary": null
  },
  "scope": [
    {
      "source_id": "motor-product",
      "targets": ["motor-controller"],
      "paths": [
        {
          "path": "firmware/motor-controller",
          "access": "write"
        }
      ]
    }
  ],
  "agent": {
    "refs": {
      "motor-product": {
        "branch": "workstream/20260910-motor-stall-a13f",
        "worktree": "work/20260910-motor-stall-a13f/sources/motor-product",
        "mapping_revision": 3,
        "user_baseline_commit": "<commit>",
        "task_base_commit": "<commit>",
        "head_commit": null
      }
    }
  },
  "dependencies": [
    {
      "workstream_id": "20260910-shared-protocol-a13f",
      "refs": {
        "motor-product": {
          "task_base_commit": "<dependency-task-base-commit>",
          "head_commit": "<dependency-head-commit>",
          "mapping_revision": 3
        }
      }
    }
  ],
  "has_unresolved_changes": false,
  "updated_at": "2026-09-10T00:00:00+08:00"
}
```

- 当前运行环境能够稳定提供 `host_id` 和 `thread_id` 时，可以写入 `conversation.primary`；这些字段始终可选，不能成为创建或使用 workstream 的前提。
- 对话标题和目录名不能代替稳定 ID。用户明确说“继续某任务”时按 `workstream-id` 或唯一匹配绑定；无法唯一判断时才询问。
- 一个对话同一时刻只绑定一个活动 workstream。切换任务时更新状态或解绑，不覆盖历史关系。
- `scope` 使用 `source-id + 规范化相对路径 + access`；Windows 路径比较不区分大小写，拒绝 `..` 和真实路径越界。
- 范围先按任务需要粗粒度登记，只在扩大写入范围或发布前更新，不要求每次编辑都改清单。
- 不同源组只有在真实路径也不重叠时才可视为独立；只读范围通常不阻塞其他任务写入，高影响生成器、链接脚本和 IDE 元数据的并发写入始终报告。
- `completed` 或 `abandoned` 只有在 `has_unresolved_changes: false` 时才退出冲突检测。
- 每个依赖必须引用具体 `workstream_id`、每个相关源组的 `task_base_commit`、`head_commit` 和 `mapping_revision`；不得只引用仍会变化的分支名。
- 依赖提交必须在对应源组私有 Git 中可取回；依赖关系必须无环，并按固定提交展开。
- 依赖任务后续产生的新提交不会自动混入当前任务；只有用户或 Agent 明确重新固定依赖后才更新依赖闭包，并重新检查冲突。
- `task_base_commit` 可以是已固定依赖的合并起点；当前任务自己的发布差异仍只取 `task_base_commit..head_commit`，固定依赖差异按闭包另行计入。

`README.md` 只供人阅读和交接，推荐结构：

```text
## Goal

## Current state

## Decisions

## Changes

## Verification

## Next
```

只在下列时机更新：

- 开始修改工程或产生需要交接的长期决策时。
- 目标、范围或关键方案变化时。
- 完成一组有意义的修改和验证时。
- 暂停、阻塞、交接或完成前。

不记录完整聊天、每条命令、完整构建输出或无关浏览过程。Git 记录“改了什么”，`README.md` 记录“为什么、当前状态和下一步”。全局状态直接读取各 `workstream.json`，不维护重复的 `workspace-management/workstreams/` 手写索引。

## 用户工程导入与发布

只定义三个方向明确的操作：

- `inspect`：只读检查用户工程。
- `import`：用户工程到 Agent 集成副本或当前 workstream。
- `publish`：当前 Agent workstream 到用户权威工程。

### 任务开始导入

每次开发任务开始时先执行不落盘的轻量检查：

- 有 Git 时比较提交和工作区差异。
- 无 Git 时先比较文件清单、大小和修改时间，只对变化候选计算哈希。
- 只扫描已登记源路径，不扫描整台电脑。
- 用户明确要求“只检查”“只读”或“不更新任何状态”时，检查结束后只报告结果，不执行导入或任何事实更新。
- 用户变化、Agent 未修改相同位置时自动导入。
- 双方修改不同文件或文本文件不同区域时可以三方合并。
- 同一位置、删除与修改、二进制、生成代码或 IDE 元数据冲突时停止该文件同步并报告。
- 长任务在构建前和发布前再次检查相关文件。

每次成功导入都在对应源组私有 Git 中创建可取回受管内容的不可变用户同步基线提交，并使用稳定 ref 保持可达。哈希用于快速检测变化，Git 提交用于取回基线实际内容，两者不能互相替代。扫描不完整、文件不可读或路径被过滤时，不得把“未发现”判定为删除。

活动 workstream 安全导入新的用户变化后，必须先冻结任务检查点，再将任务自己的提交重放到新的用户同步基线和已声明依赖之上，同时更新 `user_baseline_commit` 与 `task_base_commit`。用户来源的变化不得留在 `task_base_commit..head_commit` 的任务差异中；重放产生冲突时停止并报告，不自动改写任务意图。

### 同步状态模型

动态状态位于被 Agent 管理 Git 忽略的 `workspace-management/sync-state/`：

```text
sync-state/
|-- sources/
|   `-- <source-id>.json
|-- indexes/
|   `-- <source-id>.jsonl
`-- transactions/
    `-- <publish-id>.json
```

`user-imported` 源组的 `sources/<source-id>.json` 至少记录：

```json
{
  "source_id": "motor-product",
  "mapping_revision": 3,
  "mapping_digest": "<sha256>",
  "user_baseline_id": "baseline-20260910-001",
  "user_baseline_commit": "<private-git-commit>",
  "user_baseline_ref": "refs/agent/user-baselines/baseline-20260910-001",
  "captured_at": "<timestamp>",
  "scan_complete": true,
  "file_index": "../indexes/motor-product.jsonl",
  "build_baselines": {
    "motor-controller/debug": {
      "last_successful_build_commit": null,
      "evidence_ref": "../../evidence/build-motor-controller-debug.json"
    }
  }
}
```

文件索引至少记录 `mapping-id`、相对路径、类型、大小、修改时间和 SHA-256。它只覆盖实际纳管的文件；敏感文件和明确过滤项不伪装成可由私有 Git 恢复的内容。

workstream 的身份、范围、`user_baseline_commit`、`task_base_commit`、`head_commit` 和依赖以 `work/<workstream-id>/workstream.json` 为准。逐源比较结果按需从源组状态、文件索引和 `workstream.json` 计算；不创建 `sync-state/workstreams/` 缓存，也不维护第二份任务状态。

### 发布意图

推荐表达：

```text
将工作区中的 Agent 工程同步到我的工程中。
```

不得将其实现为固定口令。所有明确表达“Agent 工作副本到用户权威工程”的同步、合并、应用或发布意图都触发相同流程，例如：

- 把 Agent 工程同步回我的工程。
- 将工作副本修改合并到原工程。
- 把当前 workstream 的改动应用到用户工程。
- 用工作区中的版本更新我的工程。

反方向表达属于 `import`。只说“同步工程”且方向或 workstream 不明确时询问一次。

### 发布流程

1. 提醒用户一次：保存相关 IDE 和编辑器文件；第一版不处理未保存缓冲区。
2. 在工作区 Mutex 内重新读取共享状态，冻结当前 workstream 的 `head_commit`，校验 `user_baseline_commit`、`task_base_commit`、固定依赖闭包、`mapping_revision` 和当前工作区状态。
3. 重新扫描用户权威工程，避免覆盖刚保存的修改；扫描必须完整且所有路径可唯一映射。
4. 使用 `user_baseline_commit`、用户当前内容和冻结的 `head_commit` 做三方比较；发布内容只来自 `task_base_commit..head_commit` 及固定依赖闭包，不能从整个集成分支推断。
5. 生成并冻结逐文件发布清单。每项包含 `source-id`、`mapping-id`、相对路径、显式 `add|modify|delete`、基线/用户/Agent/预期结果的 blob 或 SHA-256，并记录写入前置条件。
6. 对所有相关源完成统一 dry-run；任何三方冲突、映射歧义、范围外修改或不完整扫描都以零写入结束。
7. 为所有相关权威源创建恢复快照和 SHA-256 清单，排除已确认可重建的缓存和构建产物。
8. 在第一次写入前重新校验清单中所有目标：修改或删除的文件当前哈希必须仍等于 `user_hash`，新增文件必须仍不存在；任一不符都以零写入结束。
9. 禁止目录镜像覆盖、`/MIR`、`--delete` 或基于时间戳盲目覆盖；路径必须位于映射对应的权威根内，拒绝绝对路径注入、`..` 和链接越界。
10. 逐文件应用清单；每个文件替换前再次校验其前置哈希，使用同目录临时文件和原子替换；删除先移动到恢复区，不立即永久删除。
11. 校验实际文件结果与冻结清单一致，再在安全可用时构建用户工程。
12. 文件、构建和副作用结果按下述事务规则处理，最后才更新用户同步基线或构建基线。

多个权威源无法形成严格的文件系统原子事务，应采用“全部预检、全部备份、逐源应用、统一校验”。

发布事务写入 `transactions/<publish-id>.json`，正常状态为：

```text
planned -> backed_up -> applying -> applied -> file_verified -> completed
```

事务记录还应保存 `mapping_revision`、发布清单摘要和每个文件的写入前置哈希。工作区 Mutex 只在当前变更阶段持有；进入等待用户决定的状态前先持久化状态并释放 Mutex，非终态事务仍会阻止新的导入或发布，恢复操作重新取得 Mutex 并重新校验现场。

异常处理：

- `conflicted`：写入前发现冲突，用户工程零写入结束。
- `apply_failed`：路径、补丁应用或文件校验失败，自动回滚本事务已经应用的所有源；回滚每个文件前必须确认它仍是本事务写出的预期结果，回滚成功后标记 `rolled_back`，用户同步基线不变。
- 如果用户或其他程序在部分应用后再次修改了待回滚文件，无法证明其仍是本事务结果时不得覆盖，立即标记 `recovery_required` 并报告现场。
- `verification_failed`：文件已经正确发布，但用户工程构建失败。保留现场、发布差异、构建日志和恢复快照，停止自动修改、重试或重新生成，等待用户明确选择保留现状或回滚。
- 用户选择回滚构建失败的发布时，恢复所有相关源并验证，用户同步基线保持不变。
- 用户明确接受构建失败后的内容时，可以将该内容登记为新的用户同步基线，但对应目标和配置的 `last_successful_build_commit` 保持原值或 `null`，不得声称构建通过。
- 构建入口不可用或不能安全执行时，可以在文件校验成功后完成发布并推进用户同步基线，但必须记录“用户工程未完成构建验证”，构建基线不变。
- `recovery_required`：任何自动回滚失败后立即停止并报告，禁止开始新的导入或发布，直到恢复状态经过人工处理和验证。

发布事务还分别记录 `file_publish_status`、`build_status` 和 `side_effect_status`。允许值依次为 `pending|verified|failed`、`passed|failed|unavailable|not-run` 和 `clean|declared|review_required`，例如：

```json
{
  "file_publish_status": "pending",
  "build_status": "not-run",
  "side_effect_status": "clean"
}
```

其中 `output_paths` 和 `generated_write_paths` 的分类规则如下：

- `output_paths` 只包含相对目标根目录的可重建产物、缓存和日志；只有这类路径变化时，文件发布可以正常完成，不把变化纳入用户同步基线。
- `generated_write_paths` 包含构建时预计会修改的工程文件。它们必须互不重叠、不能越界；自动发现的路径先放在候选证据中，用户确认后才写入配置。
- 只有已确认的 `generated_write_paths` 发生变化且构建成功时，才将变化导入源组私有 Git，作为用户构建产生的基线内容推进用户同步基线；它不能混入当前 workstream 的 `task_base_commit..head_commit` 任务差异。
- 已确认生成路径发生变化但构建失败时进入 `verification_failed`，不推进任何基线，等待用户决定保留或回滚。
- 出现其他工程源码、配置或 IDE 文件变化时进入 `side_effect_review_required`：文件发布结果可以保持 `verified`，但暂停推进同步基线并阻止新的导入或发布，直到用户确认其归属。
- 用户确认某个未登记路径是正常构建行为后，将其登记为 `output_paths` 或 `generated_write_paths`；不正常的变化按恢复快照和哈希前置条件处理，不能覆盖用户后续修改。
- 构建命令、工具、工程配置、映射或路径分类发生变化时，相关分类标为 `stale`，重新确认和验证前按未登记副作用处理。

只有文件应用和校验成功，且不存在待用户决定的 `verification_failed` 或 `side_effect_review_required`，才能进入 `completed` 并推进用户同步基线。只有实际构建成功才更新 `last_successful_build_commit`。

## 软隔离和代码保护

- 用户明确要求只读、只检查或不更新状态时，本次任务进入最高优先级 `read-only` 模式：只允许不落盘的读取和计算，不创建或修改配置、目录、workstream、日志、备份、Git 提交或构建输出，也不运行已知会写文件的 IDE、生成器或构建命令。该要求同时覆盖普通事实刷新和初始化 Skill。
- 每次任务开始的轻量变化检查本身始终只读；只有不处于 `read-only` 模式的普通任务才能按既有规则自动导入和更新事实。
- 工作副本是强制默认架构，不能取消。
- 本 Skill 管理的 Agent 默认只读用户权威工程，普通开发、构建和生成操作在当前 workstream 副本内进行；用户本人、IDE 和编辑器内 Agent 插件的外部修改不受此只读边界限制。
- 写文件和运行工具前解析真实路径，确认写入位置属于当前 workstream 或明确允许的工作区管理目录。
- 日常 Codex 项目的根目录只能是独立纯净 Agent 工作区，用户权威工程不属于普通可写 workspace root。
- 不使用 Full Access 作为推荐工作模式；优先使用仅允许写工作区的沙箱配置。
- 这属于软隔离和行为约束，不能承诺操作系统层面的绝对不可写。
- 不自动执行 `stash`、`reset --hard`、覆盖式 checkout、`clean -fdx`、全局格式化或其他破坏性命令。
- 修改前重新读取文件；检测到同一位置的并发变化时停止该文件修改。
- Agent 只能看到已保存到磁盘的内容；未保存缓冲区第一版不处理。

最重要的残余风险是副本过期、发布冲突、IDE 未保存内容、生成器覆盖和构建钩子写错目录，而不是普通单文件编辑。

## IDE 和生成代码

- 副本作为新工程重新导入和 Build，不复用旧对象文件、依赖文件、ELF 或普通构建缓存。
- Eclipse 系 IDE 不复制 `.metadata`，为 Agent 副本使用独立 IDE workspace。
- 重新生成的 ELF 必须对应副本路径，避免调试信息跳回用户源码。
- 初始化时识别 `.ioc`、MCC、Harmony 等生成器配置、版本和输出范围。
- 默认不重新生成代码；需要生成时只在副本执行。
- 识别 `USER CODE BEGIN/END` 等保护区，默认只修改允许的用户区域。
- 生成前建立检查点和受影响文件快照，生成后审查差异并确认用户区仍存在。
- 用户已有修改位于生成器拥有区时必须说明覆盖风险。
- 检查 `.project`、`.cproject`、`.uvprojx`、`.ewp`、链接资源、路径变量和构建脚本中的绝对路径。
- 检查 pre/post-build 是否包含外部写入、签名、版本文件修改或自动烧录。
- 外部 SDK、Pack 和工具链可以保持外部只读引用，但不得通过构建反向修改用户权威工程。

## 构建命令自动发现

用户第一次通常不需要提供构建命令。Agent 按证据优先级自行发现：

1. 项目已有构建脚本、CI、README 和编辑器任务。
2. IDE 构建日志、历史命令、Makefile、CMake preset 或 Ninja 文件。
3. IDE 工程元数据中的目标、配置和输出目录。
4. 根据工程类型和本机安装工具生成的标准 CLI 候选。
5. 无证据的启发式推断只能标为 `candidate`。

每个目标的构建配置使用稳定且人类可读的 `build-id`，例如 `debug`、`release` 或 `bootloader`。显示名称或 IDE 配置名可以变化，但已登记的 `build-id` 不随大小写或显示名称自动改变；命令、证据和构建基线均使用 `<target-id>/<build-id>` 定位。

应识别的常见工程入口包括但不限于：

- `Makefile`、`CMakeLists.txt`、`CMakePresets.json`。
- `.project`、`.cproject`。
- `.uvprojx`。
- `.ewp`。
- `nbproject/`。
- `sdkconfig`、`idf_component.yml`。
- `west.yml`、Zephyr 工程特征。
- `platformio.ini`。
- Arduino CLI 相关配置。

Windows 工具发现顺序：

1. `PATH` 和 `Get-Command`。
2. 项目脚本、IDE 配置和环境初始化脚本。
3. 厂商环境变量。
4. Windows 软件安装注册信息。
5. `Program Files` 下已知厂商位置。
6. 开始菜单快捷方式的真实目标。

不递归扫描整块磁盘。工具绝对路径和易变本机信息写入 `targets.local.json`。

候选命令使用结构化表示，例如：

```json
[
  {"tool": "make", "args": ["-C", "Debug", "-j8"]},
  {"tool": "cmake", "args": ["--build", "build", "--config", "Debug"]},
  {"tool": "UV4", "args": ["-b", "Project.uvprojx", "-t", "Debug"]},
  {"tool": "IarBuild", "args": ["Project.ewp", "-build", "Debug"]},
  {"tool": "idf.py", "args": ["-C", "Project", "build"]}
]
```

Eclipse 系厂商 IDE 的 headless 参数必须依据具体版本和工程元数据生成，不能写死。

构建执行规则：

- 配置保存 `tool`、参数数组和相对 `cwd`，不保存整段 Shell 命令。
- 本机工具的实际可执行文件由 `targets.local.json` 中的工具 ID 解析。
- 使用 `System.Diagnostics.ProcessStartInfo` 的 `ArgumentList` 逐项传递参数，禁止 `Invoke-Expression`、字符串拼接、管道、重定向、`;` 和 `&&`。
- `cwd` 必须位于对应执行上下文允许的工程根内；所有写入目标必须落在已确认的 `output_paths`、`generated_write_paths` 或发布清单中，并拒绝 `..`、绝对路径注入和链接越界。
- 已登记的工具、SDK、Pack、许可证服务和受管包装脚本可以作为工程根外的只读输入。命令运行器不尝试从任意 CLI 参数猜测每个路径的读写性质，而是通过已登记工具、构建钩子审计和构建前后变化检查约束实际写入。
- 普通初始化、开发、构建和测试使用 `execution_context: agent-copy`；发布后的用户工程验证只能由发布事务显式使用 `user-authority`，不能成为普通任务的默认写入入口。
- 必须记录退出码、标准输出、标准错误和实际产生的预期产物。
- 厂商环境脚本只能通过受管包装脚本调用；包装脚本、工具路径或关键参数变化后，命令标为 `stale` 并重新验证。

### 构建命令与结果状态

构建命令本身的可信状态与某次工程构建结果分开记录：

- `candidate`：根据证据生成，但尚未成功验证。
- `verified`：该命令曾成功运行并生成或更新预期 ELF、HEX 或 BIN。
- `unavailable`：当前缺少工具链、依赖或授权凭据，无法执行。
- `unconfirmed`：命令存在潜在副作用，不能安全运行。
- `stale`：命令、工程路径、工具版本或关键依赖已经变化，需要重新验证。

每次构建结果单独使用 `passed`、`failed`、`unavailable` 或 `not-run`。源码错误导致当前构建失败时，保留此前已经验证的命令状态，只把本次结果记为 `failed`；只有命令或依赖本身变化才标为 `stale`。对应目标和构建配置的 `last_successful_build_commit` 只在实际构建成功并取得产物证据时更新。

### 安全初始构建条件

- 工具存在且版本查询成功。
- 工程、目标、配置、工作目录和输出目录明确。
- 默认构建只在 Agent 副本内写入；用户权威工程构建仅可由已冻结的发布事务在 `user-authority` 上下文中调用。
- 不需要重新生成源码。
- 已检查构建钩子，不包含烧录、擦除或未知外部写入。
- 不与正在运行的 IDE 争用同一 IDE workspace。

初始化阶段不得执行 `clean`、`rebuild`、删除构建目录、自动安装工具、转换工程系统或为了让构建通过而修改业务源码。退出码成功但产物未产生或未更新，不能把命令或本次结果标记为 `verified`、`passed`。

## 验证策略

使用“验证能力清单 + 最小充分验证”，不强制完整分层闭环。

| 验证能力 | 使用条件 |
| --- | --- |
| 构建 | CLI 工具链、许可证、依赖和配置可用 |
| 软件测试 | 项目已有测试入口，或逻辑可以脱离硬件运行 |
| 仿真 | 模拟器支持对应 MCU、板卡和相关外设 |
| 板级验证 | 板卡、探针、驱动、供电和端口映射明确 |
| HIL | 另有可控电源、仪器、夹具和自动断言接口 |

初始化阶段：

- 识别现有验证入口。
- 条件满足时验证一次普通构建。
- 不主动增加测试框架、模拟器或 HIL 系统。

日常规则：

- 修改源码后通常执行已验证的构建命令。
- 现有软件测试与改动相关时才运行。
- 现有模拟器确实覆盖当前行为时才运行。
- 行为依赖真实外设、电气、时序或多板通信时说明需要板级验证。
- 明确区分“构建通过”“软件行为通过”和“实物硬件通过”。

最终验证报告保持简短，例如：

```text
验证：MotorController Debug 构建通过；无现成软件测试；未进行板级验证。
```

## 硬件风险规则

- 初始化 Skill 不执行硬件操作。
- 用户已经明确要求烧录或调试指定目标后，不反复询问普通烧录、复位和串口操作。
- 探针或串口被占用时不强行抢占。
- 电机或高功率输出首次动作前提醒一次，本轮不重复。
- OTP、eFuse、永久读保护、不可逆锁定、Option Bytes、Bootloader 区和包含重要数据的全片擦除，每次必须确认。
- 不创建硬件资源锁、租约文件或后台协调服务。

## 敏感文件和复制策略

本节规则适用于把用户工程或外部参考导入 Agent 工作区的 `agent-import`；非空旧 Agent 工作区迁移直接从原目录复制，旧目录保持原样，是否登记为外部历史参考按批准计划决定，不创建额外初始化备份：

- 默认不复制 `.git` 元数据、IDE workspace 元数据、可重建缓存和普通构建产物。
- Keil 导入过滤 `.uvguix.*`、`.dbgconf` 等 IDE 用户状态及工程配置输出目录中的已知可重建产物；必要 `.sct` 链接脚本作为构建输入保留，不能因靠近输出目录而排除。
- 确定性识别的私钥、令牌、凭据、生产签名文件、工具链授权文件、激活凭据、许可证密钥和设备转储只列出，不复制。
- `LICENSE`、`NOTICE`、`COPYING`、`COPYRIGHT` 和第三方版权清单属于法律合规资料，随源码或参考工程保留并记录来源；不得按文件名中的 `license` 或单一扩展名笼统排除。
- 无法判断是法律说明还是授权凭据时标记为待确认，不复制、不删除原文件，也不从网络补全或臆造许可证。
- 高熵检测只产生警告，不能据此排除所有二进制，因为预编译库和固件可能天然高熵。
- 构建需要的秘密或授权材料优先通过环境变量、许可证服务器或外部只读路径引用。
- 明确允许复制的敏感文件或授权材料必须确认许可条款允许复制，且不得进入 Agent 管理 Git、源组私有 Git 或任务参考副本 Git。
- 预编译库、固件 blob、启动文件和链接脚本不能按扩展名笼统排除。
- 符号链接、junction 和外部 SDK 必须解析真实目标；不能默默展开为大目录或形成对用户工程的写回路径。
- 复制过程中检测源文件是否变化；变化时重试或报告快照不一致。

## 参考工程目录

管理根目录必须提供：

```text
reference-projects/
|-- README.md
`-- <reference-id>/
    |-- README.md
    |-- manifest.json
    `-- project/
```

用途和边界：

- 用于存放用户提供、从外部路径导入或从公开仓库取得的参考工程快照。
- 每个参考工程使用稳定、简短的 `reference-id`。
- `<reference-id>/README.md` 至少记录来源、获取日期、版本或提交、参考用途、适用目标、许可证、已知差异和是否经过构建验证。
- `<reference-id>/manifest.json` 记录导入时的受管文件清单和 SHA-256，由 Agent 管理 Git 跟踪，用于确认未纳入管理 Git 的 `project/` 快照没有变化。
- `project/` 保持参考工程自身目录结构；包装层 README 不覆盖项目原有 README。
- `reference-projects/README.md` 维护简短索引，帮助 Agent 只读取与当前任务有关的参考工程，禁止默认加载全部参考代码。
- 参考工程默认只读，不直接修改、不创建 workstream 分支、不进入 Agent 到用户工程的同步或发布流程。
- Agent 不得把参考工程自动识别为 MCU 开发目标或权威源，即使其中存在 `.ioc`、`.uvprojx`、`.ewp`、Makefile 等工程标志。
- 需要试改、构建或验证参考工程时，将所需快照复制到 `work/<workstream-id>/reference-copies/<reference-id>/project/`；在其外层创建 `README.md` 记录来源快照、快照哈希或版本、用途、创建时间、所属 workstream、构建状态和清理条件，不得覆盖参考工程自带说明或污染原参考快照。
- 每个可修改的参考工程副本自动建立独立的临时私有 Git 和导入基线，不纳入用户工程发布、不推送；只有对应 workstream 已完成且不存在未保留成果时才可以清理。
- 参考工程正文由内容清单和来源版本保证不可变，默认不进入 Agent 管理 Git；包装说明和索引由管理 Git 跟踪。来源不可重新取得且快照不可替代时先向用户报告，不自行改变 Git 边界。
- 需要将参考工程正式转为开发工程时，必须由用户明确表达提升意图，再登记为 `reference-promoted` 源组，执行敏感检查并建立源组私有 Git 基线；是否建立用户权威映射由用户另行决定。
- 导入参考工程时沿用敏感文件过滤规则，默认排除 `.git` 元数据、可重建缓存、构建产物和本机状态；保留并记录 LICENSE、NOTICE、版权说明、启动文件、链接脚本及必要预编译库。
- 公共仓库参考应记录精确提交或版本，避免仅记录可能变化的分支名。
- 引用或移植参考代码时，在当前 workstream 记录来源和适用许可证，不因“仅供参考”忽略授权条件。

用户手工放入 `reference-projects/` 的新内容在下一次 Agent 任务中进行轻量识别；无法确认包装边界、来源或敏感内容时先登记为待整理项，不擅自移动或重写。

## 持久项目知识和开发路径

跨 workstream 长期有效的产品定义、方案结论和开发路线统一进入 `project-docs/`，不把聊天流水或尚未确认的讨论直接当成项目事实。

```text
project-docs/
|-- README.md
|-- PRODUCT.md
|-- SOLUTION.md
|-- ROADMAP.md
|-- decisions/
|   `-- README.md
`-- versions/
    `-- README.md
```

职责边界：

- `project-docs/README.md` 提供当前阶段、权威文档入口和下一项关键决策的一屏索引。
- `PRODUCT.md` 记录最终产品目标、用户、使用场景和长期能力边界，不混入某一开发版本的暂时限制。
- `SOLUTION.md` 记录当前有效的统一方案、系统划分和关键约束，不保留已经失效的方案正文。
- `ROADMAP.md` 记录开发阶段、依赖顺序、当前状态和下一步；每个阶段至少包含目标、依赖、范围和退出条件。
- `decisions/YYYY-MM-DD-topic.md` 记录跨任务的重要选择、备选方案、取舍、证据、状态及来源 workstream。
- `versions/V<序号>-topic.md` 记录该版本目标、包含范围、明确不包含、完成标准和验证要求。

信息流转规则：

- 进行中的方案讨论、候选结论和任务证据先记录在 `work/<workstream-id>/README.md`。
- 普通 Agent 不得因一次讨论自动修改 `PRODUCT.md`、`SOLUTION.md` 或 `ROADMAP.md` 中的项目事实。
- 用户确认跨任务有效的结论后，才将其提升到 `SOLUTION.md` 或独立 decision；来源 workstream 和确认日期必须可追溯。
- 与旧结论冲突时，将旧 decision 标记为 `已替代` 并指向新 decision，不静默删除历史。
- 统一使用 `待确认`、`已确认`、`已推迟`、`已替代` 四种方案状态。
- Git 是项目演进的时间线；workstream 和项目文档不重复抄写完整变更历史。
- Markdown 是项目知识的单一事实源；XMind、图表和其他可视化只作为可选派生视图，不强制多份文档同步维护。
- `PRODUCT.md`、`SOLUTION.md`、`ROADMAP.md` 仅在能够填入真实内容时创建，不生成空正文占位文件。
- `decisions/` 和 `versions/` 属于固定目录骨架，初始化时创建目录和各自的职责 README；具体 decision 和 version 文件只在产生真实内容时创建。

出现多个目标间的稳定通信协议时，可以按需增加 `project-docs/interfaces/`；验证矩阵变复杂时可以按需增加 `project-docs/verification/`。这些是项目发展后再启用的能力，不是每个工作区的固定空目录。

阶段成果归档保持可选。只有用户明确要求且阶段退出条件已经验证时，才生成不可覆盖旧版本的自包含快照；归档位置和独立 Git 策略在实际需要时另行登记，不作为第一版初始化的强制内容。

## 工作区根目录和分类

三个入口文档始终位于实际 Codex 工作区根目录，保证启动任务时能够发现规则和用户说明：

```text
AGENTS.md
README.md
USER_GUIDE.md
```

所有分类都相对于固定的纯净 Agent 工作区根目录 `managed_root: .`。下列不含占位符的目录和所列 README、运行期指南及模板属于固定骨架，初始化时一次性创建；`<source-id>`、`<workstream-id>`、`<reference-id>`、发布恢复内容、证据、日志和项目知识正文等实例按实际操作创建：

```text
.git/                       # Agent 管理 Git
.gitignore                  # 管理 Git边界和本机状态排除
project-docs/
|-- README.md
|-- decisions/
|   `-- README.md
`-- versions/
    `-- README.md
reference-projects/
|-- README.md
`-- <reference-id>/
    |-- README.md
    |-- manifest.json
    `-- project/
sources/
|-- README.md
`-- <source-id>/
    |-- README.md
    `-- integration/
work/
|-- README.md
`-- <workstream-id>/
    |-- README.md
    |-- workstream.json
    |-- sources/
    |   `-- <source-id>/
    |-- reference-copies/
    |   |-- README.md
    |   `-- <reference-id>/
    |       |-- README.md
    |       `-- project/
    |-- tools/
    |   `-- README.md
    `-- artifacts/
        `-- README.md
workspace-management/
|-- README.md
|-- config/
|   |-- README.md
|   |-- workspace.json
|   |-- targets.json
|   `-- targets.local.json
|-- guides/
|   |-- README.md
|   |-- lifecycle-and-migration.md
|   |-- sources-targets-and-git.md
|   |-- workstreams-and-concurrency.md
|   |-- synchronization-and-recovery.md
|   |-- build-and-hardware.md
|   |-- references-and-project-knowledge.md
|   `-- configuration-schema.md
|-- schemas/
|   |-- README.md
|   |-- workspace.schema.json
|   |-- targets.schema.json
|   |-- targets-local.schema.json
|   |-- workstream.schema.json
|   |-- source-sync-state.schema.json
|   |-- publish-transaction.schema.json
|   |-- evidence.schema.json
|   `-- legacy-instructions-manifest.schema.json
|-- tools/
|   `-- README.md
|-- templates/
|   |-- README.md
|   `-- project-docs/
|       |-- README.md
|       |-- product.md
|       |-- solution.md
|       |-- roadmap.md
|       |-- decision.md
|       `-- version.md
|-- sync-state/
|   |-- README.md
|   |-- sources/
|   |   `-- README.md
|   |-- indexes/
|   |   `-- README.md
|   `-- transactions/
|       `-- README.md
|-- evidence/
|   `-- README.md
|-- recovery/
|   `-- README.md
|-- migration/
|   `-- README.md
|-- history/
|   |-- README.md
|   `-- legacy-instructions/
|       `-- README.md
`-- ide-workspaces/
    `-- README.md
```

规则：

- 纯净 Agent 工作区根目录只允许 Agent 管理 Git元数据、管理 `.gitignore`、三个入口文档和一级分类目录；用户权威工程永远不位于其中。
- 项目级长期事实进入 `project-docs/`，不与单个 workstream 的过程状态混写。
- 参考工程只进入 `reference-projects/<reference-id>/project/`，不得混入 `sources/` 或正式 workstream 工程。
- 正式源码保留在 `work/<workstream-id>/sources/<source-id>/` 内对应工程的原有相对位置。
- 参考工程的试改或构建副本进入 `work/<workstream-id>/reference-copies/<reference-id>/project/`。
- 一次性任务脚本进入 `work/<workstream-id>/tools/`。
- 可复用工作区工具进入 `workspace-management/tools/<purpose>/`。
- 普通 Agent 的按需运行规则进入 `workspace-management/guides/`；根 `AGENTS.md` 只负责选择当前任务需要的指南，不得要求每个任务全部读取。
- 后续普通 Agent 需要的本地模板进入 `workspace-management/templates/`；不得依赖初始化 Skill 安装目录中的隐藏资源。
- 分析报告、日志摘要和导出物进入当前 workstream 的 `artifacts/`。
- 同步状态进入 `workspace-management/sync-state/`。
- 构建和验证的结构化证据进入 `workspace-management/evidence/`；配置中只保存简短引用。证据 JSON 使用 `evidence/<kind>-<target-id>[-<build-id>].json` 形式的稳定名称，并由 `evidence.schema.json` 校验；大型 stdout、stderr、二进制报告和厂商原生日志保持其合适格式，由证据 JSON 记录相对路径、媒体类型和 SHA-256，不嵌入 JSON 正文。
- 发布恢复快照进入 `workspace-management/recovery/<publish-id>/`。
- IDE 独立 workspace 元数据进入 `workspace-management/ide-workspaces/`，不与用户 IDE workspace 混用。
- 每个职责边界目录必须包含 `README.md`，说明用途、所有权、Git 状态和清理规则。
- 不要求 MCU 工程内部每个源码子目录都创建说明文件。
- IDE 或构建系统强制位于工程根目录的文件和输出路径属于例外，不能为了分类破坏工程。
- Agent 不得把脚本、日志、下载文件、测试产物或临时文件直接放在工作区根目录。
- Agent 管理 Git只跟踪规则、模板、可移植配置、项目知识和任务元数据，并按“三套 Git 必须分离”中的清单忽略其他内容。
- Agent 管理 Git使根目录被 Codex 识别为 Git 项目，但只用于管理元数据；Codex 任务仍必须选择 `Local`，项目内部源码并行由本系统自己的 linked worktree 完成。
- 固定骨架中的空目录不是项目内容；具体参考工程、项目知识正文、workstream、证据、日志、恢复快照、迁移报告和历史记录仍按实际需要创建。迁移发生时必须在工作区启用前生成 `workspace-management/migration/initialization-report.md`；归档旧规则时必须同时生成 `workspace-management/history/legacy-instructions/manifest.json`。
- 创建 `<source-id>`、`<workstream-id>` 或 `<reference-id>` 等动态对象时，必须在同一受管操作中建立该对象规定的内部骨架和职责 README；不得先留下无法判断所有权或清理规则的半成品目录。

### 运行期工具与模板

初始化完成后，将日常任务需要的确定性脚本部署到 `workspace-management/tools/`：

- `lib/workspace-common.psm1`：统一提供真实路径规范化、工作区 Mutex、原子配置写入和结构化进程执行。
- `detect-targets.ps1`：轻量发现新增或变化的 MCU 工程。
- `import-sources.ps1`：按可逆映射导入用户已保存变化并维护用户同步基线。
- `preserve-user-changes.ps1`：将明确选定的内部用户修改分别保留为暂存区和磁盘提交，验证后恢复选定文件到 Agent 检查点。
- `import-reference.ps1`：导入只读参考工程及其来源信息。
- `create-reference-copy.ps1`：创建带独立私有 Git 基线的任务参考副本。
- `new-workstream.ps1`：创建或明确复用 workstream、分支、linked worktree 和机器清单。
- `invoke-build.ps1`：解析结构化命令，在指定执行上下文中运行构建并分类文件变化。
- `publish-workstream.ps1`：冻结任务提交，执行映射校验、三方预检、事务备份和受控发布。

`plan-migration.ps1` 随运行工具部署用于只读计划；初始化、迁移、刷新和策略升级仍由显式初始化 Skill 路由，普通任务不能因工具存在而自行升级约束。所有共享状态脚本复用同一套路径规范化、工作区 Mutex、原子配置写入和结构化进程执行函数，不能各自实现不同协议。

`workspace-management/templates/project-docs/` 保存 PRODUCT、SOLUTION、ROADMAP、decision 和 version 的本地格式说明或模板，使没有日常开发 Skill 的普通 Agent 也能按一致格式创建后续文档。模板只定义职责和必要字段，不包含虚构项目内容。

`workspace-management/guides/` 保存普通 Agent 的七份按需运行指南。它们与实际 Skill 中同名的 canonical references 同源部署，不维护两套内容；初始化、刷新或升级时通过哈希确认一致。根 `AGENTS.md` 只路由到当前任务需要的指南：

- 工作区初始化、迁移或规则升级：`lifecycle-and-migration.md`。
- 源组、目标、映射或 Git：`sources-targets-and-git.md`。
- workstream、并行或依赖：`workstreams-and-concurrency.md`。
- 导入、发布、冲突或恢复：`synchronization-and-recovery.md`。
- 构建、生成代码、验证或硬件：`build-and-hardware.md`。
- 参考工程或项目知识：`references-and-project-knowledge.md`。
- 配置字段、状态或 schema：`configuration-schema.md`。

普通任务不得默认读取全部指南、全部目标、全部 workstream、全部参考工程、完整文件索引或历史事务。脚本在标准输出中只返回当前操作的状态、数量、相关路径、阻断原因和下一步；完整 stdout、stderr、逐文件清单和证据保存在既定目录中，仅在失败、恢复或用户要求审计时读取。`read-only` 模式下不得为了保存这些信息创建日志或证据。

## 配置模型

工作区机器配置和动态状态统一使用 UTF-8 JSON/JSONL，不依赖外部 YAML 模块：

- 每类 JSON 都有受管 schema；字段说明进入 `configuration-schema.md` 或 schema 的 `description`，不依赖 JSON 注释，也不把机器字段手册塞进 `USER_GUIDE.md`。
- 每份 schema 必须为根对象和所有已知嵌套节点声明 `type`，把读取和安全判断必需的字段列入 `required`，并用 `enum` 约束有限状态值。关键校验不得只依赖 `format`；日期、ID、哈希或路径需要强制语法时使用 schema `pattern` 或确定性脚本校验。
- PowerShell 序列化必须显式指定足够覆盖 schema 的 `ConvertTo-Json -Depth`，将深度警告视为失败；临时文件写入后重新解析、按 schema 验证，并比较序列化前后 schema 关键路径的类型、值、数组长度和对象键，再执行原子替换。仅确认 `ConvertFrom-Json` 能重新解析不是往返一致性验证。
- JSONL 每行必须是一个完整 JSON 对象；读取失败或出现半行时视为状态不完整，不继续写入或把缺失记录解释为删除。
- 深度验证必须包含反例：故意以不足的 `ConvertTo-Json -Depth` 序列化多层配置，确认产生警告、嵌套对象发生类型变化，且结果被 schema 或往返类型比较拒绝，不能进入原子替换。
- 结构化证据统一使用 JSON，并由 `evidence.schema.json` 定义公共信封。公共必需字段至少包括 `schema`、`evidence_id`、`kind`、`captured_at`、`subject`、`result` 和 `artifacts`；`artifacts` 只保存原始产物引用及可用哈希，按 `kind` 需要的详细字段由 schema 约束。证据正文被 Agent 管理 Git 忽略，`evidence/README.md` 属于固定骨架并由 Agent 管理 Git 跟踪。
- 用户在 2026-09-13 提供的系统终端截图显示 PowerShell `7.6.6`，将其作为当前主机基准；Codex 内部运行时可能不同，因此实现和验收仍须记录脚本实际调用的 PowerShell 可执行文件路径、版本及 JSON/schema 能力，不能用另一个终端或运行时的版本替代。
- PSGallery 可达性、目标 PowerShell 对深层 JSON 的具体默认行为和 schema 能力必须在后续实现验收中实测，不在设计阶段预判；运行时不得安装解析依赖，也不能依赖默认序列化深度。

### `workspace.json`

保存工作区格式和策略版本，用于幂等刷新与受控迁移：

```json
{
  "workspace_schema": 1,
  "policy_version": 1,
  "workspace_state": "active",
  "layout_mode": "pure",
  "managed_root": ".",
  "initializer": "embedded-workspace-init",
  "initialized_at": "2026-09-12T00:00:00+08:00",
  "migration": {
    "migrated_from": null,
    "migrated_at": null
  }
}
```

- `workspace_schema` 表示目录和配置数据结构版本。
- `policy_version` 表示 Agent 行为规则版本。
- `workspace_state` 在新建或迁移期间为 `initializing`；只有完整验证后才能原子更新为 `active`。非 `active` 工作区不得执行日常开发、导入或发布。
- `layout_mode` 固定为 `pure`，`managed_root` 固定为 `.`；其他值视为需要迁移的旧格式，不能继续日常写入。
- `migrated_from` 只记录稳定的旧工作区引用 ID；默认将对应本机绝对路径登记在被忽略的 `targets.local.json`，明确选择 `RegisterLegacyWorkspace: false` 时不建立此历史路径绑定。`migrated_at` 和初始化报告用于说明迁移来源；旧工作区不自动纳入目标或参考工程索引。
- Skill 自身升级不会自动迁移已有工作区；只有显式刷新并确认具体计划后才改变结构或策略版本。

### `targets.json`

只保存可移植、可共享的工程事实，不保存绝对本机路径或秘密。

```json
{
  "schema": 1,
  "sources": {
    "motor-product": {
      "origin": "user-imported",
      "user_source": "configured",
      "integration_path": "sources/motor-product/integration",
      "write_policy": "explicit-publish-only",
      "sync_strategy": "three-way",
      "mapping_revision": 1,
      "mappings": [
        {
          "mapping_id": "motor-firmware",
          "integration_subpath": "firmware/motor-controller",
          "kind": "directory"
        },
        {
          "mapping_id": "shared-protocol",
          "integration_subpath": "shared/protocol",
          "kind": "directory"
        }
      ]
    },
    "sensor-node": {
      "origin": "agent-created",
      "user_source": "none",
      "integration_path": "sources/sensor-node/integration",
      "sync_strategy": "none",
      "mapping_revision": 0,
      "mappings": []
    }
  },
  "targets": {
    "motor-controller": {
      "source": "motor-product",
      "path": "firmware/motor-controller",
      "mcu": "STM32G0B1CBT6",
      "project": {
        "type": "stm32cubeide",
        "entry": ".project",
        "generator": "motor.ioc"
      },
      "builds": {
        "debug": {
          "configuration": "Debug",
          "cwd": "firmware/motor-controller",
          "default_execution_context": "agent-copy",
          "command": {
            "tool": "make",
            "args": ["-C", "Debug", "-j8"]
          },
          "command_state": "verified",
          "output_paths": ["Debug/**"],
          "generated_write_paths": ["Core/Inc/version.h"],
          "outputs": [
            "Debug/motor-controller.elf",
            "Debug/motor-controller.hex"
          ]
        },
        "release": {
          "configuration": "Release",
          "cwd": "firmware/motor-controller",
          "default_execution_context": "agent-copy",
          "command": {
            "tool": "make",
            "args": ["-C", "Release", "-j8"]
          },
          "command_state": "candidate",
          "output_paths": ["Release/**"],
          "generated_write_paths": [],
          "outputs": ["Release/motor-controller.elf"]
        }
      },
      "generated": {
        "policy": "edit-user-sections-only",
        "config": ["motor.ioc"]
      },
      "verification": {
        "test_command": null,
        "simulator_command": null
      },
      "hardware": {
        "warnings": ["motor"]
      }
    }
  },
  "field_metadata": {
    "/targets/motor-controller/mcu": {
      "provenance": "detected",
      "freshness": "current",
      "evidence_ref": "workspace-management/evidence/mcu-motor-controller.json"
    },
    "/targets/motor-controller/builds/debug/command": {
      "provenance": "detected",
      "verification": "verified",
      "freshness": "current",
      "evidence_ref": "workspace-management/evidence/build-motor-controller-debug.json"
    },
    "/targets/motor-controller/builds/debug/output_paths": {
      "provenance": "confirmed",
      "verification": "verified",
      "freshness": "current",
      "evidence_ref": "workspace-management/evidence/build-motor-controller-debug.json"
    },
    "/targets/motor-controller/builds/debug/generated_write_paths": {
      "provenance": "confirmed",
      "verification": "verified",
      "freshness": "current",
      "evidence_ref": "workspace-management/evidence/build-motor-controller-debug.json"
    },
    "/targets/motor-controller/generated/policy": {
      "provenance": "confirmed",
      "verification": "unverified",
      "freshness": "current"
    }
  }
}
```

普通值保持紧凑；只有目标身份、路径、MCU、工程入口、构建命令、生成代码策略等需要保护或追溯的重要字段，才在 `field_metadata` 中按稳定 JSON Pointer 记录元数据。无需为每个字段包装完整对象。

- `provenance` 使用 `detected|confirmed|imported`，表示值来自扫描、用户确认或既有配置导入。
- `verification` 使用 `unverified|verified|failed`，只表示该字段是否经过实际验证。
- `freshness` 使用 `current|stale|conflicted`，表示字段与当前工程和环境是否一致。
- 自动扫描只允许增加缺失值或更新 `provenance: detected` 的值；`confirmed` 值不得静默覆盖，新候选写入动态状态并报告。
- `verified` 只能由实际证据产生。工程路径、工具版本、命令或关键依赖变化时保留原值并标为 `stale`。
- 用户明确修改值时将 `provenance` 设为 `confirmed`，同时清除不再适用的旧验证状态。
- 构建失败保留命令配置并记录本次失败证据，不能把源码失败误报成命令配置失效。
- `output_paths` 和 `generated_write_paths` 只保存已经确认的分类；自动发现但未确认的候选保留在证据中。二者必须相对目标根目录、互不重叠且解析后不越界。

详细证据进入 `workspace-management/evidence/`，配置只保存简短引用。未知信息省略或使用 `null`，不能猜测。

### `targets.local.json`

保存本机易变信息，并加入 Agent 管理 Git 和所有代码私有 Git 的忽略规则：

```json
{
  "schema": 1,
  "workspace": {
    "root_path": "D:/CodexWorkspaces/MotorProduct",
    "execution_environment": "local"
  },
  "sources": {
    "motor-product": {
      "mappings": {
        "motor-firmware": {
          "source_path": "D:/Projects/MotorController"
        },
        "shared-protocol": {
          "source_path": "D:/Shared/ProductProtocol"
        }
      }
    }
  },
  "legacy_workspaces": {
    "legacy-workspace-001": {
      "path": "D:/Projects/OldAgentWorkspace"
    }
  },
  "tools": {
    "make": {
      "executable": "C:/Tools/GNU-Make/bin/make.exe"
    },
    "cubeide": {
      "executable": "C:/Tools/STM32CubeIDE/stm32cubeide.exe"
    }
  },
  "hardware": {
    "motor-controller": {
      "probe": "st-link",
      "probe_serial": null,
      "serial_port": null
    }
  }
}
```

不得在其中存放密钥。

`workspace.root_path` 的生命周期分为三段：初始化计划阶段只读解析候选真实根路径；用户确认后，在 `workspace_state: initializing` 阶段写入 `targets.local.json`；切换为 `active` 前重新解析并确认记录值仍与实际根路径一致。初始化期间文件尚未创建属于正常状态，不适用“本机配置缺失时不得写入”；只有激活后的普通任务才必须在 Codex `Local` 环境中从该路径启动，本机配置缺失、当前根路径不符或检测到外层 Codex-managed worktree 时不得写入。

具有用户权威源的源组，其 `mapping-id` 必须与 `targets.json` 一一对应。映射关系固定为 `source_path/<relative-path> <-> integration_path/integration_subpath/<relative-path>`，发布时按同一关系反向解析；任何纳入用户同步但无法唯一映射的文件直接停止。`agent-created` 或没有用户权威源的 `reference-promoted` 源组允许空映射且不能发布。动态文件哈希、用户同步基线、构建基线和发布事务写入 `workspace-management/sync-state/`，不要频繁改写人工配置。

## 根目录文档职责

### `AGENTS.md`

纯净 Agent 工作区只保留一个系统生成并生效的根 `AGENTS.md`，不创建根 `AGENTS.override.md` 或其他 fallback 指令文件。根文件采用“长期不变量 + 场景路由”，以 6 KiB 为软目标，并验证不超过当前 Codex 指令发现容量；不得为了达到大小目标删减安全约束。条件流程只指向 `workspace-management/guides/` 中的相关指南，不复制配置 schema、发布状态机、长示例或用户手册，也不要求普通任务一次读取全部指南。

根文件必须直接写明正确项目入口、真实根路径检查、`read-only`、`workspace_state`、用户工程默认只读、受管脚本和 Mutex、明确发布授权这组共同门禁。根文件与按需指南合计至少覆盖：

- 所有新任务在纯净 Agent 工作区根目录选择 Codex `Local` 环境启动；不对管理根使用 Codex-managed/permanent worktree，也不把 `sources/`、`integration/` 或 `work/` 中的代码副本单独添加为 Codex 项目。
- 对照 `targets.local.json` 校验当前真实根路径，并确认任务涉及的用户源和旧工作区参考路径可读；不满足时只报告，不自动改权限。
- 根据任务类型只读取相关运行指南、当前目标、当前 workstream 和必要状态；不默认加载完整索引、全部历史或无关参考工程。
- 开始普通任务前确认 `workspace_state: active`；`initializing` 候选只允许继续初始化、检查或放弃。
- 用户工程自带的同名规则文件作为工程内容保护，不是本工作区的生效规则；初始化系统不向代码副本额外生成规则文件。
- 已登记的迁移前旧工作区可以按需只读参考，但不自动扫描、构建、同步或发布，也不加载其中的旧规则作为当前指令；用户明确不登记时不建立历史路径绑定。
- 读取目标和本机配置。
- 按当前任务需要读取参考工程索引和相关参考项目，不默认遍历全部参考工程。
- 参考工程原快照保持只读，试改和构建只能在 `work/<workstream-id>/reference-copies/` 中进行。
- 读取 `project-docs/` 中与当前任务有关的产品边界、当前方案和开发路径；未确认的 workstream 结论不得自动提升为项目事实。
- 任务开始执行轻量目标与源变化检测。
- 新 MCU 工程自动识别来源并纳入对应源组私有 Git；Agent 自建工程不虚构用户源。
- 用户工程默认只读，普通写入只发生在 workstream 副本。
- 内部受管文件的用户直接修改先按明确范围保存到 `preserved-user/*`，验证后仅恢复选定文件到不变的 Agent HEAD；暂存区与磁盘内容分别保留，不处理无关改动或外部权威工程，混合修改先分离，结束时报告分支、提交和文件范围。
- 创建或明确复用 workstream，读取机器清单、固定依赖提交并检查其他活动任务的写入范围。
- 共享配置、Git 元数据、基线和发布只能由取得工作区 Mutex 的受管脚本更新。
- 所有 Git 操作显式传入管理根、源组 worktree 或已授权用户仓库路径；根 Git 状态不得代替源码仓库状态。
- 发现 submodule、嵌套 Git、既有 linked worktree 或 LFS 时暂停受影响源组，不自动展平或纳管。
- 按稳定 `build-id` 选择目标的构建配置，优先通过结构化命令运行器执行已验证命令，并按执行上下文和构建文件变化分类完成最小充分验证。
- 保护 IDE 生成代码和用户已有修改。
- 分类存放所有新文件。
- 更新 workstream 状态。
- 发布必须识别明确的 Agent 到用户工程意图并执行三方检查和备份。
- 用户同步基线与构建基线分开；发布只能来自冻结 workstream 提交和固定提交的显式依赖闭包。
- 用户工程 Git 提交只在明确要求时执行。
- 普通任务不得自行修改受管策略、目录模式和迁移工具；发现不适配时只提出调整方案。
- 使用初始化 Skill 更新已有约束时，展示计划后必须停止；用户确认前连日常事实登记也不得写入。
- 用户要求只读或只检查时，禁止一切落盘事实刷新、构建、备份和 Git 操作。
- 旧规则归档只供迁移审计，除非用户明确要求，否则不作为指令加载。

### 根 `README.md`

提供一屏可读的工作区概览、核心目录入口和当前管理状态，不复制完整使用手册。第一屏明确写明唯一 Codex 项目入口是当前根目录，任务必须选择 `Local`，不得使用根管理 Git创建外层 Codex worktree，也不得单独打开 `sources/` 或 `work/` 中的副本。

### `USER_GUIDE.md`

初始化后必须在根目录生成 UTF-8 中文用户手册，面向用户而非 Agent。内容至少包括：

1. 60 秒快速开始。
2. 用户权威工程、集成副本和 workstream 的区别。
3. 自动执行事项和需要用户明确表达的事项。
4. 用户工程 Git、Agent 管理 Git 和源组私有 Git 的区别。
5. 导入和发布的方向及自然语言示例。
6. 多 MCU、多权威源和多对话并行的使用方式。
7. `reference-projects/` 只读快照与 `work/<workstream-id>/reference-copies/` 任务副本的区别、实际位置、私有 Git 和清理条件。
8. 产品定义、方案记录、开发路线、决策和版本资料分别存放在哪里。
9. 如何从已有用户工程建立外部纯净 Agent 工作区，以及如何迁移非空旧 Agent 工作区。
10. 工作区规则如何提出升级计划、等待一次确认、验证、记录和回滚。
11. 迁移前旧工作区默认登记的只读参考用途、可明确排除旧规则与历史绑定，以及不从旧路径启动 Codex、不自动扫描、构建、同步或发布的规则。
12. 工作区固定目录骨架、职责 README 与按需生成内容的区别。
13. 用户同步基线与构建基线的区别，以及发布失败、构建副作用、同步冲突和恢复方法。
14. 未保存缓冲区、软隔离和板卡共享等已知边界。
15. 唯一根 `AGENTS.md`、旧规则归档和禁止单独打开 worktree 的要求。
16. 为什么任务必须使用 Codex `Local`、如何识别正确根路径，以及外部用户源不可读时如何处理。
17. 一个目标存在多个 `build-id` 时如何指定构建配置，以及根管理 Git与各源组代码 Git 的状态为何要分别查看。

用户手册还应说明内部受管文件的用户直接修改保存流程：暂存区和磁盘内容分别保留到 `preserved-user/*`，验证后恢复选定文件到 Agent 检查点，报告分支、提交和范围；与外部用户权威工程的导入/发布区分。编辑器内 Agent 插件属于外部用户工程一侧的写入者，已保存修改按正常三方导入处理，未保存缓冲区不可见，Codex 日常入口仍为纯净 Agent 工作区根目录的 `Local` 环境。

常用自然语言示例：

```text
把我的工程最新修改导入 Agent 工作区。
将工作区中的 Agent 工程同步到我的工程中。
重新扫描并登记新增 MCU 工程。
构建 motor-controller。
查看当前正在进行的任务。
继续之前的电机堵转保护任务。
为用户工程启用 Git。
恢复同步前的工程副本。
将 <path-or-url> 添加为参考工程。
参考 <reference-id> 分析当前驱动，但不要修改参考工程。
参考迁移前的旧工作区分析历史方案，但不要在那里修改或构建。
把 <reference-id> 复制到当前任务中供试改和构建。
将 <reference-id> 提升为正式开发工程；先作为 reference-promoted 源组，不建立用户发布映射。
更新已有工作区约束，先只展示迁移计划。
```

这些是示例，不是固定口令。

用户手册仅在以下情况下自动更新：

- 首次初始化。
- 工作区一级目录结构发生变化。
- 同步、Git、并行或恢复规则发生变化。
- 经用户确认的 Skill 升级或策略迁移改变用户使用方式。

新增普通目标、构建命令或 workstream 时不重写整份手册；当前事实以配置文件为准，避免重复信息过期。

## 受控进化和规则升级

工作区可以随项目推进持续适配，但必须区分“项目事实”和“管理策略”。

### 正常任务中的事实更新

完成初始化、当前没有待确认的约束迁移且用户没有要求 `read-only` 时，普通 Agent 可以幂等更新：

- 新源组、MCU 目标和稳定 ID。
- 工具链位置、候选构建命令及其验证状态。
- 参考工程索引和 workstream 当前状态。
- 用户已保存内容与 Agent 副本之间的同步事实。

这些更新不得改变根 `AGENTS.md`、固定纯净布局、同步策略、Git 策略、安全门槛或迁移工具。普通 Agent 发现现有规则反复不适配时，只在回复或当前 workstream 中说明问题并提出候选方案，不自行“优化”约束。

### 项目知识进化

- 新结论先留在 workstream，只有用户确认其跨任务有效后才提升到 `project-docs/`。
- 新增 MCU 或工具链不自动改变产品目标和开发阶段。
- 阶段切换必须满足已记录的退出条件，并由用户确认；完成状态不能仅凭 Agent 推断。
- 多目标出现稳定通信关系时可以提议增加接口文档；验证需求实际变复杂时可以提议增加验证矩阵。
- 旧决策被替代时保留可追溯关系，不直接改写成仿佛旧方案从未存在。

### 使用 Skill 更新已有工作区约束

显式调用 `$embedded-workspace-init` 更新规则、结构或策略时，采用严格的两阶段事务。

确认前只能执行只读审计和 dry-run，并在对话中展示：

- 当前和目标 `workspace_schema`、`policy_version`。
- 将创建、修改、移动或保留的文件和目录。
- 布局模式、源组、复制映射、排除项和 Git 边界变化。
- 对现有 workstream、项目文档、构建与同步的影响。
- 执行前备份、应用后验证和失败回滚方法。

展示具体计划后必须停止并等待用户明确确认。确认前不得：

- 创建或修改任何工作区文件、目录、备份或 Git 检查点。
- 更新 `targets.json`、构建状态、参考工程索引或 workstream。
- 改变版本号、写迁移历史或运行会产生输出的构建。
- 将正常任务中的自动事实更新夹带进本次升级操作。

用户未回应、明确拒绝或取消时，本次更新以零写入结束。用户只确认部分内容时，先生成删减后的新计划并再次等待确认，不能自行实施部分迁移。

用户确认完整计划后：

1. 重新读取当前状态；若相对计划发生实质变化，重新展示计划并再次确认。
2. 创建 Agent 管理 Git 检查点、受影响源组私有 Git 检查点和管理文件快照。
3. 需要替换根 `AGENTS.md` 时，先按“旧规则归档”保存上一版本及清单，再整体写入唯一的新规则文件；不使用受管区和用户自定义区拼接。随后执行幂等结构或配置迁移，保留稳定 ID、确认字段、已有副本和未提交改动。
4. 验证 JSON、路径引用、唯一根规则、fallback 排除、检测脚本、工作副本、三套 Git 和分类结构；能安全构建时再执行初始构建验证。
5. 成功后更新版本、必要的 `USER_GUIDE.md`，并在 `workspace-management/history/YYYY-MM-DD-policy-vN-to-vM.md` 记录原因、计划、批准、差异、归档清单、验证和回滚方法。
6. 验证失败时恢复管理文件和结构、验证回滚结果，并记录失败及已回滚的迁移尝试；不得触碰用户业务源码或隐式发布到用户工程。

根 `AGENTS.md` 由初始化系统整体管理，活跃工作区中只保留这一份生效规则。旧规则原文和元数据只进入历史归档，不复制到新规则；更新后的指令从下一次任务或重新打开工作区开始使用最可靠。

## 无日常开发 Skill 时的运行方式

短期内不需要另建日常开发 Skill。职责关系为：

```text
$embedded-workspace-init
    -> 部署规则、配置、工作副本和确定性脚本

根 AGENTS.md
    -> 约束后续任务

普通 Agent
    -> 按规则开发、构建、验证、交接和按需发布
```

只有从该项目作用域启动且支持 `AGENTS.md` 的 Agent 才能自动遵守这些规则。其他 IDE 插件或工具不一定遵守。未来只有出现稳定、频繁且仅靠 `AGENTS.md` 难以完成的日常工作流时，才考虑创建日常开发 Skill。

## 实际 Skill 建议结构

```text
embedded-workspace-init/
|-- SKILL.md
|-- agents/
|   `-- openai.yaml
|-- assets/
|   |-- AGENTS.md
|   |-- README.md
|   |-- USER_GUIDE.md
|   |-- directory-README.md
|   |-- initialization-report.md
|   |-- project-docs-README.md
|   |-- product.md
|   |-- solution.md
|   |-- roadmap.md
|   |-- decision.md
|   |-- version.md
|   |-- reference-project-README.md
|   |-- reference-copy-README.md
|   |-- workstream-README.md
|   |-- workstream.json
|   |-- legacy-instructions-manifest.json
|   |-- source-sync-state.json
|   |-- publish-transaction.json
|   |-- workspace.json
|   |-- targets.json
|   `-- schemas/
|       |-- workspace.schema.json
|       |-- targets.schema.json
|       |-- targets-local.schema.json
|       |-- workstream.schema.json
|       |-- source-sync-state.schema.json
|       |-- publish-transaction.schema.json
|       |-- evidence.schema.json
|       `-- legacy-instructions-manifest.schema.json
|-- references/
|   |-- lifecycle-and-migration.md
|   |-- sources-targets-and-git.md
|   |-- workstreams-and-concurrency.md
|   |-- synchronization-and-recovery.md
|   |-- build-and-hardware.md
|   |-- references-and-project-knowledge.md
|   `-- configuration-schema.md
`-- scripts/
    |-- lib/
    |   `-- workspace-common.psm1
    |-- init-workspace.ps1
    |-- plan-migration.ps1
    |-- apply-migration.ps1
    |-- refresh-workspace.ps1
    |-- detect-targets.ps1
    |-- import-reference.ps1
    |-- create-reference-copy.ps1
    |-- import-sources.ps1
    |-- preserve-user-changes.ps1
    |-- test-internal-user-changes.ps1
    |-- new-workstream.ps1
    |-- invoke-build.ps1
    `-- publish-workstream.ps1
```

- `SKILL.md` 只保留触发边界、初始化路由和关键安全约束，以 8 KiB 为软目标；超出时先消除重复和外移条件流程，不得为满足大小目标删除安全规则。
- 大段条件规则进入按需读取的 references；每次只读取当前路由需要的文件，同一 canonical reference 初始化后原样部署到 `workspace-management/guides/`，不维护重复版本。
- 稳定生成内容放入 assets。
- 目录创建、哈希、复制、Git 基线、差异检测和发布预检使用确定性脚本。
- 路径规范化、工作区 Mutex、原子配置写入和结构化进程执行集中在共享 PowerShell 模块中，避免各脚本产生不同安全语义。
- 脚本负责输出可复核的盘点事实并执行已确认的分类映射；Agent 根据事实制定迁移计划并处理语义歧义。当前脚本只支持规范中已经定义的初始化和迁移，不预先实现任意未来 schema 之间的通用迁移引擎。
- `initialization-report.md` 可以从模板生成；实际路径、清单哈希和结果必须由脚本填入，不能保留占位值。
- 初始化必须建立规范规定的完整固定目录骨架、职责 README、运行期指南、schema 和模板；动态对象与项目内容按实际操作生成，不创建空的参考工程、workstream、证据、日志、恢复快照或项目知识正文。
- `SPEC.md` 和设计期评审材料不进入实际 Skill 或已初始化工作区。

## 验收场景

实际 Skill 创建后必须保留既有 81 项行为验收，并补充本次轻量化产生的新验收。每项使用稳定的能力 ID，同时内联优先级和原编号；新增或重排时不得修改既有 ID，也不再维护一份容易失配的数字区间表。

- P0 是安全和最小端到端闭环，P2 是参考工程与项目知识基础能力；P0 和 P2 必须全部实现并通过，才能交付最小可用版本。P2 的目录、规则、模板和操作能力必须就绪；行为测试使用隔离样例，不能为了通过测试向实际初始化目标生成虚构的项目内容。
- P1 保留在完整功能范围内，在真实多源、并发、迁移或运维场景首次启用前完成对应专项验收；未通过时必须明确报告该能力尚未启用，不能静默降级或宣称整份规范已完成。
- 每项只能属于一个优先级。机器检查必须确认所有原编号 `1..81` 恰好出现一次、能力 ID 无重复，并明确列出尚未通过的 P1。

P1 不使用固定实施顺序，按真实触发条件选择专项门禁：非空旧工作区或规则升级验证相关 `MIG-*`；多个源组、分散映射或复杂 Git 拓扑验证相关 `MAP-*`、`GIT-*` 和多源 `SYNC-*`；第二个活动 workstream 或任务依赖验证相关 `WORK-*` 和 Mutex；用户选择启用用户 Git 时验证对应 `GIT-*`；构建命令、工具或工程配置变化时验证相关 `BUILD-*`。每次还要回归该场景影响到的 P0/P2，未触发的 P1 不阻止其他已验证能力。

- `CORE-01` `[P0; 原 1]`：全新空目录能初始化完整的纯净 Agent 工作区、固定目录骨架、职责 README、运行期指南、JSON schema、Agent 管理 Git 和三份根入口文档。
- `CORE-02` `[P0; 原 2]`：当前打开目录是用户工程时，Skill 只读建议外部空目录，确认前不在任一位置写入。
- `CORE-03` `[P0; 原 3]`：Agent 工作区与所有用户源的真实路径互不包含；符号链接、junction、映射造成的间接包含或已知的同一用户源多活工作区会阻止初始化。
- `MIG-01` `[P0; 原 4]`：非空且未初始化的候选 Agent 工作区在确认具体迁移计划前保持零写入。
- `MIG-02` `[P1; 原 5]`：非空旧 Agent 工作区迁移到新的空路径，旧目录保持不变；默认登记为 Agent 可按需读取的外部历史参考，可按明确批准计划不登记历史绑定。
- `CORE-04` `[P0; 原 6]`：配置只允许 `layout_mode: pure` 和 `managed_root: .`，不产生兼容模式或 `agent-workspace/`。
- `CORE-05` `[P0; 原 7]`：布局初始化不会在外部用户工程增加规则、说明、`.gitignore` 或 Agent 管理文件。
- `GIT-01` `[P0; 原 8]`：用户另行确认启用用户 Git时，才允许独立创建 `.git` 和必要 `.gitignore`。
- `CORE-06` `[P0; 原 9]`：活跃 Agent 工作区只有一个系统生成的根 `AGENTS.md`，没有根 override 或 fallback 规则。
- `MIG-03` `[P1; 原 10]`：默认旧 Agent 规则逐字节归档，独立清单保存原路径、时间和 SHA-256，归档文件不再被 Codex 发现；明确批准并绑定摘要的 `preserve-only` 不复制规则正文或归档清单。
- `CORE-07` `[P1; 原 11]`：外部用户工程原有的 `AGENTS.md`、override 和 fallback 文件保持原样。
- `CORE-08` `[P0; 原 12]`：初始化系统不向 integration 或 linked worktree 添加规则文件；初始化在用户确认后于 `initializing` 阶段建立 `workspace.root_path` 并在激活前复核，之后所有任务从该真实根目录以 Codex `Local` 环境启动，配置缺失、根路径不符或外层 Codex-managed/permanent worktree 会只读停止。
- `MIG-04` `[P1; 原 13]`：已登记的旧工作区可供 Agent 只读参考，但不会自动登记目标、构建、同步或发布，也不会加载旧规则为当前指令；明确不登记时无历史路径绑定。
- `MAP-01` `[P1; 原 14]`：单 MCU 与多 MCU 使用同一套源组和目标模型。
- `MAP-02` `[P1; 原 15]`：分散权威源通过多个稳定映射保持必要相对拓扑，不复制无关父目录。
- `MAP-03` `[P0; 原 16]`：映射便携结构位于 `targets.json`，本机绝对路径只位于被忽略的 `targets.local.json`。
- `MAP-04` `[P0; 原 17]`：每个纳入用户同步的集成文件都能唯一反向映射；无用户源的 Agent 自建或参考提升源组允许空映射且不可发布。
- `MAP-05` `[P1; 原 18]`：映射实际变化才递增版本；旧 workstream 或事务引用旧版本时不能发布。
- `MAP-06` `[P1; 原 19]`：Agent 自建工程使用 `origin: agent-created`、`user_source: none` 和 `sync_strategy: none`。
- `REF-01` `[P2; 原 20]`：参考工程提升后使用 `origin: reference-promoted`，不会自动虚构用户权威源。
- `MAP-07` `[P1; 原 21]`：后续新增 MCU 工程能够识别来源、稳定登记并纳入对应源组私有 Git。
- `MAP-08` `[P0; 原 22]`：重复扫描不会重复目标、重写确认字段、递增未变化映射或创建空提交。
- `MAP-09` `[P1; 原 23]`：稀疏 `field_metadata` 能区分来源、验证和新鲜度，扫描不会覆盖用户确认值。
- `BUILD-01` `[P1; 原 24]`：工程、工具或构建配置变化后，相关已验证字段会变为 `stale`；稳定 `build-id` 不因 IDE 显示名称变化而自动改变。
- `GIT-02` `[P0; 原 25]`：用户工程 Git、Agent 管理 Git 和源组私有 Git 的边界互不混淆；所有 Git 命令显式指定仓库，根 Git 状态不冒充源码状态。
- `GIT-03` `[P0; 原 26]`：Agent 管理 Git只跟踪规则、固定骨架职责 README、可移植配置、项目知识、指南、schema、工具、模板、历史和任务元数据，并按管理操作边界自动创建不夹带无关文件的检查点。
- `GIT-04` `[P0; 原 27]`：Agent 管理 Git会忽略代码仓库、参考正文、本机配置以及动态同步状态、证据正文、恢复数据和 IDE 状态，但会重新纳入这些目录的固定骨架 README；嵌套 README 的父目录也保持可遍历和可跟踪。
- `GIT-05` `[P1; 原 28]`：用户工程有 Git时不会自动提交或推送；无 Git时同意、拒绝和无回应进入正确状态。
- `GIT-06` `[P0; 原 29]`：每个受支持源组自动拥有独立私有 Git 和必要检查点；每个 `user-imported` 源组另有稳定用户基线 ref，所有私有 Git 均不向用户仓库推送。
- `GIT-07` `[P1; 原 30]`：普通单 Git 用户源的私有 clone能导入已保存的 dirty 和必要 untracked 内容；submodule、嵌套 Git、既有 worktree 或 LFS 会暂停该源组并展示拓扑，不被自动展平。
- `WORK-01` `[P0; 原 31]`：每个 workstream 使用固定 `work/<id>/sources/<source-id>/` linked worktree，不直接写公共集成副本。
- `WORK-02` `[P0; 原 32]`：`workstream.json` 是任务身份、范围、Git 基线和依赖的唯一机器事实源，README 只做人类交接。
- `WORK-03` `[P1; 原 33]`：对话 ID不可用时仍能创建 workstream；新任务默认新建，明确续接且唯一匹配时才复用。
- `WORK-04` `[P1; 原 34]`：范围使用 `source-id + 相对路径 + access`，扩大写范围和发布前都会检查冲突。
- `WORK-05` `[P1; 原 35]`：已完成但仍有未处置修改的 workstream 继续参与冲突检测。
- `WORK-06` `[P1; 原 36]`：多个 workstream 可以独立修改和构建，重叠写入会被报告，共享管理写入由单一工作区 Mutex 串行化。
- `WORK-07` `[P1; 原 37]`：汇总集成分支可以用于验证，但不会被直接用作发布差异来源。
- `SYNC-01` `[P0; 原 38]`：用户同步基线与构建基线相互独立；从未成功构建的工程仍能进行三方同步。
- `SYNC-02` `[P0; 原 39]`：`user_baseline_commit`、`task_base_commit` 和 `head_commit` 分别表达共同基线、任务起点和冻结结果。
- `SYNC-03` `[P0; 原 40]`：用户同步基线提交由稳定 ref 保持可达，能够取回所有实际纳管且未过滤的基线内容。
- `SYNC-04` `[P0; 原 41]`：文件索引记录映射、路径、类型、大小、时间和哈希，不把不完整扫描误判为删除。
- `SYNC-05` `[P1; 原 42]`：活动 workstream 导入新的用户变化后会重建用户和任务基点，用户来源的内容不会混入任务发布差异。
- `SYNC-06` `[P0; 原 43]`：发布只包含 `task_base_commit..head_commit` 和固定提交的显式依赖闭包，不夹带其他 workstream 的新提交。
- `SYNC-07` `[P0; 原 44]`：冻结发布清单逐文件记录映射、操作、基线、用户、Agent、预期结果和写入前置哈希。
- `SYNC-08` `[P0; 原 45]`：用户与 Agent 修改同一位置、映射变化、扫描不完整或写入前哈希变化时，发布在写入前停止。
- `SYNC-09` `[P0; 原 46]`：发布不会使用整目录镜像覆盖；每个文件原子替换，删除显式登记并先移入恢复区。
- `SYNC-10` `[P1; 原 47]`：多源发布先全部预检和备份，再逐源应用并统一校验。
- `SYNC-11` `[P0; 原 48]`：路径、补丁应用或文件校验失败会自动整体回滚，用户同步基线保持不变。
- `SYNC-12` `[P0; 原 49]`：文件正确发布但用户工程构建失败时保留现场和快照，等待用户选择保留或回滚。
- `SYNC-13` `[P0; 原 50]`：用户接受构建失败内容时只推进用户同步基线，不更新构建基线或宣称构建成功。
- `SYNC-14` `[P0; 原 51]`：构建不可用时可在文件校验成功后完成发布，但明确记录用户工程未完成构建验证。
- `SYNC-15` `[P0; 原 52]`：自动回滚失败会进入 `recovery_required`，阻止新的导入和发布。
- `SYNC-16` `[P0; 原 53]`：所有语义等价的 Agent 到用户工程表达触发同一发布流程，方向不清才询问。
- `BUILD-02` `[P0; 原 54]`：每个目标可通过稳定 `build-id` 保存多个构建配置；命令使用工具 ID、参数数组和相对工作目录，命令状态、单次结果和构建副作用分类分开记录。
- `BUILD-03` `[P0; 原 55]`：副本不复用旧缓存，并使用独立 IDE workspace 完成安全初始构建；用户工程验证只能由发布事务显式调用。
- `SAFE-01` `[P0; 原 56]`：`read-only` 是最高优先级模式，不创建配置、目录、日志、备份、Git 提交或构建输出。
- `SAFE-02` `[P0; 原 57]`：导入保留法律和版权说明，过滤授权凭据；用途不明确的文件进入待确认清单。
- `SAFE-03` `[P0; 原 58]`：疑似秘密不会自动复制或进入任何 Agent Git，高熵二进制不会被笼统排除。
- `CORE-09` `[P0; 原 59]`：脚本、日志、下载和测试产物不会出现在根目录；固定职责边界在初始化时具有准确 README，动态职责边界在创建时具有准确 README。
- `REF-02` `[P2; 原 60]`：参考工程按独立包装和内容清单导入，不会自动成为目标、源组或发布对象，原快照保持不变。
- `REF-03` `[P2; 原 61]`：任务参考副本具有来源、临时私有 Git 基线和清理条件，且不会参与用户工程发布。
- `REF-04` `[P2; 原 62]`：Agent 只按任务需要读取相关参考工程，不因参考目录增大而加载全部代码。
- `DOC-01` `[P2; 原 63]`：产品定义、当前方案、开发路线、决策和版本边界进入职责明确的 `project-docs/`。
- `DOC-02` `[P2; 原 64]`：未确认的 workstream 结论不会成为项目事实，新决策替代旧决策时保留关系。
- `MIG-05` `[P1; 原 65]`：约束升级展示只读计划；未确认、拒绝、取消或部分确认时整个操作零写入。
- `MIG-06` `[P1; 原 66]`：确认后的规则升级归档旧根规则，并为 Agent 管理 Git 和受影响的源组私有 Git 创建检查点；用户 Git 不会被自动提交。
- `MIG-07` `[P1; 原 67]`：日常事实更新不会夹带进待确认迁移，也不会在用户明确只读时发生。
- `MIG-08` `[P1; 原 68]`：仅刷新事实的重新扫描保持幂等；发现结构、策略、映射或 schema 迁移时整次转入计划模式。
- `MIG-09` `[P1; 原 69]`：旧工作区迁移直接从原目录复制到新的 `initializing` 工作区，不创建第二份初始化备份；复制发现源变化时停止并重新盘点。
- `MIG-10` `[P1; 原 70]`：新工作区记录 `migrated_from`、迁移时间和初始化报告，验证通过后才变为 `active`；旧目录不自动交换、移动或删除。
- `DOC-03` `[P0; 原 71]`：`USER_GUIDE.md` 能在不了解内部脚本的情况下解释 `Local` 入口、三套 Git、多构建配置、双基线、同步和恢复。
- `CORE-10` `[P0; 原 72]`：没有日常开发 Skill 时，普通 Agent 仍能找到按需运行指南、脚本、配置、schema、项目文档模板和任务状态。
- `SAFE-04` `[P0; 原 73]`：初始化不会修改业务源码、修复基线错误、安装工具、放宽外部目录权限、烧录硬件或强制完整测试体系；外部路径不可读时明确停止。
- `DOC-04` `[P2; 原 74]`：没有真实内容时不会生成空的 PRODUCT、SOLUTION 或 ROADMAP 正文。
- `CORE-11` `[P1; 原 75]`：同一工作区通过大小写、分隔符、链接或尾部分隔符的不同表示仍生成同一个 Named Mutex；锁超时不写入共享状态。
- `WORK-08` `[P1; 原 76]`：两个并行任务更新共享配置、Git ref 或 worktree 时由工作区 Mutex 串行化；锁内重读和原子替换不会丢失另一任务的更新。
- `BUILD-04` `[P0; 原 77]`：构建命令通过工具 ID、参数数组和 `ProcessStartInfo.ArgumentList` 执行，路径含空格、中文或特殊字符时不经过 Shell 重新解析。
- `BUILD-05` `[P0; 原 78]`：普通构建只能使用 `agent-copy` 上下文；`user-authority` 构建只能由已冻结发布事务调用。
- `BUILD-06` `[P0; 原 79]`：发布后只有 `output_paths` 变化时正常完成；成功构建产生的已确认 `generated_write_paths` 会作为用户构建内容导入基线，不进入任务发布差异。
- `BUILD-07` `[P0; 原 80]`：构建失败并修改生成文件，或出现未登记工程文件副作用时，不推进同步基线；后者进入 `side_effect_review_required` 并阻止新的导入和发布。
- `MIG-11` `[P1; 原 81]`：非空旧 Agent 工作区直接迁移到新的 `initializing` 路径，旧目录保持不变，按批准计划决定历史登记；源变化或验证失败不会启用新工作区。

本次轻量化新增以下验收：

- `DATA-01` `[P0; 新]`：除 `agents/openai.yaml` 和 Skill frontmatter 外，工作区结构化配置、状态、证据和机器清单统一使用符合 schema 的 JSON/JSONL，不依赖外部 YAML 解析模块；原生构建日志和其他非结构化产物保持其合适格式并由证据 JSON 引用。
- `DATA-02` `[P0; 新]`：JSON 写入显式设置序列化深度，将深度警告视为失败，并通过重新解析、含 `required|type|enum` 的 schema 以及关键路径类型和值往返比较后才原子替换；测试包含深度不足反例，并记录实际 PowerShell 路径和版本。
- `DATA-03` `[P0; 新]`：结构化证据符合 `evidence.schema.json` 的公共信封；原始日志和二进制报告保持独立并由相对路径、媒体类型和可用 SHA-256 引用，证据正文被忽略而固定 `evidence/README.md` 由 Agent 管理 Git 跟踪。
- `CONTEXT-01` `[P0; 新]`：`SKILL.md` 和根 `AGENTS.md` 的大小预算是软目标；超限时先去重和路由条件流程，任何安全规则都不会为满足预算而删除。
- `CONTEXT-02` `[P0; 新]`：普通任务只加载当前任务需要的指南、目标和状态，脚本默认只返回摘要，不读取完整 SPEC、全部参考工程、完整索引、历史事务或完整日志。
- `SYNC-17` `[P0; 新]`：不创建 `sync-state/workstreams/`；逐源比较按需从源组状态、文件索引和 `workstream.json` 计算，结果不成为新的权威状态。

接续实现新增以下验收：

- `GIT-08` `[P0; 新]`：选定内部用户修改先保存到经验证的可达分支，再恢复选定文件；暂存区和磁盘内容分别保留，包括仅暂存区修改。Agent HEAD、无关改动、无关暂存条目和外部权威工程保持不变；计划过期或发现秘密时禁止恢复。

接续回归还检查 Git 环境变量隔离、旧规则 `preserve-only`、不登记历史绑定，以及 Keil IDE 状态与输出过滤、必要 `.sct` 保留。JSON/JSONL 校验失败由调用方统一抛出明确 schema 错误，避免 PowerShell 本地化原始错误先行终止；校验、往返比较和写入门禁不放宽。

## 已明确删除或暂缓的设计

- 不使用专用账户、ACL、虚拟机或独立高权限 Publisher 做强隔离。
- 不承诺 Agent 在技术上绝对无法写用户工程。
- 不提供把 Agent 管理内容嵌入用户工程的兼容模式。
- 不把 integration 或 linked worktree 单独作为 Codex 项目，也不向其中额外生成 Agent 规则文件。
- 不支持在 Agent 管理根使用 Codex-managed 或 permanent worktree；项目内部并行只使用源组私有 Git的 linked worktree。
- 不实现硬件资源锁；只在资源占用时不抢占。
- 不处理编辑器未保存缓冲区；发布前只提醒保存一次。
- 不强制完整分层测试闭环。
- 不创建专用 Git 提交 Skill。
- 不创建日常开发 Skill，等实际重复需求出现后再决定。
- 不使用固定同步口令。
- 不进行后台实时监控。
- 不为发布事务进程中断增加独立日志恢复协议；第一版只保留现有事务状态、快照和人工恢复门槛。
- 不为同步过滤集合增加独立版本号；映射版本、文件索引和当前配置按现有模型处理。
- 不额外处理 Git clean/smudge、LFS 或换行转换的逐字节恢复语义；发布恢复依赖当前文件哈希和恢复快照。
- 不为非空旧工作区迁移再创建内容相同的初始化备份，也不实现原路径目录交换。

## 成功标准

- Skill 仅在用户显式调用时初始化或刷新工作区。
- 用户无需改变原有 MCU、IDE、编辑器或目录组织方式。
- 用户工程与纯净 Agent 工作区始终是两个互不包含的真实目录；Codex 日常任务只从登记的 Agent 工作区真实根目录以 `Local` 环境启动。
- 用户日常交互可以压缩为“提出任务、Agent 在副本工作、明确要求时发布”。
- 用户工程 Git、Agent 管理 Git、源组私有 Git、workstream 和同步方向始终不会在文档或实现中混淆。
- 多权威源、多 MCU 和多对话并行均能被同一模型表达。
- 已有用户工程可以无损导入外部 Agent 工作区，旧 Agent 工作区可以经确认迁移；参考工程与权威源、集成副本和 workstream 的职责始终清晰分离。
- 最小可用版本同时通过全部 P0 和 P2 验收；参考工程与项目知识能力从首个可用版本即存在，但具体内容仍由真实项目按需产生。
- 未确认的已有工作区迁移或约束升级不会产生任何写入；确认后的变化可验证、可审计、可回滚。
- 用户同步基线、workstream 任务基线和构建基线职责分离，发布只包含冻结任务提交和固定提交的显式依赖。
- 活跃 Agent 工作区只保留一个根 `AGENTS.md`；按批准计划归档的旧规则可追溯但不再生效，明确排除的旧规则仅留在旧路径。
- 复杂机械操作由已验证脚本完成，规则文档保持精简。
- 发生冲突时停止覆盖；发生可恢复故障时存在基线或快照。
- 所有事实性成功声明都有对应验证证据。
- 实际 Skill 使用 `quick_validate.py` 通过结构与元数据检查。
