[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)

function Get-RepositoryRelativePath {
    param([Parameter(Mandatory = $true)][string]$FullName)

    if (-not $FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A repository file resolved outside the repository root.'
    }
    return $FullName.Substring($rootPrefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Read-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    try {
        return [IO.File]::ReadAllText($Path, $utf8Strict)
    }
    catch {
        throw "Text file is not valid UTF-8: $DisplayPath"
    }
}

function Read-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    $text = Read-Utf8Text -Path $File.FullName -DisplayPath $DisplayPath
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON: $DisplayPath"
    }
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "$Context is missing required property '$Name'."
    }
    return ,$Object.PSObject.Properties[$Name].Value
}

function Test-IsJsonObject {
    param($Value)

    return $null -ne $Value -and $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
}

function Get-RequiredObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = Get-RequiredPropertyValue -Object $Object -Name $Name -Context $Context
    if (-not (Test-IsJsonObject $value)) {
        throw "$Context.$Name must be an object."
    }
    return $value
}

function Get-RequiredArrayProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = Get-RequiredPropertyValue -Object $Object -Name $Name -Context $Context
    if (-not ($value -is [Array])) {
        throw "$Context.$Name must be an array."
    }
    return ,$value
}

function Assert-RequiredProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($name in $Names) {
        [void](Get-RequiredPropertyValue -Object $Object -Name $name -Context $Context)
    }
}

function Test-IsJsonInteger {
    param($Value)

    return (
        $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    )
}

function Resolve-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Context
    )

    try {
        $candidate = [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Target)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    catch {
        throw "$Context contains an invalid repository path."
    }
    if ($candidate -ne $root -and -not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context leaves the repository."
    }
    return $candidate
}

$allFiles = @(
    Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch '(?i)(^|[\\/])\.git([\\/]|$)' }
)

$fileByRelativePath = [Collections.Generic.Dictionary[string,IO.FileInfo]]::new([StringComparer]::Ordinal)
$directoryByRelativePath = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void]$directoryByRelativePath.Add('')
foreach ($file in $allFiles) {
    $relativePath = Get-RepositoryRelativePath -FullName $file.FullName
    $fileByRelativePath[$relativePath] = $file
    $segments = $relativePath -split '/'
    for ($segmentCount = 1; $segmentCount -lt $segments.Count; $segmentCount++) {
        [void]$directoryByRelativePath.Add(($segments[0..($segmentCount - 1)] -join '/'))
    }
}

function Require-File {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    if (-not $fileByRelativePath.ContainsKey($normalized)) {
        throw "Required file is missing: $normalized"
    }
    return $fileByRelativePath[$normalized]
}

$required = @(
    'README.md',
    'WORKFLOW.md',
    'SKILL.md',
    'LICENSE',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'assets/checkpoint-template.json',
    'evals/evals.json',
    'scripts/capture-mumu-state.ps1',
    'scripts/compare-mumu-visual-state.ps1',
    'scripts/invoke-bounded-process.ps1',
    'scripts/resolve-mumu-target.ps1',
    'scripts/send-mumu-input.ps1',
    'references/research-safety.md',
    'references/adb-recovery.md',
    'references/activity-operations.md',
    'docs/evaluation.md',
    '.github/workflows/validate.yml',
    'tests/validate-repository.ps1',
    'tests/test-validate-repository.ps1',
    'tests/test-mumu-safety.ps1',
    'tests/test-send-mumu-input.ps1'
)
foreach ($relativePath in $required) {
    [void](Require-File -RelativePath $relativePath)
}

$productionScripts = @(
    $allFiles | Where-Object {
        (Get-RepositoryRelativePath -FullName $_.FullName) -match '^scripts/.+\.ps1$'
    }
)
if ($productionScripts.Count -ne 5) {
    throw "Expected exactly five scripts/*.ps1 files; found $($productionScripts.Count)."
}

$referenceFiles = @(
    $allFiles | Where-Object {
        (Get-RepositoryRelativePath -FullName $_.FullName) -match '^references/.+$'
    }
)
if ($referenceFiles.Count -ne 3) {
    throw "Expected exactly three references; found $($referenceFiles.Count)."
}

