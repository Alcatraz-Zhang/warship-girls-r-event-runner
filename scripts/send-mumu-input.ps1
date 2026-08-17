[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Tap', 'Swipe', 'KeyEvent')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceJson,

    [int]$X,
    [int]$Y,
    [int]$X2,
    [int]$Y2,
    [ValidateRange(50, 5000)][int]$DurationMs = 400,
    [int]$KeyCode,
    [int]$GuardX,
    [int]$GuardY,

    [ValidateRange(1, 30)]
    [int]$MaxEvidenceAgeSeconds = 10,

    [ValidatePattern('^(?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z][A-Za-z0-9_]*$')]
    [string]$GamePackage = 'com.huanmeng.zhanjian2'
)

$ErrorActionPreference = 'Stop'

function Test-IsJsonObject {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
}

function Test-IsJsonInteger {
    param([AllowNull()][object]$Value)
    return (
        $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    )
}

function Write-InputReceipt {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Test-BoundedProcessSucceeded {
    param([object]$Result)
    return ($null -ne $Result -and -not $Result.TimedOut -and $null -ne $Result.ExitCode -and [int]$Result.ExitCode -eq 0)
}

switch ($Action) {
    'Tap' {
        if (-not $PSBoundParameters.ContainsKey('X') -or -not $PSBoundParameters.ContainsKey('Y')) {
            throw 'Tap requires -X and -Y.'
        }
    }
    'Swipe' {
        foreach ($required in @('X', 'Y', 'X2', 'Y2')) {
            if (-not $PSBoundParameters.ContainsKey($required)) { throw "Swipe requires -$required." }
        }
    }
    'KeyEvent' {
        if (-not $PSBoundParameters.ContainsKey('KeyCode')) { throw 'KeyEvent requires -KeyCode.' }
        $allowedKeyCodes = @(66, 67, 112, 279)
        if ($allowedKeyCodes -notcontains $KeyCode) {
            throw "KeyEvent key code $KeyCode is not allowed. Allowed key codes: 66, 67, 112, 279."
        }
        if (-not $PSBoundParameters.ContainsKey('GuardX') -or -not $PSBoundParameters.ContainsKey('GuardY')) {
            throw 'KeyEvent requires -GuardX and -GuardY.'
        }
    }
}

$resolver = Join-Path $PSScriptRoot 'resolve-mumu-target.ps1'
$processHelper = Join-Path $PSScriptRoot 'invoke-bounded-process.ps1'
$visualHelper = Join-Path $PSScriptRoot 'compare-mumu-visual-state.ps1'
if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
    throw "Resolver not found: $resolver"
}
if (-not (Test-Path -LiteralPath $processHelper -PathType Leaf)) {
    throw "Bounded process helper not found: $processHelper"
}
if (-not (Test-Path -LiteralPath $visualHelper -PathType Leaf)) {
    throw "Visual comparison helper not found: $visualHelper"
}
. $processHelper
. $visualHelper
if (-not (Test-Path -LiteralPath $EvidenceJson -PathType Leaf)) {
    throw "Evidence JSON not found: $EvidenceJson"
}

$receiptPath = "$EvidenceJson.consumed.json"
if (Test-Path -LiteralPath $receiptPath) {
    throw "Input refused: this screenshot evidence was already consumed. Capture again. Receipt: $receiptPath"
}

$evidenceText = [IO.File]::ReadAllText($EvidenceJson, [Text.Encoding]::UTF8)
try {
    $evidence = $evidenceText | ConvertFrom-Json
} catch {
    throw 'Input refused: evidence is not valid JSON.'
}
if ($evidenceText -notmatch '^\s*\{' -or -not (Test-IsJsonObject $evidence)) {
    throw 'Input refused: evidence root must be a JSON object.'
}

$schemaVersionProperty = $evidence.PSObject.Properties['SchemaVersion']
if ($null -eq $schemaVersionProperty -or
    -not (Test-IsJsonInteger $schemaVersionProperty.Value) -or
    $schemaVersionProperty.Value -ne 1) {
    throw 'Input refused: evidence SchemaVersion must be integer 1.'
}

