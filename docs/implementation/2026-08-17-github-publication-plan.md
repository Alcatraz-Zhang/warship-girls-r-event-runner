# 通用目录 GitHub 公开发布实施计划

> **供 Agent 执行：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，逐项执行下列复选步骤。

**目标：** 把已经验证的战舰少女R活动执行工作流整理成公开、MIT 授权、中文文档齐全的普通 GitHub 目录，并发布到 `Alcatraz-Zhang/warship-girls-r-event-runner`。

**架构：** 仓库以 `WORKFLOW.md` 作为平台无关入口，以 `SKILL.md` 作为支持 Skill 约定的平台入口；五个 PowerShell 脚本分别负责 MuMu 目标解析、唯一截图取证、有界外部进程、实时画面比较和单次证据绑定输入。静态验证脚本和离线假 ADB 测试在本地与 GitHub Actions 中复用，不连接真实模拟器。

**技术栈：** Git、GitHub CLI、PowerShell 7、ADB、MuMu Player 12、Markdown、JSON、GitHub Actions（`windows-latest`）。

---

## 文件职责

- `README.md`：中文项目首页、安装、使用、安全边界和免责声明。
- `WORKFLOW.md`：不依赖某个 Agent 产品的完整活动执行流程。
- `SKILL.md`：保留技能元数据，正文使用中文并指向同一流程资源。
- `LICENSE`：MIT 许可证，版权主体 `Alcatraz-Zhang`。
- `CHANGELOG.md`：中文版本变更记录。
- `CONTRIBUTING.md`：中文贡献规范和隐私限制。
- `SECURITY.md`：中文安全报告说明。
- `assets/checkpoint-template.json`：运行检查点模板。
- `scripts/invoke-bounded-process.ps1`：以有界超时执行 MuMu CLI 与 ADB 子进程，并在超时时终止本次进程树。
- `scripts/resolve-mumu-target.ps1`：动态发现并验证 MuMu/ADB 目标。
- `scripts/capture-mumu-state.ps1`：生成唯一截图及指纹侧车。
- `scripts/compare-mumu-visual-state.ps1`：用固定门限比较原证据与实时 A/B 画面。
- `scripts/send-mumu-input.ps1`：校验目标、侧车和实时画面并只发送一次输入。
- `references/*.md`：ADB 恢复、活动执行、研究与安全的中文细则。
- `evals/evals.json`：四组中文离线评测用例。
- `docs/evaluation.md`：中文解释评测结果和局限。
- `docs/design/*`、`docs/implementation/*`：已批准的设计与实施记录。
- `tests/validate-repository.ps1`：目录、语法、JSON、链接、隐私与禁入文件检查。
- `tests/test-validate-repository.ps1`：仓库验证器的离线回归测试。
- `tests/test-mumu-safety.ps1`：MuMu 目标解析与截图取证的离线安全测试。
- `tests/test-send-mumu-input.ps1`：输入助手的离线假 ADB 测试。
- `.github/workflows/validate.yml`：在 Windows Runner 上运行四项验证。

---

> **发布审查更新：** 下列任务 1–4 保留的是首次复制和建库时的历史执行顺序，其中嵌入的早期 validator 代码不再代表当前实现。发布前安全加固阶段由“任务 4A”接续：先加入真实 validator 回归测试并观察 RED，再更新 validator、检查点、评测与文档。当前 validator 会精确要求工作流和四个测试文件，因此不要脱离任务 4A 单独重跑早期任务的中间状态。

### 任务 1：先建立会失败的仓库验证

**文件：**

- 新建：`tests/validate-repository.ps1`
- 新建：`tests/test-send-mumu-input.ps1`

- [ ] **步骤 1：编写静态验证脚本**

`tests/validate-repository.ps1` 使用以下完整逻辑：