$powerShellFiles = @($allFiles | Where-Object { $_.Extension -ieq '.ps1' })
foreach ($scriptFile in $powerShellFiles) {
    $relativePath = Get-RepositoryRelativePath -FullName $scriptFile.FullName
    $bytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
    foreach ($value in $bytes) {
        if ($value -gt 127) {
            throw "PowerShell script is not ASCII: $relativePath"
        }
    }
    $source = Read-Utf8Text -Path $scriptFile.FullName -DisplayPath $relativePath
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($source, $scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell syntax error: $relativePath"
    }
}

$checkpointFile = Require-File -RelativePath 'assets/checkpoint-template.json'
$checkpoint = Read-Utf8Json -File $checkpointFile -DisplayPath 'assets/checkpoint-template.json'
if (-not (Test-IsJsonObject $checkpoint)) {
    throw 'assets/checkpoint-template.json must contain an object.'
}

$schemaVersion = Get-RequiredPropertyValue -Object $checkpoint -Name 'schema_version' -Context 'checkpoint'
if (-not (Test-IsJsonInteger $schemaVersion) -or $schemaVersion -ne 1) {
    throw 'checkpoint.schema_version must be the integer 1.'
}
[void](Get-RequiredPropertyValue -Object $checkpoint -Name 'updated_at' -Context 'checkpoint')
$activity = Get-RequiredObjectProperty -Object $checkpoint -Name 'activity' -Context 'checkpoint'
$emulator = Get-RequiredObjectProperty -Object $checkpoint -Name 'emulator' -Context 'checkpoint'
$currentState = Get-RequiredObjectProperty -Object $checkpoint -Name 'current_state' -Context 'checkpoint'
$fleet = Get-RequiredObjectProperty -Object $checkpoint -Name 'fleet' -Context 'checkpoint'
$battleCenter = Get-RequiredObjectProperty -Object $checkpoint -Name 'battle_center' -Context 'checkpoint'
$completion = Get-RequiredObjectProperty -Object $checkpoint -Name 'completion' -Context 'checkpoint'
[void](Get-RequiredArrayProperty -Object $checkpoint -Name 'sources' -Context 'checkpoint')

Assert-RequiredProperties -Object $activity -Context 'checkpoint.activity' -Names @('name', 'start_date', 'end_date')
[void](Get-RequiredArrayProperty -Object $activity -Name 'requested_scope' -Context 'checkpoint.activity')
[void](Get-RequiredArrayProperty -Object $activity -Name 'definition_of_done' -Context 'checkpoint.activity')

Assert-RequiredProperties -Object $emulator -Context 'checkpoint.emulator' -Names @(
    'vm_index',
    'serial',
    'source',
    'boot_id',
    'android_id',
    'model',
    'game_package',
    'game_pid',
    'foreground_package',
    'foreground_activity',
    'physical_size',
    'override_size',
    'rotation',
    'screenshot_path',
    'screenshot_sidecar'
)

Assert-RequiredProperties -Object $currentState -Context 'checkpoint.current_state' -Names @(
    'page', 'chapter', 'map', 'entrance', 'progress', 'blocker', 'next_safe_action'
)

[void](Get-RequiredArrayProperty -Object $fleet -Name 'slots' -Context 'checkpoint.fleet')
$identityChecks = Get-RequiredArrayProperty -Object $fleet -Name 'ship_identity_checks' -Context 'checkpoint.fleet'
if ($identityChecks.Count -lt 1 -or -not (Test-IsJsonObject $identityChecks[0])) {
    throw 'checkpoint.fleet.ship_identity_checks[0] must be an object.'
}
$identityCheck = $identityChecks[0]
Assert-RequiredProperties -Object $identityCheck -Context 'checkpoint.fleet.ship_identity_checks[0]' -Names @(
    'slot', 'name', 'form', 'class', 'level', 'favorite', 'candidate_count', 'evidence_sidecar'
)
$expectedSkill = Get-RequiredObjectProperty -Object $identityCheck -Name 'expected_skill' -Context 'checkpoint.fleet.ship_identity_checks[0]'
$observedSkill = Get-RequiredObjectProperty -Object $identityCheck -Name 'observed_active_skill' -Context 'checkpoint.fleet.ship_identity_checks[0]'
Assert-RequiredProperties -Object $expectedSkill -Context 'checkpoint.fleet.ship_identity_checks[0].expected_skill' -Names @('name_or_branch', 'minimum_level')
Assert-RequiredProperties -Object $observedSkill -Context 'checkpoint.fleet.ship_identity_checks[0].observed_active_skill' -Names @('name_or_branch', 'level')
$identityVerified = Get-RequiredPropertyValue -Object $identityCheck -Name 'identity_verified' -Context 'checkpoint.fleet.ship_identity_checks[0]'
if (-not ($identityVerified -is [bool]) -or $identityVerified) {
    throw 'checkpoint.fleet.ship_identity_checks[0].identity_verified must be false.'
}
[void](Get-RequiredArrayProperty -Object $fleet -Name 'route_constraints' -Context 'checkpoint.fleet')
[void](Get-RequiredArrayProperty -Object $fleet -Name 'equipment_notes' -Context 'checkpoint.fleet')
$repairSupplyVerified = Get-RequiredPropertyValue -Object $fleet -Name 'repair_supply_verified' -Context 'checkpoint.fleet'
if (-not ($repairSupplyVerified -is [bool]) -or $repairSupplyVerified) {
    throw 'checkpoint.fleet.repair_supply_verified must be false.'
}