$stableProperty = $evidence.PSObject.Properties['Stable']
if ($null -eq $stableProperty -or $stableProperty.Value -isnot [bool] -or -not $stableProperty.Value) {
    throw 'Input refused: screenshot evidence is marked unstable or has an invalid Stable value.'
}

$capturedAtProperty = $evidence.PSObject.Properties['CapturedAtUtc']
if ($null -eq $capturedAtProperty -or
    (($capturedAtProperty.Value -isnot [string]) -and ($capturedAtProperty.Value -isnot [DateTime])) -or
    [string]::IsNullOrWhiteSpace([string]$capturedAtProperty.Value)) {
    throw 'Input refused: evidence CapturedAtUtc must be a non-empty JSON string.'
}

$screenshotPathProperty = $evidence.PSObject.Properties['ScreenshotPath']
if ($null -eq $screenshotPathProperty -or
    $screenshotPathProperty.Value -isnot [string] -or
    [string]::IsNullOrWhiteSpace($screenshotPathProperty.Value)) {
    throw 'Input refused: evidence ScreenshotPath must be a non-empty JSON string.'
}

foreach ($dimensionName in @('Width', 'Height')) {
    $property = $evidence.PSObject.Properties[$dimensionName]
    if ($null -eq $property -or -not (Test-IsJsonInteger $property.Value) -or $property.Value -lt 1) {
        throw "Input refused: evidence $dimensionName must be a positive integer."
    }
}

$sha256Property = $evidence.PSObject.Properties['Sha256']
if ($null -eq $sha256Property -or
    $sha256Property.Value -isnot [string] -or
    $sha256Property.Value -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'Input refused: evidence Sha256 must be a 64-character hexadecimal string.'
}

$fingerprintProperty = $evidence.PSObject.Properties['Fingerprint']
if ($null -eq $fingerprintProperty -or -not (Test-IsJsonObject $fingerprintProperty.Value)) {
    throw 'Input refused: evidence Fingerprint must be a JSON object.'
}
$expected = $evidence.Fingerprint

$vmIndexProperty = $expected.PSObject.Properties['VmIndex']
if ($null -eq $vmIndexProperty -or
    ($null -ne $vmIndexProperty.Value -and
        (-not (Test-IsJsonInteger $vmIndexProperty.Value) -or
            $vmIndexProperty.Value -lt 0 -or $vmIndexProperty.Value -gt 2147483647))) {
    throw 'Input refused: evidence Fingerprint.VmIndex has an invalid type.'
}