```powershell
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($RepositoryRoot)

$requiredFiles = @(
    'README.md',
    'WORKFLOW.md',
    'SKILL.md',
    'LICENSE',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'assets/checkpoint-template.json',
    'evals/evals.json',
    'scripts/resolve-mumu-target.ps1',
    'scripts/capture-mumu-state.ps1',
    'scripts/send-mumu-input.ps1',
    'references/adb-recovery.md',
    'references/activity-operations.md',
    'references/research-safety.md',
    'docs/evaluation.md'
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file is missing: $relative"
    }
}

foreach ($relative in @('assets/checkpoint-template.json', 'evals/evals.json')) {
    Get-Content -LiteralPath (Join-Path $root $relative) -Raw | ConvertFrom-Json | Out-Null
}

foreach ($scriptPath in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failed for $($scriptPath.Name): $($errors -join '; ')"
    }

    $bytes = [System.IO.File]::ReadAllBytes($scriptPath.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
        throw "PowerShell source must remain ASCII for Windows compatibility: $($scriptPath.Name)"
    }
}

$forbiddenExtensions = @('.skill', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.apk', '.aab', '.so', '.unity3d')
$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]'
}
$forbiddenFiles = @($files | Where-Object { $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() })
if ($forbiddenFiles.Count -gt 0) {
    throw "Forbidden binary or screenshot files found: $($forbiddenFiles.FullName -join ', ')"
}

$textFiles = @($files | Where-Object { $_.Extension -in @('.md', '.json', '.ps1', '.yml', '.yaml') })
$secretPattern = '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|' + 'C:\\' + 'Users\\[^\\\s]+)'
foreach ($file in $textFiles) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $secretPattern -AllMatches
    if ($matches) {
        throw "Sensitive token or user-specific absolute path found: $($file.FullName)"
    }
}

$markdownFiles = @($files | Where-Object { $_.Extension -eq '.md' })
$linkPattern = '\[[^\]]+\]\((?<target>[^)]+)\)'
foreach ($file in $markdownFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($content, $linkPattern)) {
        $target = $match.Groups['target'].Value.Trim().Trim('<', '>')
        if ($target -match '^(https?://|mailto:|#)') { continue }
        $pathPart = ($target -split '#', 2)[0]
        if (-not $pathPart) { continue }
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $pathPart))
        if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Markdown link escapes repository: $($file.FullName) -> $target"
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Broken relative Markdown link: $($file.FullName) -> $target"
        }
    }
}

$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw
if ($skill -notmatch '(?s)^---\r?\n.*?name:\s*warship-girls-r-event-runner\r?\n.*?description:.*?\r?\n---') {
    throw 'SKILL.md frontmatter is missing the expected name or description.'
}

Write-Output 'Repository validation passed.'
```

- [ ] **步骤 2：编写离线输入助手测试**

`tests/test-send-mumu-input.ps1` 必须使用 GUID 临时目录、假 resolver 和假 ADB，验证以下三项：