[void](Get-RequiredPropertyValue -Object $battleCenter -Name 'points_remaining' -Context 'checkpoint.battle_center')
[void](Get-RequiredArrayProperty -Object $battleCenter -Name 'active_buffs' -Context 'checkpoint.battle_center')
foreach ($arrayName in @('maps', 'questions', 'rewards', 'boxes', 'achievements')) {
    [void](Get-RequiredArrayProperty -Object $completion -Name $arrayName -Context 'checkpoint.completion')
}

$evalFile = Require-File -RelativePath 'evals/evals.json'
$evalDocument = Read-Utf8Json -File $evalFile -DisplayPath 'evals/evals.json'
if (-not (Test-IsJsonObject $evalDocument)) {
    throw 'evals/evals.json must contain an object.'
}
$skillName = Get-RequiredPropertyValue -Object $evalDocument -Name 'skill_name' -Context 'eval document'
if (-not ($skillName -is [string]) -or $skillName -cne 'warship-girls-r-event-runner') {
    throw 'eval document skill_name is invalid.'
}
$evals = Get-RequiredArrayProperty -Object $evalDocument -Name 'evals' -Context 'eval document'
if ($evals.Count -ne 4) {
    throw "eval document must contain exactly four evals; found $($evals.Count)."
}
$evalIds = @()
for ($evalIndex = 0; $evalIndex -lt $evals.Count; $evalIndex++) {
    $eval = $evals[$evalIndex]
    $context = "evals[$evalIndex]"
    if (-not (Test-IsJsonObject $eval)) {
        throw "$context must be an object."
    }
    $id = Get-RequiredPropertyValue -Object $eval -Name 'id' -Context $context
    if (-not (Test-IsJsonInteger $id)) {
        throw "$context.id must be a JSON integer."
    }
    $evalIds += [int]$id
    foreach ($stringProperty in @('prompt', 'expected_output')) {
        $value = Get-RequiredPropertyValue -Object $eval -Name $stringProperty -Context $context
        if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
            throw "$context.$stringProperty must be a non-empty string."
        }
    }
    $files = Get-RequiredArrayProperty -Object $eval -Name 'files' -Context $context
    for ($fileIndex = 0; $fileIndex -lt $files.Count; $fileIndex++) {
        $fileReference = $files[$fileIndex]
        if (-not ($fileReference -is [string]) -or [string]::IsNullOrWhiteSpace($fileReference)) {
            throw "$context.files[$fileIndex] must be a non-empty string."
        }
        if ([IO.Path]::IsPathRooted($fileReference) -or $fileReference -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $fileReference -match '^//') {
            throw "$context.files[$fileIndex] must be a relative repository path."
        }
        $candidate = Resolve-RepositoryPath -BaseDirectory $root -Target $fileReference -Context "$context.files[$fileIndex]"
        if ($candidate -eq $root) {
            throw "$context.files[$fileIndex] does not identify a file."
        }
        $candidateRelativePath = Get-RepositoryRelativePath -FullName $candidate
        if (-not $fileByRelativePath.ContainsKey($candidateRelativePath)) {
            throw "$context.files[$fileIndex] does not exist."
        }
    }
    $expectations = Get-RequiredArrayProperty -Object $eval -Name 'expectations' -Context $context
    if ($expectations.Count -ne 6) {
        throw "$context.expectations must contain exactly six strings."
    }
    for ($expectationIndex = 0; $expectationIndex -lt $expectations.Count; $expectationIndex++) {
        $expectation = $expectations[$expectationIndex]
        if (-not ($expectation -is [string]) -or [string]::IsNullOrWhiteSpace($expectation)) {
            throw "$context.expectations[$expectationIndex] must be a non-empty string."
        }
    }
}
$sortedEvalIds = @($evalIds | Sort-Object -Unique)
if ($sortedEvalIds.Count -ne 4 -or (($sortedEvalIds -join ',') -ne '1,2,3,4')) {
    throw 'eval IDs must be the unique set 1,2,3,4.'
}

