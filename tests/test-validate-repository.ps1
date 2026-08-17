[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$validatorPath = Join-Path $PSScriptRoot 'validate-repository.ps1'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    throw 'The repository validator is missing.'
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureId = [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $systemTemp ("validator-fixture-$fixtureId")
$baselineFiles = @{}
$failures = [Collections.Generic.List[string]]::new()
$assertionCount = 0

function Assert-TemporaryFixturePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedCandidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $expectedPrefix = $systemTemp + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedCandidate
    if (-not $resolvedCandidate.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean fixture outside the system temp directory: $resolvedCandidate"
    }
    if ($leaf -notmatch '^validator-fixture-[0-9a-f]{32}$') {
        throw "Refusing to clean a non-GUID fixture directory: $resolvedCandidate"
    }
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Add-BaselineFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $baselineFiles[$RelativePath] = $Content
}

function Write-FixtureFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    Write-Utf8NoBomFile -Path (Join-Path $fixtureRoot $RelativePath) -Content $Content
}

function Reset-Fixture {
    Assert-TemporaryFixturePath -Path $fixtureRoot
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $fixtureRoot)
    foreach ($entry in $baselineFiles.GetEnumerator()) {
        Write-FixtureFile -RelativePath $entry.Key -Content $entry.Value
    }
}

function Read-FixtureJson {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    return [IO.File]::ReadAllText((Join-Path $fixtureRoot $RelativePath), $utf8NoBom) | ConvertFrom-Json
}

function Write-FixtureJson {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$Value
    )

    Write-FixtureFile -RelativePath $RelativePath -Content ($Value | ConvertTo-Json -Depth 30)
}

function Add-AssertionFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $failures.Add("${Name}: $Reason")
}

function Assert-Passes {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [scriptblock]$Arrange = {}
    )

    $script:assertionCount++
    Reset-Fixture
    & $Arrange
    try {
        & $validatorPath -RepositoryRoot $fixtureRoot | Out-Null
    }
    catch {
        Add-AssertionFailure -Name $Name -Reason ("valid fixture was rejected: " + $_.Exception.Message)
    }
}

function Assert-Fails {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Arrange,
        [string]$ForbiddenEcho
    )

    $script:assertionCount++
    Reset-Fixture
    & $Arrange

    $validatorFailed = $false
    $validatorMessage = $null
    try {
        & $validatorPath -RepositoryRoot $fixtureRoot | Out-Null
    }
    catch {
        $validatorFailed = $true
        $validatorMessage = $_.Exception.Message
    }

    if (-not $validatorFailed) {
        Add-AssertionFailure -Name $Name -Reason 'invalid fixture was accepted'
        return
    }
    if (-not [string]::IsNullOrEmpty($ForbiddenEcho) -and $validatorMessage.Contains($ForbiddenEcho)) {
        Add-AssertionFailure -Name $Name -Reason 'validation error echoed credential material'
    }
}

$checkpointJson = @'
{
  "schema_version": 1,
  "updated_at": null,
  "activity": {
    "name": null,
    "start_date": null,
    "end_date": null,
    "requested_scope": [],
    "definition_of_done": []
  },
  "emulator": {
    "vm_index": null,
    "serial": null,
    "source": null,
    "boot_id": null,
    "android_id": null,
    "model": null,
    "game_package": null,
    "game_pid": null,
    "foreground_package": null,
    "foreground_activity": null,
    "physical_size": null,
    "override_size": null,
    "rotation": null,
    "screenshot_path": null,
    "screenshot_sidecar": null
  },
  "current_state": {
    "page": null,
    "chapter": null,
    "map": null,
    "entrance": null,
    "progress": null,
    "blocker": null,
    "next_safe_action": null
  },
  "fleet": {
    "slots": [],
    "ship_identity_checks": [
      {
        "slot": null,
        "name": null,
        "form": null,
        "class": null,
        "level": null,
        "favorite": null,
        "candidate_count": null,
        "expected_skill": {
          "name_or_branch": null,
          "minimum_level": null
        },
        "observed_active_skill": {
          "name_or_branch": null,
          "level": null
        },
        "identity_verified": false,
        "evidence_sidecar": null
      }
    ],
    "route_constraints": [],
    "equipment_notes": [],
    "repair_supply_verified": false
  },
  "battle_center": {
    "points_remaining": null,
    "active_buffs": []
  },
  "completion": {
    "maps": [],
    "questions": [],
    "rewards": [],
    "boxes": [],
    "achievements": []
  },
  "sources": []
}
'@