$bootIdProperty = $expected.PSObject.Properties['BootId']
if ($null -eq $bootIdProperty -or
    ($null -ne $bootIdProperty.Value -and
        ($bootIdProperty.Value -isnot [string] -or
            $bootIdProperty.Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'))) {
    throw 'Input refused: evidence Fingerprint.BootId has an invalid type.'
}

foreach ($fieldName in @('AndroidId', 'GamePid', 'ForegroundPackage', 'ForegroundActivity', 'PhysicalSize')) {
    $property = $expected.PSObject.Properties[$fieldName]
    if ($null -eq $property -or $property.Value -isnot [string]) {
        throw "Input refused: evidence Fingerprint.$fieldName has an invalid type."
    }
}

if ($expected.GamePid -notmatch '^(?:|[1-9]\d*)$') {
    throw 'Input refused: evidence Fingerprint.GamePid has an invalid type.'
}
if ($expected.PhysicalSize -notmatch '^(?:|[1-9]\d*x[1-9]\d*)$') {
    throw 'Input refused: evidence Fingerprint.PhysicalSize has an invalid type.'
}

$overrideSizeProperty = $expected.PSObject.Properties['OverrideSize']
if ($null -eq $overrideSizeProperty -or
    ($null -ne $overrideSizeProperty.Value -and
        ($overrideSizeProperty.Value -isnot [string] -or
            $overrideSizeProperty.Value -notmatch '^(?:|[1-9]\d*x[1-9]\d*)$'))) {
    throw 'Input refused: evidence Fingerprint.OverrideSize has an invalid type.'
}

$rotationProperty = $expected.PSObject.Properties['Rotation']
if ($null -eq $rotationProperty -or
    ($null -ne $rotationProperty.Value -and
        (-not (Test-IsJsonInteger $rotationProperty.Value) -or
            $rotationProperty.Value -lt 0 -or $rotationProperty.Value -gt 3))) {
    throw 'Input refused: evidence Fingerprint.Rotation has an invalid type.'
}

switch ($Action) {
    'Tap' {
        if ($X -lt 0 -or $X -ge $evidence.Width -or $Y -lt 0 -or $Y -ge $evidence.Height) {
            throw "Tap coordinate is outside the captured image: ${X}x${Y}, image=$($evidence.Width)x$($evidence.Height)"
        }
    }
    'Swipe' {
        foreach ($value in @($X, $Y, $X2, $Y2)) {
            if ($value -lt 0) { throw 'Swipe coordinates must be non-negative.' }
        }
        if ($X -ge $evidence.Width -or $X2 -ge $evidence.Width -or $Y -ge $evidence.Height -or $Y2 -ge $evidence.Height) {
            throw "Swipe coordinate is outside the captured image: image=$($evidence.Width)x$($evidence.Height)"
        }
    }
    'KeyEvent' {
        if ($GuardX -lt 0 -or $GuardX -ge $evidence.Width -or $GuardY -lt 0 -or $GuardY -ge $evidence.Height) {
            throw "KeyEvent guard coordinate is outside the captured image: ${GuardX}x${GuardY}, image=$($evidence.Width)x$($evidence.Height)"
        }
    }
}

$capturedAt = [DateTimeOffset]::MinValue
if ($evidence.CapturedAtUtc -is [DateTime]) {
    # PowerShell 7 may deserialize an ISO JSON string directly as DateTime.
    # Casting it back to string would lose the UTC kind under a local culture.
    $capturedAt = [DateTimeOffset]$evidence.CapturedAtUtc
} elseif (-not [DateTimeOffset]::TryParse([string]$evidence.CapturedAtUtc, [ref]$capturedAt)) {
    throw 'Input refused: evidence has no valid capture time.'
}
$ageSeconds = ([DateTimeOffset]::UtcNow - $capturedAt.ToUniversalTime()).TotalSeconds
if ($ageSeconds -lt -5 -or $ageSeconds -gt $MaxEvidenceAgeSeconds) {
    throw "Input refused: evidence age is $([math]::Round($ageSeconds, 1)) seconds. Capture a fresh screenshot."
}

$screenshotPath = $evidence.ScreenshotPath
if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) {
    throw "Input refused: screenshot is missing: $screenshotPath"
}
$liveHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
if ($liveHash -ne [string]$evidence.Sha256) {
    throw 'Input refused: screenshot hash does not match its evidence sidecar.'
}

$parameters = @{
    Action            = 'Info'
    GamePackage       = $GamePackage
    RequireForeground = $true
}
if ($null -ne $expected.VmIndex -and [string]$expected.VmIndex -ne '') {
    $parameters.VmIndex = [int]$expected.VmIndex
}
$liveJson = & $resolver @parameters
if (-not $liveJson) { throw 'Live target resolution failed.' }
$live = $liveJson | ConvertFrom-Json

$keys = @('VmIndex', 'BootId', 'AndroidId', 'GamePid', 'ForegroundPackage', 'ForegroundActivity', 'PhysicalSize', 'OverrideSize', 'Rotation')
$differences = [System.Collections.Generic.List[string]]::new()
foreach ($key in $keys) {
    if ([string]$expected.$key -cne [string]$live.$key) {
        [void]$differences.Add("$key expected='$($expected.$key)' live='$($live.$key)'")
    }
}
if ($differences.Count -gt 0) {
    throw "Input refused because the target changed: $($differences -join '; ')"
}

$postResolutionAgeSeconds = ([DateTimeOffset]::UtcNow - $capturedAt.ToUniversalTime()).TotalSeconds
if ($postResolutionAgeSeconds -lt -5 -or $postResolutionAgeSeconds -gt $MaxEvidenceAgeSeconds) {
    throw "Input refused: evidence age is $([math]::Round($postResolutionAgeSeconds, 1)) seconds. Capture a fresh screenshot."
}
if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) {
    throw "Input refused: screenshot is missing: $screenshotPath"
}
$postResolutionHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
if ($postResolutionHash -ne [string]$evidence.Sha256) {
    throw 'Input refused: screenshot hash does not match its evidence sidecar.'
}
$liveHash = $postResolutionHash