$forbiddenExtensions = @(
    '.skill',
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.ico', '.svg',
    '.apk', '.aab', '.so', '.unity3d',
    '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.webm', '.wmv', '.flv', '.mpeg', '.mpg',
    '.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.opus', '.wma',
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    '.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst', '.cab',
    '.exe', '.dll', '.msi', '.jar', '.dex', '.obb',
    '.p12', '.pfx', '.jks', '.keystore'
)
foreach ($file in $allFiles) {
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) {
        $relativePath = Get-RepositoryRelativePath -FullName $file.FullName
        throw "Forbidden file type present: $relativePath"
    }
}

function Test-IsReasonableTextFile {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$File)

    $extension = $File.Extension.ToLowerInvariant()
    if ($extension -in @(
        '.md', '.rst', '.adoc', '.txt', '.log',
        '.json', '.yml', '.yaml', '.toml', '.xml', '.csv', '.tsv', '.ini', '.cfg', '.conf', '.config', '.properties', '.lock',
        '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.fish', '.cmd', '.bat',
        '.py', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.html', '.htm', '.css', '.scss', '.sql', '.graphql', '.gql',
        '.java', '.kt', '.kts', '.gradle', '.cs', '.c', '.h', '.cpp', '.hpp',
        '.pem', '.key', '.asc'
    )) {
        return $true
    }
    if ($File.Name -in @('LICENSE', 'CHANGELOG', 'NOTICE', 'Dockerfile', 'Makefile', '.gitignore', '.gitattributes', '.editorconfig', '.npmrc')) {
        return $true
    }
    if ($File.Name.StartsWith('.env', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Test-IsExplicitPlaceholder {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $candidate = $Value.Trim()
    if ($candidate.Length -ge 2) {
        $first = $candidate.Substring(0, 1)
        $last = $candidate.Substring($candidate.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
        }
    }
    if ($candidate -match '^(?i:placeholder|example|redacted|dummy|changeme)$') {
        return $true
    }
    if ($candidate -match '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$' -or $candidate -match '^<[A-Za-z_][A-Za-z0-9_]*>$') {
        return $true
    }
    return $false
}

$credentialPatterns = @(
    '(?i)(?:gh[pousr]_[A-Za-z0-9_-]{20,}|github_pat_[A-Za-z0-9_-]{20,})',
    '(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])',
    '(?i)(?:xox[baprs]-[A-Za-z0-9-]{20,}|xapp-[A-Za-z0-9-]{20,})',
    'AIza[0-9A-Za-z_-]{35}',
    'sk_live_[0-9A-Za-z]{16,}',
    'sk-(?:proj-)?[A-Za-z0-9_-]{20,}',
    '-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
    ('-----BEGIN PGP ' + 'PRIVATE KEY BLOCK-----')
)
$genericAssignmentPattern = '(?im)^[ \t]*(?:export[ \t]+)?(?<key>[A-Za-z_][A-Za-z0-9_.-]*)[ \t]*[:=][ \t]*(?<value>[^\r\n]*?)[ \t]*$'
$genericSensitiveKeyPattern = '(?i)^(?:password|passwd|pwd|secret|token|auth|authorization|(?:.+[_.-])(?:password|passwd|pwd|secret|token)|(?:.+[_.-])?(?:api|access|private|client|auth|openai|google|aws|stripe|github|slack)[_.-]?(?:key|secret|token))$'
$npmrcAuthPattern = '(?im)^[ \t]*//[^ \t\r\n]+/:_authToken[ \t]*=[ \t]*(?<value>[^\r\n]*?)[ \t]*$'

foreach ($file in $allFiles) {
    if (-not (Test-IsReasonableTextFile -File $file)) {
        continue
    }
    $relativePath = Get-RepositoryRelativePath -FullName $file.FullName
    $text = Read-Utf8Text -Path $file.FullName -DisplayPath $relativePath
    foreach ($pattern in $credentialPatterns) {
        if ($text -match $pattern) {
            throw "Potential credential found in $relativePath."
        }
    }
    foreach ($match in [regex]::Matches($text, $genericAssignmentPattern)) {
        if ($match.Groups['key'].Value -notmatch $genericSensitiveKeyPattern) {
            continue
        }
        $assignedValue = $match.Groups['value'].Value -replace '[ \t]+#.*$', ''
        if (-not (Test-IsExplicitPlaceholder -Value $assignedValue)) {
            throw "Potential credential assignment found in $relativePath."
        }
    }
    if ($file.Name -ieq '.npmrc') {
        foreach ($match in [regex]::Matches($text, $npmrcAuthPattern)) {
            $assignedValue = $match.Groups['value'].Value -replace '[ \t]+#.*$', ''
            if (-not (Test-IsExplicitPlaceholder -Value $assignedValue)) {
                throw "Potential npm credential assignment found in $relativePath."
            }
        }
    }
    if ($text -match '(?i)\b[A-Z]:[\\/]+Users[\\/]+[^\\/\s`"'']+') {
        throw "User-specific absolute path found in $relativePath."
    }
}

function Remove-MarkdownFences {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $outsideFence = [Text.StringBuilder]::new()
    $fenceCharacter = $null
    $fenceLength = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $opening = [regex]::Match($line, '^[ ]{0,3}(?<mark>`{3,}|~{3,})')
        if ($null -eq $fenceCharacter -and $opening.Success) {
            $fenceCharacter = $opening.Groups['mark'].Value.Substring(0, 1)
            $fenceLength = $opening.Groups['mark'].Value.Length
            continue
        }
        if ($null -ne $fenceCharacter) {
            $closing = [regex]::Match($line, '^[ ]{0,3}(?<mark>`{3,}|~{3,})[ \t]*$')
            if (
                $closing.Success -and
                $closing.Groups['mark'].Value.Substring(0, 1) -eq $fenceCharacter -and
                $closing.Groups['mark'].Value.Length -ge $fenceLength
            ) {
                $fenceCharacter = $null
                $fenceLength = 0
            }
            continue
        }
        [void]$outsideFence.AppendLine($line)
    }
    return $outsideFence.ToString()
}

function Test-IsMarkdownCharacterEscaped {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $backslashCount = 0
    $scanIndex = $Index - 1
    while ($scanIndex -ge 0 -and $Text[$scanIndex] -eq '\') {
        $backslashCount++
        $scanIndex--
    }
    return ($backslashCount % 2) -eq 1
}

function Remove-MarkdownInlineCode {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $masked = $Text.ToCharArray()
    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -ne '`') {
            $index++
            continue
        }

        $openingStart = $index
        while ($index -lt $Text.Length -and $Text[$index] -eq '`') {
            $index++
        }
        if (Test-IsMarkdownCharacterEscaped -Text $Text -Index $openingStart) {
            continue
        }
        $delimiterLength = $index - $openingStart
        $searchIndex = $index
        $closingStart = -1

        while ($searchIndex -lt $Text.Length) {
            if ($Text[$searchIndex] -ne '`') {
                $searchIndex++
                continue
            }
            $runStart = $searchIndex
            while ($searchIndex -lt $Text.Length -and $Text[$searchIndex] -eq '`') {
                $searchIndex++
            }
            if (($searchIndex - $runStart) -eq $delimiterLength) {
                $closingStart = $runStart
                break
            }
        }

        if ($closingStart -lt 0) {
            continue
        }
        $closingEnd = $closingStart + $delimiterLength
        for ($maskIndex = $openingStart; $maskIndex -lt $closingEnd; $maskIndex++) {
            if ($masked[$maskIndex] -ne "`r" -and $masked[$maskIndex] -ne "`n") {
                $masked[$maskIndex] = ' '
            }
        }
        $index = $closingEnd
    }
    return -join $masked
}