```powershell
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ("wgr-input-test-" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)

if (-not ([System.IO.Path]::GetFullPath($testRoot)).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary test directory escaped the system temp root.'
}

try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/send-mumu-input.ps1') -Destination $testRoot
    $fakeAdb = Join-Path $testRoot 'fake-adb.cmd'
    Set-Content -LiteralPath $fakeAdb -Encoding ascii -Value "@echo off`r`nexit /b 0`r`n"

    $resolver = @'
param([string]$Action, [string]$GamePackage, [switch]$RequireForeground, [Nullable[int]]$VmIndex)
[pscustomobject]@{
    Serial='127.0.0.1:19999'; VmIndex=0; BootId='test-boot'; AndroidId='test-android';
    GamePid='4242'; ForegroundPackage='com.huanmeng.zhanjian2';
    ForegroundActivity='com.test.UnityPlayerActivity'; PhysicalSize='1440x2560';
    OverrideSize=''; Rotation=1; AdbPath=(Join-Path $PSScriptRoot 'fake-adb.cmd')
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $testRoot 'resolve-mumu-target.ps1') -Encoding ascii -Value $resolver

    $screenshot = Join-Path $testRoot 'screen.bin'
    Set-Content -LiteralPath $screenshot -Encoding ascii -Value 'offline-test-image'
    $hash = (Get-FileHash -LiteralPath $screenshot -Algorithm SHA256).Hash

    function Write-Evidence {
        param([string]$Path, [DateTime]$CapturedAt)
        [pscustomobject]@{
            SchemaVersion=1; CapturedAtUtc=$CapturedAt.ToUniversalTime().ToString('o'); Stable=$true;
            ScreenshotPath=$screenshot; Width=1; Height=1; Sha256=$hash;
            Fingerprint=[pscustomobject]@{
                VmIndex=0; BootId='test-boot'; AndroidId='test-android'; GamePid='4242';
                ForegroundPackage='com.huanmeng.zhanjian2'; ForegroundActivity='com.test.UnityPlayerActivity';
                PhysicalSize='1440x2560'; OverrideSize=''; Rotation=1
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    $helper = Join-Path $testRoot 'send-mumu-input.ps1'

    $stale = Join-Path $testRoot 'stale.json'
    Write-Evidence -Path $stale -CapturedAt ([DateTime]::UtcNow.AddHours(-1))
    try {
        & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $stale -MaxEvidenceAgeSeconds 5 | Out-Null
        throw 'Stale evidence was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'evidence age') { throw }
    }

    $missing = Join-Path $testRoot 'missing.json'
    Write-Evidence -Path $missing -CapturedAt ([DateTime]::UtcNow)
    try {
        & $helper -Action Tap -EvidenceJson $missing | Out-Null
        throw 'Missing coordinates were accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'requires -X and -Y') { throw }
    }

    $singleUse = Join-Path $testRoot 'single-use.json'
    Write-Evidence -Path $singleUse -CapturedAt ([DateTime]::UtcNow)
    & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $singleUse | Out-Null
    try {
        & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $singleUse | Out-Null
        throw 'Consumed evidence was accepted twice.'
    } catch {
        if ($_.Exception.Message -notmatch 'already consumed') { throw }
    }
    $receipt = Get-Content -LiteralPath "$singleUse.consumed.json" -Raw | ConvertFrom-Json
    if ($receipt.Status -ne 'sent') { throw 'Input receipt did not record sent status.' }

    Write-Output 'Offline input helper tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
```

- [ ] **步骤 3：运行验证并确认它因核心文件尚未加入而失败**

运行：

```powershell
pwsh -NoProfile -File tests/validate-repository.ps1
```

预期：以 `Required file is missing: README.md` 失败。此失败证明验证器确实覆盖即将实现的仓库结构。

- [ ] **步骤 4：只提交验证基础**

```powershell
git add -- tests/validate-repository.ps1 tests/test-send-mumu-input.ps1
git commit -m "添加仓库离线验证"
```

---

### 任务 2：加入核心脚本、模板和通用工作流

**文件：**

- 新建：`WORKFLOW.md`
- 新建：`SKILL.md`
- 新建：`scripts/resolve-mumu-target.ps1`
- 新建：`scripts/capture-mumu-state.ps1`
- 新建：`scripts/send-mumu-input.ps1`
- 新建：`assets/checkpoint-template.json`
- 新建：`references/adb-recovery.md`
- 新建：`references/activity-operations.md`
- 新建：`references/research-safety.md`
- 新建：`evals/evals.json`

- [ ] **步骤 1：复制已经验证的机器文件**

从工作区的 `warship-girls-r-event-runner/` 精确复制三个脚本和检查点模板；不复制 `dist/`、评测工作区或截图。复制后逐文件比较 SHA-256，要求源文件与目标文件一致。

这里的源文件哈希只用于任务 2 初始复制时建立基线。进入发布前安全加固阶段后，目标仓库已加入后续安全加固、测试和场景中性化改动；此后的发布审查以目标仓库当前版本及新验证测试的结果为准，不再要求当前文件与旧工作区源文件保持相同哈希，也不得用旧源覆盖后续改动。

- [ ] **步骤 2：创建中文通用入口 `WORKFLOW.md`**

内容必须完整覆盖：能力接口、会话建立、动态 ADB、唯一截图、单证据单输入、当期攻略研究、路线约束表、搜索和筛选、复制人技能身份、战况中心、自动带路、战斗状态机、思维殿堂、中断恢复、检查点和不可逆操作边界。任何示例命令都使用 `<仓库目录>`、`<会话证据目录>` 等通用占位标记，不出现用户绝对路径。

- [ ] **步骤 3：把 `SKILL.md` 正文翻译并收敛为中文**

