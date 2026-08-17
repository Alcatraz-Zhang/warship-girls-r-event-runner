# 战舰少女R活动执行工作流：GitHub 公开发布设计

## 1. 目标

把已经验证过的战舰少女R活动执行工作流发布为普通、公开、可克隆的 GitHub 目录，而不是依赖 `.skill` 压缩包或专用安装器。

仓库目标地址为 `Alcatraz-Zhang/warship-girls-r-event-runner`，采用 MIT 许可证，默认分支为 `main`。仓库主要面向中文玩家，因此所有面向人的说明文档使用中文。

成功标准：

- 普通用户可以直接浏览、克隆或下载仓库；
- 通用 AI Agent 可以从 `WORKFLOW.md` 理解并执行流程；
- 支持 Skill 目录的工具可以直接识别根目录的 `SKILL.md`；
- 仓库不包含 `.skill` 文件、账号数据、游戏截图、存档、游戏资源或本期活动的临时攻略答案；
- 推送前和 GitHub Actions 均能验证脚本、JSON 与关键目录结构；
- 远端公开仓库可访问，并带有 `v0.1.0` 标签。

## 2. 发布方式比较与选型

### 方案 A：通用源码目录（采用）

仓库根目录直接保存工作流、脚本、参考资料、模板和评测。`WORKFLOW.md` 作为与平台无关的入口，`SKILL.md` 作为支持 Skill 约定的平台入口。

优点是可读、可审查、可修改，不需要专用安装器；缺点是不同 Agent 仍需根据自己的工具接口适配浏览器、截图查看和命令执行。

### 方案 B：只发布 `.skill` 包

安装方便，但格式面向特定技能安装器，不满足通用目录要求，因此不采用。

### 方案 C：完整应用或机器人

可以提供统一 UI 和运行时，但会引入服务、账号、配置与长期维护成本，明显超出本次发布范围，因此不采用。

## 3. 仓库结构

```text
warship-girls-r-event-runner/
├── README.md
├── WORKFLOW.md
├── SKILL.md
├── LICENSE
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── assets/
│   └── checkpoint-template.json
├── scripts/
│   ├── invoke-bounded-process.ps1
│   ├── resolve-mumu-target.ps1
│   ├── capture-mumu-state.ps1
│   ├── compare-mumu-visual-state.ps1
│   └── send-mumu-input.ps1
├── references/
│   ├── adb-recovery.md
│   ├── activity-operations.md
│   └── research-safety.md
├── evals/
│   └── evals.json
├── docs/
│   ├── evaluation.md
│   ├── design/2026-08-17-github-publication-design.md
│   └── implementation/2026-08-17-github-publication-plan.md
├── tests/
│   ├── validate-repository.ps1
│   ├── test-validate-repository.ps1
│   ├── test-mumu-safety.ps1
│   └── test-send-mumu-input.ps1
└── .github/workflows/validate.yml
```

不提交构建产物、测试截图、评测查看器、临时依赖、ADB 抓图目录、游戏二进制或活动账号检查点。

## 4. 文档设计

### README.md

作为中文首页，说明项目定位、能力、限制、目录结构、环境要求、快速开始、通用 Agent 使用方式、Codex 安装方式、安全边界、验证结果和免责声明。

README 明确：本项目不是无人值守刷图机器人，不包含任何一期活动的固定答案；实际执行必须重新研究当期活动并基于实时截图逐步操作。

### WORKFLOW.md

移除对某个 Agent 产品的专有称呼，定义通用能力接口：

- 运行本地 PowerShell/ADB 命令；
- 查看并理解截图；
- 通过浏览器读取当前攻略；
- 维护 JSON 检查点；
- 每次只根据一张新鲜证据执行一个输入。

内容覆盖动态 ADB、页面状态机、攻略研究、带路约束、搜索筛选、复制人技能核验、战况中心、答题、战斗结算、中断恢复和完成证据。

### SKILL.md

保留 `name`、`description` 和 `compatibility` 等机器可识别元数据；正文改为中文，并引用同一套脚本和参考文档。它不能成为与 `WORKFLOW.md` 冲突的第二套流程，二者共享相同的安全规则。