$evalJson = @'
{
  "skill_name": "warship-girls-r-event-runner",
  "evals": [
    {
      "id": 1,
      "prompt": "Prompt one.",
      "expected_output": "Output one.",
      "files": ["README.md"],
      "expectations": ["One.", "Two.", "Three.", "Four.", "Five.", "Six."]
    },
    {
      "id": 2,
      "prompt": "Prompt two.",
      "expected_output": "Output two.",
      "files": [],
      "expectations": ["One.", "Two.", "Three.", "Four.", "Five.", "Six."]
    },
    {
      "id": 3,
      "prompt": "Prompt three.",
      "expected_output": "Output three.",
      "files": [],
      "expectations": ["One.", "Two.", "Three.", "Four.", "Five.", "Six."]
    },
    {
      "id": 4,
      "prompt": "Prompt four.",
      "expected_output": "Output four.",
      "files": [],
      "expectations": ["One.", "Two.", "Three.", "Four.", "Five.", "Six."]
    }
  ]
}
'@

$skillText = @'
---
name: warship-girls-r-event-runner
description: Runs an event safely.
compatibility: Windows PowerShell 5.1 or later.
---

# Fixture skill
'@

Add-BaselineFile -RelativePath '.github/workflows/validate.yml' -Content "name: validate`non: push`n"
Add-BaselineFile -RelativePath 'README.md' -Content "# Fixture`n"
Add-BaselineFile -RelativePath 'WORKFLOW.md' -Content "# Workflow`n"
Add-BaselineFile -RelativePath 'SKILL.md' -Content $skillText
Add-BaselineFile -RelativePath 'LICENSE' -Content "Fixture license.`n"
Add-BaselineFile -RelativePath 'CHANGELOG.md' -Content "# Changelog`n"
Add-BaselineFile -RelativePath 'CONTRIBUTING.md' -Content "# Contributing`n"
Add-BaselineFile -RelativePath 'SECURITY.md' -Content "# Security`n"
Add-BaselineFile -RelativePath 'assets/checkpoint-template.json' -Content $checkpointJson
Add-BaselineFile -RelativePath 'evals/evals.json' -Content $evalJson
Add-BaselineFile -RelativePath 'scripts/capture-mumu-state.ps1' -Content "Write-Output 'capture'`n"
Add-BaselineFile -RelativePath 'scripts/compare-mumu-visual-state.ps1' -Content "Write-Output 'compare'`n"
Add-BaselineFile -RelativePath 'scripts/invoke-bounded-process.ps1' -Content "Write-Output 'bounded'`n"
Add-BaselineFile -RelativePath 'scripts/resolve-mumu-target.ps1' -Content "Write-Output 'resolve'`n"
Add-BaselineFile -RelativePath 'scripts/send-mumu-input.ps1' -Content "Write-Output 'send'`n"
Add-BaselineFile -RelativePath 'references/research-safety.md' -Content "# Research safety`n"
Add-BaselineFile -RelativePath 'references/adb-recovery.md' -Content "# Recovery`n"
Add-BaselineFile -RelativePath 'references/activity-operations.md' -Content "# Operations`n"
Add-BaselineFile -RelativePath 'docs/evaluation.md' -Content "# Evaluation`n"
Add-BaselineFile -RelativePath 'tests/validate-repository.ps1' -Content "Write-Output 'fixture validator placeholder'`n"
Add-BaselineFile -RelativePath 'tests/test-validate-repository.ps1' -Content "Write-Output 'fixture validator test placeholder'`n"
Add-BaselineFile -RelativePath 'tests/test-mumu-safety.ps1' -Content "Write-Output 'fixture safety test placeholder'`n"
Add-BaselineFile -RelativePath 'tests/test-send-mumu-input.ps1' -Content "Write-Output 'fixture input test placeholder'`n"