function Test-IsMarkdownEscapableCharacter {
    param([Parameter(Mandatory = $true)][char]$Character)

    $codePoint = [int]$Character
    return (
        [char]::IsWhiteSpace($Character) -or
        ($codePoint -ge 33 -and $codePoint -le 47) -or
        ($codePoint -ge 58 -and $codePoint -le 64) -or
        ($codePoint -ge 91 -and $codePoint -le 96) -or
        ($codePoint -ge 123 -and $codePoint -le 126)
    )
}

function ConvertFrom-MarkdownEscapes {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $unescaped = [Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Value.Length) {
        if (
            $Value[$index] -eq '\' -and
            $index + 1 -lt $Value.Length -and
            (Test-IsMarkdownEscapableCharacter -Character $Value[$index + 1])
        ) {
            [void]$unescaped.Append($Value[$index + 1])
            $index += 2
            continue
        }
        [void]$unescaped.Append($Value[$index])
        $index++
    }
    return $unescaped.ToString()
}

function Normalize-MarkdownReferenceLabel {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label)

    $unescaped = ConvertFrom-MarkdownEscapes -Value $Label
    return ([regex]::Replace($unescaped.Trim(), '\s+', ' ')).ToLowerInvariant()
}

function Get-MarkdownTitleEnd {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    if ($StartIndex -ge $Text.Length) {
        return $null
    }
    $delimiter = $Text[$StartIndex]
    if ($delimiter -eq '"' -or $delimiter -eq "'") {
        $index = $StartIndex + 1
        while ($index -lt $Text.Length) {
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            if ($Text[$index] -eq $delimiter) {
                return $index + 1
            }
            $index++
        }
        return $null
    }
    if ($delimiter -eq '(') {
        $depth = 1
        $index = $StartIndex + 1
        while ($index -lt $Text.Length) {
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            if ($Text[$index] -eq '(') {
                $depth++
            }
            elseif ($Text[$index] -eq ')') {
                $depth--
                if ($depth -eq 0) {
                    return $index + 1
                }
            }
            $index++
        }
    }
    return $null
}