# Reserve this sidecar atomically before any live visual check. The receipt remains
# even when checking or input fails; retrying always requires new screenshot evidence.
try {
    $receiptStream = [System.IO.File]::Open(
        $receiptPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    $receiptStream.Dispose()
} catch [System.IO.IOException] {
    throw "Input refused: this screenshot evidence was already consumed. Capture again. Receipt: $receiptPath"
}

$receipt = [ordered]@{
    SchemaVersion     = 1
    ReservedAtUtc     = [DateTime]::UtcNow.ToString('o')
    Action            = $Action
    EvidenceJson      = (Resolve-Path -LiteralPath $EvidenceJson).Path
    Screenshot        = (Resolve-Path -LiteralPath $screenshotPath).Path
    ScreenshotSha256  = $liveHash
    Status            = 'reserved'
}
Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)

$visualId = [guid]::NewGuid().ToString('N')
$visualTempRoot = [IO.Path]::GetTempPath()
$localA = Join-Path $visualTempRoot "codex-visual-$visualId-a.png"
$localB = Join-Path $visualTempRoot "codex-visual-$visualId-b.png"
$remoteA = "/sdcard/codex-visual-$visualId-a.png"
$remoteB = "/sdcard/codex-visual-$visualId-b.png"
$frameAStartedAt = $null
$frameBStartedAt = $null

