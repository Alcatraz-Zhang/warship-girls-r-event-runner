# 战舰少女R活动执行工作流

## 项目定位

这是一个面向通用 AI Agent 的普通源码目录，用于在 Windows 与 MuMu Player 12 环境中研究、执行和恢复战舰少女R限时活动。任何能够运行本地命令、查看截图和浏览当期资料的 Agent，都可以直接阅读 [WORKFLOW.md](WORKFLOW.md) 执行；[SKILL.md](SKILL.md) 只是供支持技能发现约定的 Agent 读取的入口元数据。

本项目不是 `.skill` 归档，不依赖 Codex 专有格式或专用安装器。仓库固化的是可审查的操作方法和安全边界，而不是某一期活动的临时答案。

## 主要能力

- 动态发现 MuMu 虚拟机与当前 ADB 端口，并核验游戏前台和设备指纹；
- 为每一步生成唯一的新截图与 JSON 证据，做到一份证据只驱动一次输入；
- 实时检索并交叉核验当期攻略、路线、机制和题库；
- 把带路条件转换为出击前约束，使用搜索与筛选完成舰船和装备选择；
- 核对同名复制人的实际技能、形态和状态，处理战况中心、战斗结算与奖励链；
- 在重启、崩溃、ADB 超时、人工介入或画面不一致后，从检查点安全恢复。

## 适用与不适用

适用于：战舰少女R限时活动的首通、清图、答题、编队、战况增益规划、战斗、结算、奖励确认和中断恢复。实际执行仍需用户授权，并以实时游戏画面和当期资料为准。

不适用于：

- 无人值守的长时间挂机、反复刷资源或持续后台运行；
- 通用 Android 测试、ADB 调试、其他模拟器、其他游戏或日常养成工具；
- 只凭一张旧截图、固定端口或历史坐标直接操作；
- 提供或内置某一期活动的固定路线、题库答案、点击坐标、战况方案或账号进度。

每一期活动都必须重新检索、核验并记录资料的新旧与不确定性，不能把历史结论硬套到当前版本。

## 目录结构