function Read-MarkdownDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$StartIndex,
        [Parameter(Mandatory = $true)][bool]$Inline
    )

    $index = $StartIndex
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $index++
    }
    if ($index -ge $Text.Length) {
        return $null
    }

    $rawTarget = $null
    if ($Text[$index] -eq '<') {
        $targetStart = ++$index
        $closed = $false
        while ($index -lt $Text.Length) {
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            if ($Text[$index] -eq '>') {
                $rawTarget = $Text.Substring($targetStart, $index - $targetStart)
                $index++
                $closed = $true
                break
            }
            if ($Text[$index] -eq "`r" -or $Text[$index] -eq "`n") {
                return $null
            }
            $index++
        }
        if (-not $closed) {
            return $null
        }
    }
    else {
        $targetStart = $index
        $parenthesisDepth = 0
        while ($index -lt $Text.Length) {
            $character = $Text[$index]
            if ($character -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            if ([char]::IsWhiteSpace($character) -and $parenthesisDepth -eq 0) {
                break
            }
            if ($character -eq '(') {
                $parenthesisDepth++
                $index++
                continue
            }
            if ($character -eq ')') {
                if ($parenthesisDepth -gt 0) {
                    $parenthesisDepth--
                    $index++
                    continue
                }
                if ($Inline) {
                    break
                }
            }
            if ($character -eq "`r" -or $character -eq "`n") {
                break
            }
            $index++
        }
        if ($parenthesisDepth -ne 0 -or $index -eq $targetStart) {
            return $null
        }
        $rawTarget = $Text.Substring($targetStart, $index - $targetStart)
    }

    $hadWhitespace = $false
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $hadWhitespace = $true
        $index++
    }

    if ($Inline) {
        if ($index -lt $Text.Length -and $Text[$index] -eq ')') {
            return [pscustomobject]@{ Target = $rawTarget; EndIndex = $index + 1 }
        }
        if (-not $hadWhitespace) {
            return $null
        }
        $titleEnd = Get-MarkdownTitleEnd -Text $Text -StartIndex $index
        if ($null -eq $titleEnd) {
            return $null
        }
        $index = $titleEnd
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
        }
        if ($index -ge $Text.Length -or $Text[$index] -ne ')') {
            return $null
        }
        return [pscustomobject]@{ Target = $rawTarget; EndIndex = $index + 1 }
    }

    if ($index -ge $Text.Length) {
        return [pscustomobject]@{ Target = $rawTarget; EndIndex = $index }
    }
    if (-not $hadWhitespace) {
        return $null
    }
    $titleEnd = Get-MarkdownTitleEnd -Text $Text -StartIndex $index
    if ($null -eq $titleEnd) {
        return $null
    }
    $index = $titleEnd
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $index++
    }
    if ($index -ne $Text.Length) {
        return $null
    }
    return [pscustomobject]@{ Target = $rawTarget; EndIndex = $index }
}