保留以下元数据语义：

```yaml
---
name: warship-girls-r-event-runner
description: 在 MuMu 12 模拟器中研究、执行并恢复战舰少女R限时活动，覆盖动态 ADB、实时截图、当期攻略、带路编队、舰船与装备搜索筛选、复制人技能核验、思维殿堂、战况中心、战斗、奖励、宝箱和功勋。用户提到战舰少女R活动首通、清图、继续战斗、NGA攻略、活动答题或模拟器中断恢复时使用；其他游戏、通用 Android 调试、日常养成讨论或一次性截图识别不使用。
compatibility: Windows、MuMu Player 12、PowerShell 7（pwsh）、adb、截图查看能力，以及用于检索当期攻略的浏览器。
---
```

正文引用 `WORKFLOW.md` 和三个中文参考文档，不重复制造另一套冲突流程。

- [ ] **步骤 4：翻译三份参考资料并保留行为约束**

逐项核对英文源文档中的每条安全规则均出现在中文版本，包括 ADB 别名去重、前台指纹、只选入口、复制人技能优先级、大破、满船坞/爆仓、活动点数、结算链和奖励完成证据。

- [ ] **步骤 5：把四组评测断言翻译为中文**

保持 `evals/evals.json` 的 ID、提示、预期输出和每组六条断言结构；只翻译说明文字，不修改测试语义。

- [ ] **步骤 6：运行局部语法检查**

```powershell
pwsh -NoProfile -Command "Get-Content assets/checkpoint-template.json -Raw | ConvertFrom-Json | Out-Null; Get-Content evals/evals.json -Raw | ConvertFrom-Json | Out-Null"
pwsh -NoProfile -Command '$failed = @(); Get-ChildItem scripts/*.ps1 | ForEach-Object { $tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $failed += "$($_.Name): $($errors -join "; ")" } }; if ($failed.Count) { throw ($failed -join "`n") }'
```

预期：两个命令均以退出码 0 完成。

- [ ] **步骤 7：提交核心工作流**

```powershell
git add -- WORKFLOW.md SKILL.md scripts assets references evals
git commit -m "加入中文通用活动执行工作流"
```

---

### 任务 3：补齐公开仓库文档和 MIT 许可证

**文件：**

- 新建：`README.md`
- 新建：`LICENSE`
- 新建：`CHANGELOG.md`
- 新建：`CONTRIBUTING.md`
- 新建：`SECURITY.md`
- 新建：`docs/evaluation.md`

- [ ] **步骤 1：编写中文 README**

README 依次包含：项目定位、主要能力、适用/不适用场景、目录结构、依赖、通用 Agent 快速开始、Codex 目录安装示例、运行安全原则、评测摘要、贡献入口、MIT 许可证和非官方免责声明。明确说明不提供当期固定答案，也不支持无人值守长时间挂机。

- [ ] **步骤 2：加入标准 MIT 文本**

`LICENSE` 使用标准英文 MIT 正文，首行为：

```text
MIT License

Copyright (c) 2026 Alcatraz-Zhang
```

- [ ] **步骤 3：编写其余中文文档**

- `CHANGELOG.md`：记录 `0.1.0 - 2026-08-17` 的通用工作流、三脚本、检查点、中文文档和离线验证；
- `CONTRIBUTING.md`：要求分支、最小变更、运行四项验证、禁止上传截图/账号/游戏资源；
- `SECURITY.md`：说明 ADB 误操作、目标识别、凭据或绝对路径泄露应私下报告，不在公开 Issue 中贴 Token；
- `docs/evaluation.md`：说明 2026-08-16 发布前旧标签版本一次历史运行中的技能版 24/24 与基线 13/24，明确当前中性化文本未重跑、每配置仅一次运行，且时间和 Token 指标不可比较；不上传原始会话评测目录。

- [ ] **步骤 4：运行 Markdown 相对链接检查**

运行：

```powershell
pwsh -NoProfile -File tests/validate-repository.ps1
```

预期：此时除尚未加入的 GitHub Actions 不属于 required files 外，静态验证通过。

- [ ] **步骤 5：提交公开文档**

```powershell
git add -- README.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md docs/evaluation.md
git commit -m "补齐中文公开文档和 MIT 许可证"
```

---

### 任务 4：加入 GitHub Actions 验证

**文件：**

- 新建：`.github/workflows/validate.yml`

- [ ] **步骤 1：创建 Windows 验证工作流**

```yaml
name: 验证通用目录

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    runs-on: windows-latest
    steps:
      - name: 检出仓库
        uses: actions/checkout@v4

      - name: 验证目录、JSON、PowerShell 与链接
        shell: pwsh
        run: ./tests/validate-repository.ps1

      - name: 运行仓库验证器回归测试
        shell: pwsh
        run: ./tests/test-validate-repository.ps1

      - name: 运行输入助手离线测试
        shell: pwsh
        run: ./tests/test-send-mumu-input.ps1

      - name: 运行 MuMu 安全离线测试
        shell: pwsh
        run: ./tests/test-mumu-safety.ps1