try {
    Assert-Passes -Name 'baseline fixture'

    Assert-Passes -Name 'CRLF SKILL frontmatter is accepted' -Arrange {
        $skillPath = Join-Path $fixtureRoot 'SKILL.md'
        $skillText = [IO.File]::ReadAllText($skillPath, [Text.Encoding]::UTF8)
        $skillText = [regex]::Replace($skillText, "`r?`n", "`r`n")
        [IO.File]::WriteAllText($skillPath, $skillText, [Text.UTF8Encoding]::new($false))
    }

    Assert-Fails -Name 'missing required workflow' -Arrange {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.github/workflows/validate.yml')
    }
    Assert-Fails -Name 'missing validator regression test' -Arrange {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'tests/test-validate-repository.ps1')
    }
    Assert-Fails -Name 'missing bounded process helper' -Arrange {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'scripts/invoke-bounded-process.ps1')
    }
    Assert-Fails -Name 'missing visual comparison helper' -Arrange {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'scripts/compare-mumu-visual-state.ps1')
    }
    Assert-Fails -Name 'required file casing is exact' -Arrange {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'README.md')
        Write-FixtureFile -RelativePath 'readme.md' -Content "# Wrong case`n"
    }
    Assert-Fails -Name 'nested sixth production script' -Arrange {
        Write-FixtureFile -RelativePath 'scripts/nested/sixth.ps1' -Content "Write-Output 'sixth'`n"
    }
    Assert-Fails -Name 'nested fourth reference file' -Arrange {
        Write-FixtureFile -RelativePath 'references/nested/fourth.md' -Content "# Fourth`n"
    }

    Assert-Fails -Name 'checkpoint missing current_state' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.PSObject.Properties.Remove('current_state')
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint missing emulator model' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.emulator.PSObject.Properties.Remove('model')
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint missing minimum_level' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.fleet.ship_identity_checks[0].expected_skill.PSObject.Properties.Remove('minimum_level')
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint maps is not an array' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.completion.maps = 'not-an-array'
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint schema version two' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.schema_version = 2
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint schema version string' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.schema_version = '1'
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint repair flag must remain false' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.fleet.repair_supply_verified = $true
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint identity flag must be boolean' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.fleet.ship_identity_checks[0].identity_verified = 'false'
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Fails -Name 'checkpoint identity flag must remain false' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value.fleet.ship_identity_checks[0].identity_verified = $true
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }
    Assert-Passes -Name 'checkpoint allows additional fields' -Arrange {
        $value = Read-FixtureJson 'assets/checkpoint-template.json'
        $value | Add-Member -NotePropertyName future_field -NotePropertyValue 'allowed'
        $value.emulator | Add-Member -NotePropertyName future_emulator_field -NotePropertyValue $null
        Write-FixtureJson 'assets/checkpoint-template.json' $value
    }

    Assert-Fails -Name 'eval count three' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals = @($value.evals | Select-Object -First 3)
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval duplicate id' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[3].id = 3
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval id must be JSON integer' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].id = '1'
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval expectations count five' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].expectations = @($value.evals[0].expectations | Select-Object -First 5)
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval empty expectation' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].expectations[2] = ''
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval empty prompt' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].prompt = ''
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval wrong skill name' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.skill_name = 'another-skill'
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval file is missing' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].files = @('missing.txt')
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval file escapes repository' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].files = @('../outside.txt')
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval file entry is empty' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].files = @('')
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval file path casing is exact' -Arrange {
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].files = @('readme.md')
        Write-FixtureJson 'evals/evals.json' $value
    }
    Assert-Fails -Name 'eval file cannot resolve through ignored git metadata' -Arrange {
        Write-FixtureFile -RelativePath '.git/config' -Content "ignored`n"
        $value = Read-FixtureJson 'evals/evals.json'
        $value.evals[0].files = @('.git/config')
        Write-FixtureJson 'evals/evals.json' $value
    }

    $forbiddenExtensions = @(
        '.skill', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.ico', '.svg',
        '.apk', '.aab', '.so', '.unity3d',
        '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.webm', '.wmv', '.flv', '.mpeg', '.mpg',
        '.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.opus', '.wma',
        '.ttf', '.otf', '.woff', '.woff2', '.eot',
        '.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst', '.cab',
        '.exe', '.dll', '.msi', '.jar', '.dex', '.obb',
        '.p12', '.pfx', '.jks', '.keystore'
    )
    foreach ($extension in $forbiddenExtensions) {
        $currentExtension = $extension
        Assert-Fails -Name ("forbidden extension $currentExtension") -Arrange {
            Write-FixtureFile -RelativePath ("blocked$currentExtension") -Content 'blocked'
        }
    }
    Assert-Passes -Name 'PDF and Office files are allowed' -Arrange {
        foreach ($extension in @('.pdf', '.docx', '.xlsx', '.pptx')) {
            Write-FixtureFile -RelativePath ("allowed$extension") -Content 'not a real package'
        }
    }
    Assert-Passes -Name 'git metadata is ignored before all scans' -Arrange {
        Write-FixtureFile -RelativePath '.git/objects/sample.zip' -Content 'ignored archive'
        $ignoredToken = ('gh' + 'p_' + ('G' * 28))
        Write-FixtureFile -RelativePath '.git/objects/credential.txt' -Content $ignoredToken
    }
    Assert-Passes -Name 'unknown binary files are not decoded as text' -Arrange {
        $bytes = [Text.Encoding]::ASCII.GetBytes(('gh' + 'p_' + ('B' * 28)))
        [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'opaque.bin'), $bytes)
    }
    Assert-Fails -Name 'script ASCII is checked from raw bytes' -Arrange {
        $scriptPath = Join-Path $fixtureRoot 'scripts/capture-mumu-state.ps1'
        $bytes = [byte[]](87, 114, 105, 116, 101, 45, 79, 117, 116, 112, 117, 116, 32, 39, 120, 39, 10, 195, 169)
        [IO.File]::WriteAllBytes($scriptPath, $bytes)
    }

    $githubToken = ('gh' + 'p_' + ('A' * 28))
    Assert-Fails -Name 'GitHub credential' -ForbiddenEcho $githubToken -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $githubToken
    }
    $awsKey = ('AK' + 'IA' + ('A' * 16))
    Assert-Fails -Name 'AWS access key' -ForbiddenEcho $awsKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $awsKey
    }
    $awsSessionKey = ('AS' + 'IA' + ('S' * 16))
    Assert-Fails -Name 'AWS session key' -ForbiddenEcho $awsSessionKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $awsSessionKey
    }
    $slackToken = ('xo' + 'xb-' + ('1' * 12) + '-' + ('A' * 24))
    Assert-Fails -Name 'Slack xox credential' -ForbiddenEcho $slackToken -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $slackToken
    }
    $slackAppToken = ('xa' + 'pp-' + ('1-' * 3) + ('A' * 24))
    Assert-Fails -Name 'Slack app credential' -ForbiddenEcho $slackAppToken -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $slackAppToken
    }
    $googleKey = ('AI' + 'za' + ('A' * 35))
    Assert-Fails -Name 'Google API credential' -ForbiddenEcho $googleKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $googleKey
    }
    $stripeKey = ('sk_' + 'live_' + ('A' * 24))
    Assert-Fails -Name 'Stripe live credential' -ForbiddenEcho $stripeKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $stripeKey
    }
    $openAiKey = ('sk-' + ('O' * 30))
    Assert-Fails -Name 'OpenAI credential' -ForbiddenEcho $openAiKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $openAiKey
    }
    $openAiProjectKey = ('sk-' + 'proj-' + ('P' * 30))
    Assert-Fails -Name 'OpenAI project credential' -ForbiddenEcho $openAiProjectKey -Arrange {
        Write-FixtureFile -RelativePath 'credential.txt' -Content $openAiProjectKey
    }
    $pemHeader = ('-----BEGIN ' + 'PRIVATE KEY-----')
    Assert-Fails -Name 'PEM private key header' -ForbiddenEcho $pemHeader -Arrange {
        Write-FixtureFile -RelativePath 'private.pem' -Content $pemHeader
    }
    $encryptedPemHeader = ('-----BEGIN ENCRYPTED ' + 'PRIVATE KEY-----')
    Assert-Fails -Name 'encrypted PEM private key header' -ForbiddenEcho $encryptedPemHeader -Arrange {
        Write-FixtureFile -RelativePath 'private.pem' -Content $encryptedPemHeader
    }
    $rsaPemHeader = ('-----BEGIN RSA ' + 'PRIVATE KEY-----')
    Assert-Fails -Name 'PEM private key in key file' -ForbiddenEcho $rsaPemHeader -Arrange {
        Write-FixtureFile -RelativePath 'private.key' -Content $rsaPemHeader
    }
    $pgpHeader = ('-----BEGIN PGP ' + 'PRIVATE KEY BLOCK-----')
    Assert-Fails -Name 'PGP private key header' -ForbiddenEcho $pgpHeader -Arrange {
        Write-FixtureFile -RelativePath 'private.asc' -Content $pgpHeader
    }
    $genericSecretValue = ('S' * 24)
    $genericSecret = ('api_' + 'secret = ' + $genericSecretValue)
    Assert-Fails -Name 'generic secret assignment' -ForbiddenEcho $genericSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $genericSecret
    }
    $exactGenericSecretValue = ('X' * 24)
    $exactGenericSecret = ('SEC' + 'RET = ' + $exactGenericSecretValue)
    Assert-Fails -Name 'exact generic secret key assignment' -ForbiddenEcho $exactGenericSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $exactGenericSecret
    }
    $prefixedCompoundSecretValue = ('Q' * 24)
    $prefixedCompoundSecret = ('MY_' + 'API_KEY = ' + $prefixedCompoundSecretValue)
    Assert-Fails -Name 'prefixed compound secret key assignment' -ForbiddenEcho $prefixedCompoundSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $prefixedCompoundSecret
    }
    $authSecretValue = ('Y' * 24)
    $authSecret = ('AU' + 'TH = ' + $authSecretValue)
    Assert-Fails -Name 'exact auth key assignment' -ForbiddenEcho $authSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $authSecret
    }
    $commentedSecretValue = ('C' * 24)
    $commentedSecret = ('TO' + 'KEN = ' + $commentedSecretValue + ' # rotate soon')
    Assert-Fails -Name 'generic secret assignment with comment' -ForbiddenEcho $commentedSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $commentedSecret
    }
    $hashSecretValue = ('abc#' + ('D' * 24))
    $hashSecret = ('PASS' + 'WORD = ' + $hashSecretValue)
    Assert-Fails -Name 'generic secret assignment containing hash' -ForbiddenEcho $hashSecretValue -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $hashSecret
    }
    Assert-Passes -Name 'generic non-secret policy settings are allowed' -Arrange {
        $settings = "token_expiry_days=30`npassword_policy=strict`nsecret_rotation_enabled=true`n"
        Write-FixtureFile -RelativePath 'settings.txt' -Content $settings
    }
    $hiddenSecret = ('sk-' + ('H' * 30))
    Assert-Fails -Name 'hidden env credential' -ForbiddenEcho $hiddenSecret -Arrange {
        Write-FixtureFile -RelativePath '.env.local' -Content (('OPENAI_' + 'KEY=') + $hiddenSecret)
    }
    $npmSecret = ('opaque-' + ('N' * 28))
    Assert-Fails -Name 'npmrc credential' -ForbiddenEcho $npmSecret -Arrange {
        Write-FixtureFile -RelativePath '.npmrc' -Content (('//registry.example/:_authToken=') + $npmSecret)
    }
    $logAwsKey = ('AK' + 'IA' + ('L' * 16))
    Assert-Fails -Name 'credential in log text' -ForbiddenEcho $logAwsKey -Arrange {
        Write-FixtureFile -RelativePath 'debug.log' -Content $logAwsKey
    }
    $backslashUserPath = ('C:' + [char]92 + 'Users' + [char]92 + 'Example' + [char]92 + 'repo')
    Assert-Fails -Name 'Windows user-specific backslash path' -ForbiddenEcho $backslashUserPath -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $backslashUserPath
    }
    $forwardSlashUserPath = ('C:' + '/' + 'Users' + '/' + 'Example' + '/' + 'repo')
    Assert-Fails -Name 'Windows user-specific forward slash path' -ForbiddenEcho $forwardSlashUserPath -Arrange {
        Write-FixtureFile -RelativePath 'settings.txt' -Content $forwardSlashUserPath
    }
    $pathSlash = [string][char]92
    $escapedUserPath = ('C:' + $pathSlash + $pathSlash + 'Users' + $pathSlash + $pathSlash + 'Example' + $pathSlash + $pathSlash + 'repo')
    Assert-Fails -Name 'JSON-escaped Windows user-specific path' -ForbiddenEcho $escapedUserPath -Arrange {
        Write-FixtureFile -RelativePath 'settings.json' -Content ('{"path":"' + $escapedUserPath + '"}')
    }
    Assert-Passes -Name 'explicit credential placeholders are allowed' -Arrange {
        $placeholderText = @'
API_SECRET=placeholder
SECRET=placeholder
TOKEN=example # documented placeholder
AUTH=redacted
ACCESS_TOKEN=example
PASSWORD=redacted
CLIENT_SECRET=dummy
PRIVATE_KEY=changeme
OPENAI_KEY=${OPENAI_KEY}
AUTH_TOKEN=<AUTH_TOKEN>
'@
        Write-FixtureFile -RelativePath '.env.example' -Content $placeholderText
        Write-FixtureFile -RelativePath '.npmrc' -Content '//registry.example/:_authToken=${NPM_TOKEN}'
    }

    Assert-Fails -Name 'undefined ordinary reference' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[missing][undefined]`n"
    }
    Assert-Fails -Name 'undefined image reference' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "![missing][undefined]`n"
    }
    Assert-Fails -Name 'defined reference target missing' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[missing][doc]`n`n[doc]: missing.md`n"
    }
    Assert-Fails -Name 'defined reference escapes repository' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[outside][doc]`n`n[doc]: ../outside.md`n"
    }
    Assert-Fails -Name 'first duplicate reference definition controls target' -Arrange {
        $markdown = "[document][duplicate]`n`n[duplicate]: missing.md`n[  DUPLICATE  ]: docs/evaluation.md`n"
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Fails -Name 'Markdown target casing is exact' -Arrange {
        Write-FixtureFile -RelativePath 'docs/CaseTarget.md' -Content "# Case target`n"
        Write-FixtureFile -RelativePath 'README.md' -Content "[case](docs/casetarget.md)`n"
    }
    Assert-Fails -Name 'Markdown target cannot resolve through ignored git metadata' -Arrange {
        Write-FixtureFile -RelativePath '.git/config' -Content "ignored`n"
        Write-FixtureFile -RelativePath 'README.md' -Content "[git](.git/config)`n"
    }
    Assert-Fails -Name 'inline link escapes repository' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[outside](../outside.md)`n"
    }
    Assert-Fails -Name 'inline Windows drive path is not treated as a URI scheme' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[outside](C:\outside.md)`n"
    }
    Assert-Fails -Name 'inline rooted backslash path stays rooted' -Arrange {
        Write-FixtureFile -RelativePath 'README.md' -Content "[outside](\README.md)`n"
    }
    Assert-Fails -Name 'unequal inline code delimiters do not mask links' -Arrange {
        $markdown = @'
`[outside](missing-inline.md)``
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Fails -Name 'escaped opening backtick does not mask active link' -Arrange {
        $markdown = @'
\`[outside](missing-inline.md)\`
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Fails -Name 'even backslashes leave Markdown link active' -Arrange {
        $markdown = @'
\\[outside](missing-inline.md)
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Passes -Name 'escaped Markdown brackets stay literal' -Arrange {
        $markdown = @'
\[literal](missing-inline.md)
!\[literal image](missing-image.png)
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Passes -Name 'inline code and fences mask pseudo links' -Arrange {
        $markdown = @'
# Masked links

`[inline](missing-inline.md)` and ``![image](missing-image.png)``.

```text
[fenced](missing-fenced.md)
![fenced-image](missing-fenced.png)
```
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }
    Assert-Passes -Name 'legal Markdown destinations and references' -Arrange {
        Write-FixtureFile -RelativePath 'docs/(guide).md' -Content "# Guide`n"
        Write-FixtureFile -RelativePath 'docs/space file.md' -Content "# Space`n"
        $markdown = @'
# Links

[double](docs/evaluation.md "double title")
[single](docs/evaluation.md 'single title')
[parenthesized-title](docs/evaluation.md (parenthesized title))
[parenthesized-path](docs/(guide).md)
[angle-space](<docs/space file.md> "space title")
[escaped-space](docs/space\ file.md)
[directory](docs/)
[query](docs/evaluation.md?mode=test#section)
[remote](https://example.invalid/missing)
[network](//example.invalid/missing)
[anchor](#missing-anchor)

[Full ordinary][  Guide   Label ]
![Full image][guide label]
[Collapsed ordinary][]
![Collapsed image][]

[guide label]: <docs/evaluation.md> (reference title)
[collapsed ordinary]: docs/(guide).md
[collapsed image]: <docs/space file.md> 'image title'
'@
        Write-FixtureFile -RelativePath 'README.md' -Content $markdown
    }

    Assert-Fails -Name 'frontmatter compatibility missing' -Arrange {
        $value = @'
---
name: warship-girls-r-event-runner
description: Runs an event safely.
---
'@
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    foreach ($emptyCompatibility in @('', '""', "''", '~', 'null')) {
        $currentCompatibility = $emptyCompatibility
        Assert-Fails -Name ("frontmatter compatibility invalid value '$currentCompatibility'") -Arrange {
            $value = "---`nname: warship-girls-r-event-runner`ndescription: Runs an event safely.`ncompatibility: $currentCompatibility`n---`n"
            Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
        }
    }
    Assert-Fails -Name 'frontmatter compatibility must be single line' -Arrange {
        $value = "---`nname: warship-girls-r-event-runner`ndescription: Runs an event safely.`ncompatibility: |`n  Windows PowerShell 5.1`n---`n"
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    Assert-Fails -Name 'frontmatter compatibility must be a string scalar' -Arrange {
        $value = "---`nname: warship-girls-r-event-runner`ndescription: Runs an event safely.`ncompatibility: []`n---`n"
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    Assert-Fails -Name 'frontmatter compatibility rejects unterminated quote' -Arrange {
        $value = "---`nname: warship-girls-r-event-runner`ndescription: Runs an event safely.`ncompatibility: `"Windows PowerShell 5.1`n---`n"
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    Assert-Fails -Name 'frontmatter compatibility rejects lone quote' -Arrange {
        $value = @'
---
name: warship-girls-r-event-runner
description: Runs an event safely.
compatibility: "
---
'@
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    Assert-Fails -Name 'frontmatter description must be a string scalar' -Arrange {
        $value = "---`nname: warship-girls-r-event-runner`ndescription: {}`ncompatibility: Windows PowerShell 5.1`n---`n"
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
    Assert-Fails -Name 'frontmatter closing marker must stand alone' -Arrange {
        $value = "---`nname: warship-girls-r-event-runner`ndescription: Runs an event safely.`ncompatibility: Windows PowerShell 5.1`n--- trailing`n"
        Write-FixtureFile -RelativePath 'SKILL.md' -Content $value
    }
}
finally {
    Assert-TemporaryFixturePath -Path $fixtureRoot
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Output "FAIL: $failure"
    }
    throw "Validator regression suite failed: $($failures.Count) of $assertionCount assertions failed."
}

Write-Output "Validator regression suite passed: $assertionCount assertions."