function Remove-MarkdownQueryAndFragment {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target)

    $index = 0
    while ($index -lt $Target.Length) {
        if ($Target[$index] -eq '\' -and $index + 1 -lt $Target.Length) {
            $index += 2
            continue
        }
        if ($Target[$index] -eq '?' -or $Target[$index] -eq '#') {
            return $Target.Substring(0, $index)
        }
        $index++
    }
    return $Target
}

function Assert-MarkdownTarget {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawTarget,
        [Parameter(Mandatory = $true)][IO.FileInfo]$MarkdownFile
    )

    $withoutSuffix = Remove-MarkdownQueryAndFragment -Target $RawTarget
    $target = (ConvertFrom-MarkdownEscapes -Value $withoutSuffix).Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        return
    }
    if ($target -match '^#' -or $target -match '^//') {
        return
    }
    if ([IO.Path]::IsPathRooted($target)) {
        throw "Markdown link leaves repository: $(Get-RepositoryRelativePath -FullName $MarkdownFile.FullName)"
    }
    if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
        return
    }

    $displayPath = Get-RepositoryRelativePath -FullName $MarkdownFile.FullName
    $candidate = Resolve-RepositoryPath -BaseDirectory $MarkdownFile.DirectoryName -Target $target -Context "Markdown link in $displayPath"
    $candidateRelativePath = if ($candidate -eq $root) { '' } else { Get-RepositoryRelativePath -FullName $candidate }
    if (-not $fileByRelativePath.ContainsKey($candidateRelativePath) -and -not $directoryByRelativePath.Contains($candidateRelativePath)) {
        throw "Markdown link target is missing in $displayPath."
    }
}

$markdownFiles = @($allFiles | Where-Object { $_.Extension -ieq '.md' })
foreach ($markdownFile in $markdownFiles) {
    $displayPath = Get-RepositoryRelativePath -FullName $markdownFile.FullName
    $markdownText = Read-Utf8Text -Path $markdownFile.FullName -DisplayPath $displayPath
    $markdownText = Remove-MarkdownFences -Text $markdownText
    $markdownText = Remove-MarkdownInlineCode -Text $markdownText

    $references = @{}
    $definitionPattern = '(?m)^[ ]{0,3}\[(?<label>(?:\\.|[^\]])+)\]:[ \t]*(?<tail>[^\r\n]*)\r?$'
    foreach ($definition in [regex]::Matches($markdownText, $definitionPattern)) {
        $key = Normalize-MarkdownReferenceLabel -Label $definition.Groups['label'].Value
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        if ($references.ContainsKey($key)) {
            continue
        }
        $parsedDefinition = Read-MarkdownDestination -Text $definition.Groups['tail'].Value -StartIndex 0 -Inline $false
        if ($null -eq $parsedDefinition) {
            throw "Markdown reference definition is invalid in $displayPath."
        }
        $references[$key] = $parsedDefinition.Target
    }

    foreach ($entry in $references.GetEnumerator()) {
        Assert-MarkdownTarget -RawTarget $entry.Value -MarkdownFile $markdownFile
    }

    $inlinePattern = '!?\[(?:\\.|[^\]])*\]\('
    foreach ($inlineMatch in [regex]::Matches($markdownText, $inlinePattern)) {
        $openingBracketIndex = $inlineMatch.Index
        if ($markdownText[$openingBracketIndex] -eq '!') {
            $openingBracketIndex++
        }
        if (Test-IsMarkdownCharacterEscaped -Text $markdownText -Index $openingBracketIndex) {
            continue
        }
        $parsedInline = Read-MarkdownDestination -Text $markdownText -StartIndex ($inlineMatch.Index + $inlineMatch.Length) -Inline $true
        if ($null -ne $parsedInline) {
            Assert-MarkdownTarget -RawTarget $parsedInline.Target -MarkdownFile $markdownFile
        }
    }

    $referencePattern = '!?\[(?<label>(?:\\.|[^\]])*)\]\[(?<id>(?:\\.|[^\]])*)\]'
    foreach ($referenceMatch in [regex]::Matches($markdownText, $referencePattern)) {
        $openingBracketIndex = $referenceMatch.Index
        if ($markdownText[$openingBracketIndex] -eq '!') {
            $openingBracketIndex++
        }
        if (Test-IsMarkdownCharacterEscaped -Text $markdownText -Index $openingBracketIndex) {
            continue
        }
        $referenceId = $referenceMatch.Groups['id'].Value
        if ([string]::IsNullOrEmpty($referenceId)) {
            $referenceId = $referenceMatch.Groups['label'].Value
        }
        $key = Normalize-MarkdownReferenceLabel -Label $referenceId
        if (-not $references.ContainsKey($key)) {
            throw "Undefined Markdown reference '$key' in $displayPath."
        }
        Assert-MarkdownTarget -RawTarget $references[$key] -MarkdownFile $markdownFile
    }
}