```

- [ ] **步骤 2：本地运行与 CI 相同的四项命令**

```powershell
pwsh -NoProfile -File tests/validate-repository.ps1
pwsh -NoProfile -File tests/test-validate-repository.ps1
pwsh -NoProfile -File tests/test-mumu-safety.ps1
pwsh -NoProfile -File tests/test-send-mumu-input.ps1
```

预期：分别输出 `Repository validation passed.`、`Validator regression suite passed: <断言数> assertions.`、`Offline MuMu safety tests passed.` 和 `Offline input helper tests passed.`。

- [ ] **步骤 3：提交 CI**

```powershell
git add -- .github/workflows/validate.yml
git commit -m "加入 Windows 离线验证工作流"
```

---

### 任务 4A：应用发布前安全与验证加固

**文件：**

- 新建：`tests/test-validate-repository.ps1`
- 修改：`tests/validate-repository.ps1`
- 修改：`assets/checkpoint-template.json`
- 修改：`evals/evals.json`
- 修改：`.github/workflows/validate.yml`
- 修改：评测、贡献、设计和发布审查文档
- 纳入现有离线测试：`tests/test-mumu-safety.ps1`、`tests/test-send-mumu-input.ps1`

- [ ] **步骤 1：先写并运行 validator 回归测试**

使用系统临时目录中的 GUID fixture 调用真实 validator，不使用 Pester 或子 PowerShell。先确认旧 validator 因接受无效 fixture 而 RED，再修改生产实现。

- [ ] **步骤 2：更新当前发布约束**

validator 从一次排除 `.git` 的文件枚举出发，统一执行显式 UTF-8、PowerShell AST/ASCII、严格 checkpoint/eval 结构、禁入类型、凭据、Markdown 和 frontmatter 校验；检查点只增加空字段，评测场景使用明确的虚构占位标签。早期源文件 SHA-256 仅是任务 2 的初始复制基线，当前发布以本任务的回归测试和目标仓库现状为准。

- [ ] **步骤 3：运行当前四项离线验证**

```powershell
powershell.exe -NoProfile -File tests/validate-repository.ps1
powershell.exe -NoProfile -File tests/test-validate-repository.ps1
powershell.exe -NoProfile -File tests/test-mumu-safety.ps1
powershell.exe -NoProfile -File tests/test-send-mumu-input.ps1
```

四项均必须退出 `0`；回归测试必须先有同一测试文件对旧实现产生的 RED 证据。此后再进入任务 5 的隐私和历史审查。

---

### 任务 5：发布前隐私、范围和历史审查

**文件：**

- 检查：整个仓库及 Git 历史

- [ ] **步骤 1：检查工作树与提交范围**

```powershell
git status -sb
git log --oneline --decorate
git ls-files
```

预期：工作树干净；只包含设计、计划、通用源码、文档、测试和工作流。

- [ ] **步骤 2：扫描隐私与禁入文件**

```powershell
rg -n --hidden --glob '!.git/**' '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|[A-Za-z]:[\\/]+Users[\\/]+|[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})'
rg -n --hidden --glob '!.git/**' '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
```

预期：第一条无 GitHub token 或 Windows 用户绝对路径；UUID 命中只允许逐项审查确认的虚构测试夹具，任何用户 UUID 或运行时 UUID 都是零容忍并必须移除。第二条只允许预期公开的 GitHub noreply 提交身份，其他邮箱均需核验并移除。随后确认不存在 `.skill`、图片、APK、SO、Unity 资源和评测工作区。

- [ ] **步骤 3：检查提交身份**

```powershell
git log --format='%h %an <%ae> %s'
```

预期：所有提交均使用 `Alcatraz-Zhang <93665866+Alcatraz-Zhang@users.noreply.github.com>`。

- [ ] **步骤 4：重新运行全部验证**

```powershell
pwsh -NoProfile -File tests/validate-repository.ps1
pwsh -NoProfile -File tests/test-validate-repository.ps1
pwsh -NoProfile -File tests/test-mumu-safety.ps1
pwsh -NoProfile -File tests/test-send-mumu-input.ps1
git diff --check
```

预期：全部成功且没有空白错误。

---

### 任务 6：创建公开仓库并推送 main

**文件：**

- 外部状态：GitHub 仓库 `Alcatraz-Zhang/warship-girls-r-event-runner`

- [ ] **步骤 1：再次确认远端仍不存在**

```powershell
gh repo view Alcatraz-Zhang/warship-girls-r-event-runner --json nameWithOwner
```

预期：GitHub 返回仓库不存在；若仓库已出现，停止并检查所有者及内容，不覆盖。

- [ ] **步骤 2：创建公开空仓库并连接 origin**

```powershell
gh repo create Alcatraz-Zhang/warship-girls-r-event-runner --public --description "战舰少女R活动执行工作流：MuMu 动态 ADB、攻略研究、编队、答题、战斗与中断恢复" --source . --remote origin
```

预期：创建公开仓库并添加唯一的 `origin`。

- [ ] **步骤 3：推送 main**

```powershell
git push -u origin main
```

预期：远端 `main` 指向本地最新提交。

- [ ] **步骤 4：设置主题标签**

```powershell
gh repo edit Alcatraz-Zhang/warship-girls-r-event-runner --add-topic warship-girls-r --add-topic ai-agent --add-topic mumu --add-topic adb --add-topic automation
```

---

### 任务 7：创建并推送 v0.1.0 标签

**文件：**

- 外部状态：Git 标签 `v0.1.0`

- [ ] **步骤 1：创建带说明的标签**

```powershell
git tag -a v0.1.0 -m "通用目录首个公开版本"
```

- [ ] **步骤 2：推送单个标签**

```powershell
git push origin v0.1.0
```

- [ ] **步骤 3：确认没有创建 `.skill` 附件或 GitHub Release**

```powershell
gh release list --repo Alcatraz-Zhang/warship-girls-r-event-runner
```

预期：没有 Release；版本通过普通 Git 标签提供。

---

### 任务 8：核验远端内容和工作流

**文件：**

- 只读核验：GitHub 远端

- [ ] **步骤 1：核验仓库元数据**

```powershell
gh repo view Alcatraz-Zhang/warship-girls-r-event-runner --json nameWithOwner,visibility,url,defaultBranchRef,description,repositoryTopics
```

预期：`visibility` 为 `PUBLIC`，默认分支为 `main`，描述和五个主题标签正确。

- [ ] **步骤 2：核验远端提交和标签**

```powershell
git ls-remote --heads origin main
git ls-remote --tags origin v0.1.0
```

预期：两项均返回对象 ID；远端 main 对象与本地 `HEAD` 一致。

- [ ] **步骤 3：检查 GitHub Actions**

```powershell
gh run list --repo Alcatraz-Zhang/warship-girls-r-event-runner --workflow validate.yml --limit 1 --json status,conclusion,url,headSha
```

若仍在运行，等待到完成；预期 `conclusion` 为 `success`。若失败，只读取日志、定位并修复仓库内问题，再提交和推送一次，不通过关闭验证来规避失败。

- [ ] **步骤 4：最终交付**

向用户报告仓库 URL、默认分支、最新提交、`v0.1.0` 标签、Actions 结果、MIT 许可证和本地发布目录；明确没有上传 `.skill`、截图或账号资料。