try {
    $captureSteps = @(
        [pscustomobject]@{ Label = 'live frame A screencap'; Arguments = @('-s', [string]$live.Serial, 'shell', 'screencap', '-p', $remoteA); LocalPath = $null; Frame = 'A' }
    )
    foreach ($step in $captureSteps) {
        if ($step.Frame -eq 'A') { $frameAStartedAt = [DateTimeOffset]::UtcNow }
        $stepResult = Invoke-BoundedProcess -FilePath ([string]$live.AdbPath) -ArgumentList $step.Arguments -TimeoutMs 8000
        if (-not (Test-BoundedProcessSucceeded -Result $stepResult) -or
            ($step.LocalPath -and -not (Test-Path -LiteralPath $step.LocalPath -PathType Leaf))) {
            $receipt.Status = 'visual-check-error-or-unknown'
            $receipt.VisualGuard = [ordered]@{
                Passed   = $false
                Decision = 'capture-error'
                Step     = $step.Label
                TimedOut = [bool]$stepResult.TimedOut
                ExitCode = $stepResult.ExitCode
            }
            Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
            throw "Visual freshness check failed or may be incomplete: $($step.Label). Capture again before retrying."
        }
    }

    Start-Sleep -Milliseconds 180

    $captureSteps = @(
        [pscustomobject]@{ Label = 'live frame B screencap'; Arguments = @('-s', [string]$live.Serial, 'shell', 'screencap', '-p', $remoteB); LocalPath = $null; Frame = 'B' },
        [pscustomobject]@{ Label = 'live frame A pull'; Arguments = @('-s', [string]$live.Serial, 'pull', $remoteA, $localA); LocalPath = $localA; Frame = '' },
        [pscustomobject]@{ Label = 'live frame B pull'; Arguments = @('-s', [string]$live.Serial, 'pull', $remoteB, $localB); LocalPath = $localB; Frame = '' }
    )
    foreach ($step in $captureSteps) {
        if ($step.Frame -eq 'B') { $frameBStartedAt = [DateTimeOffset]::UtcNow }
        $stepResult = Invoke-BoundedProcess -FilePath ([string]$live.AdbPath) -ArgumentList $step.Arguments -TimeoutMs 8000
        if (-not (Test-BoundedProcessSucceeded -Result $stepResult) -or
            ($step.LocalPath -and -not (Test-Path -LiteralPath $step.LocalPath -PathType Leaf))) {
            $receipt.Status = 'visual-check-error-or-unknown'
            $receipt.VisualGuard = [ordered]@{
                Passed   = $false
                Decision = 'capture-error'
                Step     = $step.Label
                TimedOut = [bool]$stepResult.TimedOut
                ExitCode = $stepResult.ExitCode
            }
            Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
            throw "Visual freshness check failed or may be incomplete: $($step.Label). Capture again before retrying."
        }
    }

    try {
        $liveAfterJson = & $resolver @parameters
        if (-not $liveAfterJson) { throw 'empty resolver output' }
        $liveAfter = $liveAfterJson | ConvertFrom-Json
    } catch {
        $receipt.Status = 'target-resolution-error-or-unknown'
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw 'Input refused because target resolution failed during visual checking. Capture again.'
    }

    $postVisualDifferences = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $keys) {
        if ([string]$expected.$key -cne [string]$liveAfter.$key) {
            [void]$postVisualDifferences.Add("$key expected='$($expected.$key)' live='$($liveAfter.$key)'")
        }
    }
    if ($postVisualDifferences.Count -gt 0) {
        $receipt.Status = 'target-changed-before-input'
        $receipt.TargetDifferences = @($postVisualDifferences)
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw "Input refused because the target changed during visual checking: $($postVisualDifferences -join '; ')"
    }

    $visualAgeSeconds = ([DateTimeOffset]::UtcNow - $capturedAt.ToUniversalTime()).TotalSeconds
    if ($visualAgeSeconds -lt -5 -or $visualAgeSeconds -gt $MaxEvidenceAgeSeconds) {
        $receipt.Status = 'evidence-expired-before-input'
        $receipt.EvidenceAgeSeconds = [Math]::Round($visualAgeSeconds, 3)
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw 'Input refused: evidence expired during visual checking. Capture again.'
    }
    if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash -ne [string]$evidence.Sha256) {
        $receipt.Status = 'evidence-changed-before-input'
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw 'Input refused: screenshot evidence changed during visual checking. Capture again.'
    }

    $visualX = if ($Action -eq 'KeyEvent') { $GuardX } else { $X }
    $visualY = if ($Action -eq 'KeyEvent') { $GuardY } else { $Y }
    $comparisonParameters = @{
        EvidencePath   = $screenshotPath
        LiveAPath      = $localA
        LiveBPath      = $localB
        Action         = $Action
        X              = $visualX
        Y              = $visualY
        EvidenceWidth  = [int]$evidence.Width
        EvidenceHeight = [int]$evidence.Height
    }
    if ($Action -eq 'Swipe') {
        $comparisonParameters.X2 = $X2
        $comparisonParameters.Y2 = $Y2
    }
    try {
        $comparison = Compare-MumuVisualFrames @comparisonParameters
    } catch {
        $receipt.Status = 'visual-check-error-or-unknown'
        $receipt.VisualGuard = [ordered]@{ Passed = $false; Decision = 'comparison-error' }
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw "Visual freshness check failed or may be incomplete: image comparison. Capture again before retrying."
    }

    $frameGapMs = [long][Math]::Round(($frameBStartedAt - $frameAStartedAt).TotalMilliseconds)
    $receipt.VisualGuard = [ordered]@{
        AlgorithmVersion        = $comparison.AlgorithmVersion
        Passed                  = [bool]$comparison.Passed
        Decision                = [string]$comparison.Decision
        CheckedAtUtc            = [DateTime]::UtcNow.ToString('o')
        FrameGapMs              = $frameGapMs
        SampleWidth             = $comparison.SampleWidth
        SampleHeight            = $comparison.SampleHeight
        StaticPixelCount        = $comparison.StaticPixelCount
        DynamicPixelCount       = $comparison.DynamicPixelCount
        DynamicFraction         = $comparison.DynamicFraction
        GlobalMeanRgbDelta      = $comparison.GlobalMeanRgbDelta
        GlobalMeanGradientDelta = $comparison.GlobalMeanGradientDelta
        GlobalChangedFraction   = $comparison.GlobalChangedFraction
        LocalPixelCount         = $comparison.LocalPixelCount
        LocalStaticPixelCount   = $comparison.LocalStaticPixelCount
        LocalDynamicFraction    = $comparison.LocalDynamicFraction
        LocalMeanRgbDelta       = $comparison.LocalMeanRgbDelta
        LocalMeanGradientDelta  = $comparison.LocalMeanGradientDelta
        LocalChangedFraction    = $comparison.LocalChangedFraction
        Thresholds              = $comparison.Thresholds
    }
    if (-not $comparison.Passed) {
        $receipt.Status = 'visual-rejected'
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw "Input refused: visual guard rejected the live screen: $($comparison.Decision). Capture again."
    }

    $finalAgeSeconds = ([DateTimeOffset]::UtcNow - $capturedAt.ToUniversalTime()).TotalSeconds
    if ($finalAgeSeconds -lt -5 -or $finalAgeSeconds -gt $MaxEvidenceAgeSeconds) {
        $receipt.Status = 'evidence-expired-before-input'
        $receipt.EvidenceAgeSeconds = [Math]::Round($finalAgeSeconds, 3)
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw 'Input refused: evidence expired during visual checking. Capture again.'
    }

    $liveFrameAgeSeconds = ([DateTimeOffset]::UtcNow - $frameBStartedAt).TotalSeconds
    if ($liveFrameAgeSeconds -lt -1 -or $liveFrameAgeSeconds -gt 3) {
        $receipt.Status = 'live-frame-expired-before-input'
        $receipt.LiveFrameAgeSeconds = [Math]::Round($liveFrameAgeSeconds, 3)
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw 'Input refused: live screen evidence expired before input. Capture again.'
    }

    $inputArguments = switch ($Action) {
        'Tap' { @('-s', [string]$liveAfter.Serial, 'shell', 'input', 'tap', [string]$X, [string]$Y) }
        'Swipe' { @('-s', [string]$liveAfter.Serial, 'shell', 'input', 'swipe', [string]$X, [string]$Y, [string]$X2, [string]$Y2, [string]$DurationMs) }
        'KeyEvent' { @('-s', [string]$liveAfter.Serial, 'shell', 'input', 'keyevent', [string]$KeyCode) }
    }
    $inputResult = Invoke-BoundedProcess -FilePath ([string]$liveAfter.AdbPath) -ArgumentList $inputArguments -TimeoutMs 5000
    if (-not (Test-BoundedProcessSucceeded -Result $inputResult)) {
        $receipt.Status = 'adb-error-or-unknown'
        $receipt.InputTimedOut = [bool]$inputResult.TimedOut
        $receipt.InputExitCode = $inputResult.ExitCode
        Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)
        throw "ADB input failed or may have partially executed: $Action. Capture again before retrying."
    }

    $receipt.Status = 'sent'
    $receipt.SentAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-InputReceipt -Path $receiptPath -Value ([pscustomobject]$receipt)

    [pscustomobject]@{
        Action   = $Action
        Serial   = $liveAfter.Serial
        VmIndex  = $liveAfter.VmIndex
        GamePid  = $liveAfter.GamePid
        Evidence = (Resolve-Path -LiteralPath $EvidenceJson).Path
        Receipt   = (Resolve-Path -LiteralPath $receiptPath).Path
        SentAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
} finally {
    foreach ($localPath in @($localA, $localB)) {
        if (Test-Path -LiteralPath $localPath -PathType Leaf) {
            Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        }
    }
    try {
        [void](Invoke-BoundedProcess -FilePath ([string]$live.AdbPath) -ArgumentList @('-s', [string]$live.Serial, 'shell', 'rm', '-f', $remoteA, $remoteB) -TimeoutMs 3000)
    } catch { }
}