- [WORKFLOW.md](WORKFLOW.md)：与具体 Agent 产品无关的完整主流程；
- [SKILL.md](SKILL.md)：支持技能发现的入口元数据和阅读顺序；
- [scripts/](scripts/)：目标解析、状态截图、有界进程、实时画面比较和证据绑定输入五个 PowerShell 脚本；
- [assets/checkpoint-template.json](assets/checkpoint-template.json)：复制到任务工作区使用的检查点模板；
- [references/](references/)：ADB 恢复、活动操作、研究与安全细则；
- [evals/evals.json](evals/evals.json)：四个离线评测场景及 24 条断言；
- [docs/evaluation.md](docs/evaluation.md)：评测结果、解释和限制；
- [tests/](tests/)：仓库静态验证与假 ADB 离线测试；
- [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [CHANGELOG.md](CHANGELOG.md)：贡献、安全报告与版本记录；
- [LICENSE](LICENSE)：MIT 许可证全文。

## 依赖

- Windows；
- MuMu Player 12；
- PowerShell 7（推荐，命令名为 `pwsh`）；Windows PowerShell 5.1 也通过离线兼容测试；
- 可用的 `adb`；
- Agent 的截图查看与画面理解能力；
- 能浏览并核验当期攻略、论坛或题库的浏览能力。

这些依赖不会随仓库一起安装。执行真实活动前，应先确认 Agent 能把自己的命令、截图、浏览和检查点工具映射到 [WORKFLOW.md](WORKFLOW.md) 定义的能力接口。

## 通用 Agent 快速开始

以下步骤只准备目录、检查点和只读计划，不会自动连接模拟器或发送游戏输入。

1. 克隆普通目录：

   ```powershell
   git clone "<仓库地址>" "<仓库目录>"
   ```

2. 让 Agent 先阅读 `<仓库目录>\SKILL.md` 和 `<仓库目录>\WORKFLOW.md`。不支持技能发现约定的 Agent 也可以直接从 `WORKFLOW.md` 开始。
3. 按任务需要阅读 `<仓库目录>\references\adb-recovery.md`、`activity-operations.md` 和 `research-safety.md`，不要一次加载无关资料。
4. 把检查点模板复制到当前任务工作区；运行中产生的账号进度、截图和侧车不得写回仓库或安装目录：

   ```powershell
   Copy-Item -LiteralPath "<仓库目录>\assets\checkpoint-template.json" `
     -Destination "<任务工作区>\checkpoint.json"
   ```

5. 先要求 Agent 只输出拟执行顺序和判定条件，核对目标范围、安全边界与所需授权：

   ```text
   请先阅读 <仓库目录>\SKILL.md、<仓库目录>\WORKFLOW.md，并按任务需要阅读 references。
   使用 <任务工作区>\checkpoint.json 作为检查点。在我明确授权真实操作前，
   只说明目标解析、截图取证、当期资料核验、单步输入和中断恢复计划；不要连接或点击模拟器。
   ```

6. 只有用户明确授权真实活动操作后，Agent 才按主流程动态解析目标、获取第一份新证据，并在每次输入后重新截图核验。

## Codex 可选目录安装示例

Codex 用户可以选择把同一普通目录克隆到个人技能发现目录 `$HOME/.agents/skills`；这只是可选的目录布局，不会把项目转换成 `.skill` 包，也不会改变 [WORKFLOW.md](WORKFLOW.md) 的通用性：

```powershell
$skillRoot = Join-Path $HOME ".agents\skills"
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
git clone "https://github.com/Alcatraz-Zhang/warship-girls-r-event-runner.git" (Join-Path $skillRoot "warship-girls-r-event-runner")
```

如果只希望在某个目标项目内使用，也可以放在该目标项目仓库根目录的 `.agents/skills/warship-girls-r-event-runner`。如果目标目录已经存在，应先审查现有内容并选择更新或另一个目录，不要用覆盖命令替换未知文件。运行检查点仍应复制到 `<任务工作区>`，不能保存在技能安装目录中。

## 运行安全原则

1. **动态目标与前台指纹：** 每次启动、恢复或异常后重新发现 ADB 目标，核验 VM 索引、启动与 Android 标识、游戏 PID、前台包与活动、分辨率和旋转；多个匹配目标时停止询问。
2. **新截图、单输入：** 当前页面只由唯一命名的新截图判断；每份未消费的侧车最多驱动一次点击、短滑动或允许的按键，输入后立即重新取证。
3. **复制人技能核验：** 同名候选必须打开详情核对攻略要求的精确技能与等级；收藏只是优先检查的定位信号，不是身份或技能正确的充分证据。
4. **只选入口，不手点路线：** 只在出击前选择游戏提供的入口；出击后的节点卡表示带路条件或结果，必须等待自动判路，不能手点节点“选路”。
5. **大破与爆仓阻塞：** 大破舰船不得继续前进；满船坞、满仓库或掉落空间不足时不得自行拆解、吞噬、解锁或扩容，应停下请用户处理或给出精确授权。
6. **活动点数单独授权：** 普通资源充足或一般代操作授权不包含有限活动点数；购买战况增益前必须取得当前方案或预算的明确授权。
7. **高风险操作明确授权：** 不可逆资产处置、付费货币、账号或安全设置，以及论坛、消息、云文档、代码托管等外部写入，都必须针对具体对象获得明确授权。
8. **不绕过保护：** 不得跳过前台与指纹核验、截图哈希和时效检查，也不得删除消费回执后盲目重发。

## 评测摘要

仓库包含四个完全离线的行为场景，共 24 条断言。在 2026-08-16 发布前旧标签版本的一次离线运行中，技能版得到 24/24，基线得到 13/24；后续中性化标签与中文等价性澄清未按当前文本重跑，因此这不是当前 JSON 逐字版本的新结果，也只能作为方向性证据。评测不连接真实模拟器，也不发送 ADB 输入。结果口径、四个场景和不可比较的指标详见 [docs/evaluation.md](docs/evaluation.md)。

## 贡献

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，保持改动小而聚焦，并运行其中列出的四项离线验证。若发现可能导致 ADB 误目标、保护绕过或敏感信息泄露的问题，请按照 [SECURITY.md](SECURITY.md) 私下报告。

## MIT 许可证

本项目采用 [MIT License](LICENSE)。

## 非官方免责声明

本项目是非官方社区工具，与游戏、模拟器、论坛或攻略站的相关方没有隶属、合作或背书关系。用户应自行确认并遵守游戏、模拟器及资料来源的适用条款，并自行承担自动化操作、第三方工具使用和账号相关风险。