function Test-IsNonEmptyYamlScalar {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $candidate = $Value.Trim()
    if (
        [string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^(?i:null|~|true|false|yes|no|on|off)$' -or
        $candidate -match '^[|>\[\{]' -or
        $candidate -match '^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$'
    ) {
        return $false
    }
    if ($candidate.StartsWith('#')) {
        return $false
    }
    $first = $candidate.Substring(0, 1)
    $last = $candidate.Substring($candidate.Length - 1, 1)
    if ($first -eq '"' -or $first -eq "'") {
        if ($candidate.Length -lt 2 -or $last -ne $first) {
            return $false
        }
        return -not [string]::IsNullOrWhiteSpace($candidate.Substring(1, $candidate.Length - 2))
    }
    if ($last -eq '"' -or $last -eq "'") {
        return $false
    }
    return $true
}

function Get-FrontmatterScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $pattern = '(?m)^' + [regex]::Escape($Name) + ':[ \t]*(?<value>[^\r\n]*)\r?$'
    $matches = [regex]::Matches($Body, $pattern)
    if ($matches.Count -ne 1) {
        throw "SKILL.md frontmatter $Name is missing or duplicated."
    }
    return $matches[0].Groups['value'].Value
}

$skillFile = Require-File -RelativePath 'SKILL.md'
$skillText = Read-Utf8Text -Path $skillFile.FullName -DisplayPath 'SKILL.md'
$frontmatter = [regex]::Match(
    $skillText,
    '\A---\r?\n(?<body>.*?)\r?\n---(?:\r?\n|\z)',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $frontmatter.Success) {
    throw 'SKILL.md frontmatter is missing or has an invalid closing marker.'
}
$frontmatterBody = $frontmatter.Groups['body'].Value
$allowedFrontmatterKeys = @('name', 'description', 'license', 'allowed-tools', 'metadata')
$topLevelKeys = @(
    [regex]::Matches($frontmatterBody, '(?m)^(?<name>[A-Za-z][A-Za-z0-9_-]*):') |
        ForEach-Object { $_.Groups['name'].Value } |
        Sort-Object -Unique
)
$unexpectedFrontmatterKeys = @($topLevelKeys | Where-Object { $_ -notin $allowedFrontmatterKeys })
if ($unexpectedFrontmatterKeys.Count -gt 0) {
    throw "SKILL.md frontmatter contains unsupported key(s): $($unexpectedFrontmatterKeys -join ', ')."
}
$frontmatterName = Get-FrontmatterScalar -Body $frontmatterBody -Name 'name'
if ($frontmatterName.Trim() -cne 'warship-girls-r-event-runner') {
    throw 'SKILL.md frontmatter name is invalid.'
}
$description = Get-FrontmatterScalar -Body $frontmatterBody -Name 'description'
if (-not (Test-IsNonEmptyYamlScalar -Value $description)) {
    throw 'SKILL.md frontmatter description is empty.'
}

Write-Output 'Repository validation passed.'