### 其他文档

- `CONTRIBUTING.md`：中文贡献流程、不得提交账号信息或游戏资源；
- `SECURITY.md`：中文说明 ADB、账号操作和凭据泄露问题的报告方式；
- `CHANGELOG.md`：使用中文记录版本变化；
- `docs/evaluation.md`：说明四组离线评测以及 2026-08-16 发布前旧标签版本一次历史运行中的 24/24 与基线 13/24，并明确当前中性化文本未重跑、不能推断波动性；
- `LICENSE`：标准 MIT 正文，版权主体使用 GitHub 账号 `Alcatraz-Zhang`。

脚本中的标识符、命令参数和错误字符串保留 ASCII 英文，以避免 Windows PowerShell 编码兼容问题；这不属于面向用户的说明文档。

## 5. 运行架构与数据流

通用 Agent 先读取 `WORKFLOW.md`，再按需读取参考文档：

1. `resolve-mumu-target.ps1` 动态发现 MuMu 实例和 ADB 端口，并输出设备指纹；
2. `capture-mumu-state.ps1` 生成唯一截图和 JSON 侧车；
3. Agent 分析当前截图，决定唯一下一动作；
4. `send-mumu-input.ps1` 校验设备指纹、截图哈希、时效和单次消费状态后发送一次输入；
5. Agent 重新截图、分类页面并更新工作区中的检查点；
6. 若发生重启、人工介入或画面不一致，旧证据立即失效，流程回到第一步。

仓库只提供工作流和工具，不保存任何用户运行产生的检查点或截图。

## 6. 错误处理与安全边界

- 多个 MuMu 实例同时匹配时拒绝猜测，要求明确 VM；
- 游戏不在前台、设备指纹变化、截图过期或侧车已消费时拒绝输入；
- 只在出击前选择入口，出击后不把路线条件卡当成可点击节点；
- 同名复制人必须核对实际启用的技能和等级，收藏只作为主力候选提示；
- 大破不前进，满船坞不擅自拆船或扩容；
- 不授权付费货币、账号设置、稀有资源拆解或其他不可逆操作；
- 不向仓库提交 GitHub Token、ADB 截图、账号 UUID、绝对用户路径、日志或游戏文件。

## 7. 验证设计

本地与 GitHub Actions 使用相同的四项无账号、无模拟器输入验证：

1. 仓库静态验证检查五个 PowerShell 脚本的语法，解析检查点与评测 JSON，核对必需文件和相对链接，并拒绝禁入文件与已知凭据模式；
2. 仓库验证器回归测试用隔离的临时夹具证明有效仓库可通过、各类无效结构会失败，且错误消息不会回显凭据材料；
3. MuMu 安全离线测试以假 CLI、假 ADB 和随机本机监听端口覆盖目标解析与截图取证的保护边界；
4. 输入助手离线假 ADB 测试证明过期证据被拒绝、缺坐标被拒绝、同一侧车只能消费一次。

GitHub Actions 运行在 `windows-latest`，只做静态验证和离线测试，不连接模拟器或外部游戏服务。

## 8. GitHub 发布设计

1. 在独立本地仓库中整理文件，避免把当前工作区的其他内容纳入提交；
2. 明确列出待提交文件并检查差异，不使用无范围的暂存；
3. 提交中文首版，提交信息为 `发布通用目录版 v0.1.0`；
4. 使用 `gh repo create` 创建公开仓库，并设置中文描述；
5. 推送 `main`，创建并推送 `v0.1.0` 标签；
6. 设置主题标签：`warship-girls-r`、`ai-agent`、`mumu`、`adb`、`automation`；
7. 通过 GitHub CLI 核验仓库可见性、默认分支、最新提交、标签和工作流状态；
8. 不创建 `.skill` Release 附件；首版只发布普通目录和 Git 标签。

## 9. 非目标

- 不固化当前或历史活动的具体答案、阵容和节点数据；
- 不提供无人监督长时间挂机；
- 不支持其他模拟器或其他游戏；
- 不把本次会话的评测产物和本地调试目录上传；
- 不自动修改用户现有的全局技能安装目录。
