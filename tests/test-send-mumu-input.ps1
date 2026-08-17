[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$failures = [System.Collections.Generic.List[string]]::new()
$environmentNames = @(
    'INPUT_ADB_LOG',
    'INPUT_ADB_FAIL',
    'INPUT_FOREGROUND_ACTIVITY',
    'INPUT_RESOLVER_LOG',
    'INPUT_NULLABLE_FINGERPRINT',
    'INPUT_RESOLVER_DELAY_MS',
    'INPUT_SECOND_RESOLVER_DELAY_MS',
    'INPUT_SECOND_FOREGROUND_ACTIVITY',
    'INPUT_SCREENSHOT_MUTATION',
    'INPUT_SCREENSHOT_PATH',
    'INPUT_SEQUENCE_LOG',
    'INPUT_VISUAL_A',
    'INPUT_VISUAL_B',
    'INPUT_VISUAL_B_DELAY_MS',
    'INPUT_VISUAL_FAILURE'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Set-TestEnvironment {
    param([string]$Name, [AllowNull()][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Output "PASS $Name"
    } catch {
        [void]$failures.Add("$Name`: $($_.Exception.Message)")
        Write-Output "FAIL $Name`: $($_.Exception.Message)"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$MessagePattern)
    $caught = $null
    try {
        & $Body | Out-Null
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "Expected failure matching '$MessagePattern', but the command succeeded."
    }
    if ($caught.Exception.Message -notmatch $MessagePattern) {
        throw "Expected failure matching '$MessagePattern', got '$($caught.Exception.Message)'."
    }
}

function Assert-ParameterValidationFailure {
    param([scriptblock]$Body)
    $caught = $null
    try {
        & $Body | Out-Null
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw 'Expected parameter validation, but the command succeeded.'
    }
    if ($caught.FullyQualifiedErrorId -notmatch 'ParameterArgumentValidationError') {
        throw "Expected parameter validation; got '$($caught.FullyQualifiedErrorId)': $($caught.Exception.Message)"
    }
}

function Get-AdbCallCount {
    if (-not (Test-Path -LiteralPath $script:adbLog -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $script:adbLog).Count
}

function Get-ResolverCallCount {
    if (-not (Test-Path -LiteralPath $script:resolverLog -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $script:resolverLog).Count
}

function Get-InputCalls {
    if (-not (Test-Path -LiteralPath $script:adbLog -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $script:adbLog | Where-Object { $_ -match '^-s offline shell input ' })
}

function Get-InputCallCount {
    return @(Get-InputCalls).Count
}

function Assert-NoInputCall {
    param([scriptblock]$Body, [string]$MessagePattern)
    $before = Get-InputCallCount
    Assert-Throws -Body $Body -MessagePattern $MessagePattern
    $after = Get-InputCallCount
    if ($after -ne $before) {
        throw "Rejected input sent $($after - $before) input command(s)."
    }
}

function Assert-NoAdbCall {
    param([scriptblock]$Body, [string]$MessagePattern)
    $before = Get-AdbCallCount
    Assert-Throws -Body $Body -MessagePattern $MessagePattern
    $after = Get-AdbCallCount
    if ($after -ne $before) {
        throw "Rejected input called ADB $($after - $before) time(s)."
    }
}

function Assert-NoResolverOrAdbCall {
    param([scriptblock]$Body, [string]$MessagePattern)
    $resolverBefore = Get-ResolverCallCount
    $adbBefore = Get-AdbCallCount
    Assert-Throws -Body $Body -MessagePattern $MessagePattern
    $resolverAfter = Get-ResolverCallCount
    $adbAfter = Get-AdbCallCount
    if ($resolverAfter -ne $resolverBefore) {
        throw "Rejected evidence called the resolver $($resolverAfter - $resolverBefore) time(s)."
    }
    if ($adbAfter -ne $adbBefore) {
        throw "Rejected evidence called ADB $($adbAfter - $adbBefore) time(s)."
    }
}

function Assert-RejectedBeforeResolution {
    param(
        [string]$EvidencePath,
        [scriptblock]$Body,
        [string]$MessagePattern
    )
    Assert-NoResolverOrAdbCall -Body $Body -MessagePattern $MessagePattern
    if (Test-Path -LiteralPath "$EvidencePath.consumed.json" -PathType Leaf) {
        throw 'Rejected input created a consumed receipt.'
    }
}

function Assert-RejectedAfterResolution {
    param(
        [string]$EvidencePath,
        [scriptblock]$Body,
        [string]$MessagePattern
    )
    $resolverBefore = Get-ResolverCallCount
    $adbBefore = Get-AdbCallCount
    Assert-Throws -Body $Body -MessagePattern $MessagePattern
    $resolverAfter = Get-ResolverCallCount
    $adbAfter = Get-AdbCallCount
    if ($resolverAfter -ne ($resolverBefore + 1)) {
        throw "Expected one resolver call before rejection; got $($resolverAfter - $resolverBefore)."
    }
    if ($adbAfter -ne $adbBefore) {
        throw "Rejected input called ADB $($adbAfter - $adbBefore) time(s)."
    }
    if (Test-Path -LiteralPath "$EvidencePath.consumed.json" -PathType Leaf) {
        throw 'Rejected input created a consumed receipt.'
    }
}

function Set-EvidenceProperty {
    param(
        [string]$Path,
        [string]$Name,
        [AllowNull()][object]$Value
    )
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $document.$Name = $Value
    $json = $document | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json, [Text.Encoding]::ASCII)
}

function Set-FingerprintProperty {
    param(
        [string]$Path,
        [string]$Name,
        [AllowNull()][object]$Value
    )
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $document.Fingerprint.$Name = $Value
    $json = $document | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json, [Text.Encoding]::ASCII)
}

function New-Evidence {
    param(
        [string]$Name,
        [DateTimeOffset]$CapturedAt = [DateTimeOffset]::UtcNow,
        [string]$ForegroundActivity = 'Main'
    )
    $fingerprint = [ordered]@{
        VmIndex = 0
        BootId = '11111111-2222-4333-8444-555555555555'
        AndroidId = 'android'
        GamePid = '1234'
        ForegroundPackage = 'com.huanmeng.zhanjian2'
        ForegroundActivity = $ForegroundActivity
        PhysicalSize = '1080x1920'
        OverrideSize = ''
        Rotation = 0
    }
    $path = Join-Path $tempRoot "$Name.json"
    $document = [ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = $CapturedAt.ToUniversalTime().ToString('o')
        Stable = $true
        ScreenshotPath = $script:screenshot
        Width = 640
        Height = 360
        Sha256 = $script:hash
        Fingerprint = $fingerprint
    }
    $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding ascii
    return $path
}

function New-SyntheticFrame {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('base', 'remote-a', 'remote-b', 'tap-changed', 'state-changed', 'popup', 'page', 'transition-a', 'transition-b')]
        [string]$Variant = 'base'
    )

    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(640, 360, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(18, 31, 45))
        $graphics.FillRectangle([Drawing.Brushes]::SteelBlue, 24, 24, 210, 72)
        $graphics.FillRectangle([Drawing.Brushes]::DarkSlateGray, 40, 126, 560, 46)
        $graphics.FillRectangle([Drawing.Brushes]::Goldenrod, 72, 215, 188, 90)
        $graphics.DrawRectangle([Drawing.Pens]::White, 300, 205, 278, 106)

        switch ($Variant) {
            'remote-a' { $graphics.FillRectangle([Drawing.Brushes]::OrangeRed, 592, 8, 24, 20) }
            'remote-b' { $graphics.FillRectangle([Drawing.Brushes]::DeepSkyBlue, 592, 8, 24, 20) }
            'tap-changed' { $graphics.FillRectangle([Drawing.Brushes]::Lime, 286, 150, 68, 60) }
            'state-changed' { $graphics.FillRectangle([Drawing.Brushes]::Lime, 305, 165, 30, 30) }
            'popup' {
                $graphics.FillRectangle([Drawing.Brushes]::Gainsboro, 176, 72, 288, 216)
                $graphics.DrawRectangle([Drawing.Pens]::Black, 176, 72, 288, 216)
            }
            'page' {
                $graphics.Clear([Drawing.Color]::FromArgb(212, 198, 166))
                $graphics.FillRectangle([Drawing.Brushes]::Maroon, 32, 36, 576, 90)
                $graphics.FillRectangle([Drawing.Brushes]::Navy, 70, 188, 500, 126)
            }
            'transition-a' { $graphics.Clear([Drawing.Color]::FromArgb(45, 20, 120)) }
            'transition-b' { $graphics.Clear([Drawing.Color]::FromArgb(170, 120, 15)) }
        }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    if ([IO.Path]::GetFileName($tempRoot) -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Temporary root is not GUID-named.'
    }

    $source = Join-Path $repo 'scripts/send-mumu-input.ps1'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'Input helper is missing.'
    }
    $helper = Join-Path $tempRoot 'send-mumu-input.ps1'
    Copy-Item -LiteralPath $source -Destination $helper
    foreach ($supportName in @('compare-mumu-visual-state.ps1', 'invoke-bounded-process.ps1')) {
        $supportSource = Join-Path $repo "scripts/$supportName"
        if (Test-Path -LiteralPath $supportSource -PathType Leaf) {
            Copy-Item -LiteralPath $supportSource -Destination (Join-Path $tempRoot $supportName)
        }
    }

    Invoke-TestCase -Name 'visual helper accepts identical synthetic frames' -Body {
        $visualSource = Join-Path $repo 'scripts/compare-mumu-visual-state.ps1'
        if (-not (Test-Path -LiteralPath $visualSource -PathType Leaf)) {
            throw 'Visual comparison helper is missing.'
        }
        . $visualSource
        $evidenceFrame = Join-Path $tempRoot 'visual-identical-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-identical-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-identical-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        Copy-Item -LiteralPath $evidenceFrame -Destination $liveAFrame
        Copy-Item -LiteralPath $evidenceFrame -Destination $liveBFrame
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 320 -Y 180 -EvidenceWidth 640 -EvidenceHeight 360
        if (-not $comparison.Passed) {
            throw "Expected identical frames to pass; got '$($comparison.Decision)'."
        }
        if ($comparison.SampleWidth -ne 64 -or $comparison.SampleHeight -ne 36) {
            throw "Expected a fixed 64x36 sample; got $($comparison.SampleWidth)x$($comparison.SampleHeight)."
        }
    }

    Invoke-TestCase -Name 'visual helper masks a small remote animation' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        $evidenceFrame = Join-Path $tempRoot 'visual-animation-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-animation-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-animation-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        New-SyntheticFrame -Path $liveAFrame -Variant 'remote-a'
        New-SyntheticFrame -Path $liveBFrame -Variant 'remote-b'
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 320 -Y 180 -EvidenceWidth 640 -EvidenceHeight 360
        if (-not $comparison.Passed) {
            throw "Expected a small remote animation to pass; got '$($comparison.Decision)'."
        }
        if ($comparison.DynamicPixelCount -lt 1 -or $comparison.DynamicFraction -le 0) {
            throw 'Expected the A/B animation to produce a non-empty dynamic mask.'
        }
    }

    Invoke-TestCase -Name 'visual helper rejects a changed tap target' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        $evidenceFrame = Join-Path $tempRoot 'visual-tap-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-tap-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-tap-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        New-SyntheticFrame -Path $liveAFrame -Variant 'tap-changed'
        Copy-Item -LiteralPath $liveAFrame -Destination $liveBFrame
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 320 -Y 180 -EvidenceWidth 640 -EvidenceHeight 360
        if ($comparison.Passed -or $comparison.Decision -ne 'local-changed') {
            throw "Expected local-changed rejection; got Passed=$($comparison.Passed), Decision='$($comparison.Decision)'."
        }
        if ($comparison.LocalChangedFraction -le $comparison.Thresholds.LocalChangedFractionMaximum) {
            throw 'Expected changed tap target to exceed the fixed local changed-pixel threshold.'
        }
    }

    Invoke-TestCase -Name 'visual helper rejects a changed swipe corridor' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        $evidenceFrame = Join-Path $tempRoot 'visual-swipe-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-swipe-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-swipe-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        New-SyntheticFrame -Path $liveAFrame -Variant 'tap-changed'
        Copy-Item -LiteralPath $liveAFrame -Destination $liveBFrame
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Swipe -X 100 -Y 180 -X2 540 -Y2 180 -EvidenceWidth 640 -EvidenceHeight 360
        if ($comparison.Passed -or $comparison.Decision -ne 'local-changed') {
            throw "Expected changed swipe corridor to be rejected; got Passed=$($comparison.Passed), Decision='$($comparison.Decision)'."
        }
    }

    Invoke-TestCase -Name 'visual helper rejects a popup and a different page' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        foreach ($variant in @('popup', 'page')) {
            $evidenceFrame = Join-Path $tempRoot "visual-$variant-evidence.png"
            $liveAFrame = Join-Path $tempRoot "visual-$variant-a.png"
            $liveBFrame = Join-Path $tempRoot "visual-$variant-b.png"
            New-SyntheticFrame -Path $evidenceFrame
            New-SyntheticFrame -Path $liveAFrame -Variant $variant
            Copy-Item -LiteralPath $liveAFrame -Destination $liveBFrame
            $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 48 -Y 330 -EvidenceWidth 640 -EvidenceHeight 360
            if ($comparison.Passed -or $comparison.Decision -ne 'global-changed') {
                throw "Expected $variant to be rejected globally; got Passed=$($comparison.Passed), Decision='$($comparison.Decision)'."
            }
        }
    }

    Invoke-TestCase -Name 'visual helper rejects an A/B transition' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        $evidenceFrame = Join-Path $tempRoot 'visual-transition-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-transition-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-transition-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        New-SyntheticFrame -Path $liveAFrame -Variant 'transition-a'
        New-SyntheticFrame -Path $liveBFrame -Variant 'transition-b'
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 320 -Y 180 -EvidenceWidth 640 -EvidenceHeight 360
        if ($comparison.Passed -or $comparison.Decision -ne 'too-dynamic') {
            throw "Expected an A/B transition to be rejected; got Passed=$($comparison.Passed), Decision='$($comparison.Decision)'."
        }
    }

    Invoke-TestCase -Name 'visual helper rejects a small state transition between A and B' -Body {
        . (Join-Path $repo 'scripts/compare-mumu-visual-state.ps1')
        $evidenceFrame = Join-Path $tempRoot 'visual-small-transition-evidence.png'
        $liveAFrame = Join-Path $tempRoot 'visual-small-transition-a.png'
        $liveBFrame = Join-Path $tempRoot 'visual-small-transition-b.png'
        New-SyntheticFrame -Path $evidenceFrame
        New-SyntheticFrame -Path $liveAFrame
        New-SyntheticFrame -Path $liveBFrame -Variant 'state-changed'
        $comparison = Compare-MumuVisualFrames -EvidencePath $evidenceFrame -LiveAPath $liveAFrame -LiveBPath $liveBFrame -Action Tap -X 320 -Y 180 -EvidenceWidth 640 -EvidenceHeight 360
        if ($comparison.Passed) {
            throw 'Expected a small A/B state transition to be rejected.'
        }
        if ($comparison.DynamicFraction -le $comparison.Thresholds.DynamicFractionMaximum -and
            $comparison.LocalDynamicFraction -le $comparison.Thresholds.LocalDynamicFractionMaximum) {
            throw "Expected the small state transition to exceed a fixed dynamic threshold; got global=$($comparison.DynamicFraction), local=$($comparison.LocalDynamicFraction)."
        }
        if ($comparison.DynamicFraction -ge 0.350 -or $comparison.LocalDynamicFraction -ge 0.550) {
            throw "Synthetic transition is too large to protect the calibrated gap; got global=$($comparison.DynamicFraction), local=$($comparison.LocalDynamicFraction)."
        }
    }

    $resolver = Join-Path $tempRoot 'resolve-mumu-target.ps1'
    Set-Content -LiteralPath $resolver -Encoding ascii -Value @'
param([string]$Action, [string]$GamePackage, [bool]$RequireForeground, [int]$VmIndex)
$previousSequence = if ($env:INPUT_SEQUENCE_LOG -and (Test-Path -LiteralPath $env:INPUT_SEQUENCE_LOG -PathType Leaf)) {
    @(Get-Content -LiteralPath $env:INPUT_SEQUENCE_LOG)[-1]
} else { '' }
$isPostVisual = $previousSequence -match '^adb .+ pull .+-b\.png '
[IO.File]::AppendAllText($env:INPUT_RESOLVER_LOG, "resolve`r`n", [Text.Encoding]::ASCII)
$resolveCount = @(Get-Content -LiteralPath $env:INPUT_RESOLVER_LOG).Count
if ($env:INPUT_SEQUENCE_LOG) {
    [IO.File]::AppendAllText($env:INPUT_SEQUENCE_LOG, "resolve-$resolveCount`r`n", [Text.Encoding]::ASCII)
}
$delayMs = 0
if ([int]::TryParse($env:INPUT_RESOLVER_DELAY_MS, [ref]$delayMs) -and $delayMs -gt 0) {
    Start-Sleep -Milliseconds $delayMs
}
$secondDelayMs = 0
if ($isPostVisual -and [int]::TryParse($env:INPUT_SECOND_RESOLVER_DELAY_MS, [ref]$secondDelayMs) -and $secondDelayMs -gt 0) {
    Start-Sleep -Milliseconds $secondDelayMs
}
switch ($env:INPUT_SCREENSHOT_MUTATION) {
    'hash' { [IO.File]::WriteAllBytes($env:INPUT_SCREENSHOT_PATH, [byte[]](1, 2, 3, 4)) }
    'delete' { Remove-Item -LiteralPath $env:INPUT_SCREENSHOT_PATH -Force }
}
$activity = if ($isPostVisual -and $env:INPUT_SECOND_FOREGROUND_ACTIVITY) {
    $env:INPUT_SECOND_FOREGROUND_ACTIVITY
} elseif ($env:INPUT_FOREGROUND_ACTIVITY) {
    $env:INPUT_FOREGROUND_ACTIVITY
} else {
    'Main'
}
$nullableFingerprint = $env:INPUT_NULLABLE_FINGERPRINT -eq '1'
[pscustomobject]@{
    AdbPath = (Join-Path $PSScriptRoot 'adb.cmd')
    Serial = 'offline'
    VmIndex = if ($nullableFingerprint) { $null } else { $VmIndex }
    BootId = if ($nullableFingerprint) { $null } else { '11111111-2222-4333-8444-555555555555' }
    AndroidId = 'android'
    GamePid = '1234'
    ForegroundPackage = $GamePackage
    ForegroundActivity = $activity
    PhysicalSize = '1080x1920'
    OverrideSize = if ($nullableFingerprint) { $null } else { '' }
    Rotation = if ($nullableFingerprint) { $null } else { 0 }
} | ConvertTo-Json -Compress
'@

    $script:adbLog = Join-Path $tempRoot 'adb.log'
    $adb = Join-Path $tempRoot 'adb.cmd'
    Set-Content -LiteralPath $adb -Encoding ascii -Value @'
@echo off
echo %*>> "%INPUT_ADB_LOG%"
if defined INPUT_SEQUENCE_LOG echo adb %*>> "%INPUT_SEQUENCE_LOG%"
if not "%INPUT_VISUAL_FAILURE%"=="" exit /b 21
if "%3"=="shell" if "%4"=="screencap" (
  echo %6| findstr /c:"-a.png" >nul
  echo %6| findstr /c:"-b.png" >nul
  if not errorlevel 1 if defined INPUT_VISUAL_B_DELAY_MS if not "%INPUT_VISUAL_B_DELAY_MS%"=="0" powershell.exe -NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds %INPUT_VISUAL_B_DELAY_MS%"
  exit /b 0
)
if "%3"=="pull" (
  echo %4| findstr /c:"-a.png" >nul
  if not errorlevel 1 (
    copy /y "%INPUT_VISUAL_A%" "%~5" >nul
    exit /b %errorlevel%
  )
  echo %4| findstr /c:"-b.png" >nul
  if not errorlevel 1 (
    copy /y "%INPUT_VISUAL_B%" "%~5" >nul
    exit /b %errorlevel%
  )
  exit /b 25
)
if "%3"=="shell" if "%4"=="input" if "%INPUT_ADB_FAIL%"=="1" exit /b 17
exit /b 0
'@
    Set-TestEnvironment -Name 'INPUT_ADB_LOG' -Value $script:adbLog
    Set-TestEnvironment -Name 'INPUT_ADB_FAIL' -Value '0'
    Set-TestEnvironment -Name 'INPUT_FOREGROUND_ACTIVITY' -Value 'Main'
    Set-TestEnvironment -Name 'INPUT_NULLABLE_FINGERPRINT' -Value '0'
    Set-TestEnvironment -Name 'INPUT_RESOLVER_DELAY_MS' -Value '0'
    Set-TestEnvironment -Name 'INPUT_SECOND_RESOLVER_DELAY_MS' -Value '0'
    Set-TestEnvironment -Name 'INPUT_SECOND_FOREGROUND_ACTIVITY' -Value ''
    Set-TestEnvironment -Name 'INPUT_SCREENSHOT_MUTATION' -Value 'none'
    $script:resolverLog = Join-Path $tempRoot 'resolver.log'
    Set-TestEnvironment -Name 'INPUT_RESOLVER_LOG' -Value $script:resolverLog
    $script:sequenceLog = Join-Path $tempRoot 'sequence.log'
    Set-TestEnvironment -Name 'INPUT_SEQUENCE_LOG' -Value $script:sequenceLog

    $script:screenshot = Join-Path $tempRoot 'offline.png'
    New-SyntheticFrame -Path $script:screenshot
    $script:screenshotBytes = [IO.File]::ReadAllBytes($script:screenshot)
    $script:hash = (Get-FileHash -LiteralPath $script:screenshot -Algorithm SHA256).Hash
    Set-TestEnvironment -Name 'INPUT_SCREENSHOT_PATH' -Value $script:screenshot
    $script:visualA = Join-Path $tempRoot 'live-a-source.png'
    $script:visualB = Join-Path $tempRoot 'live-b-source.png'
    New-SyntheticFrame -Path $script:visualA
    New-SyntheticFrame -Path $script:visualB
    Set-TestEnvironment -Name 'INPUT_VISUAL_A' -Value $script:visualA
    Set-TestEnvironment -Name 'INPUT_VISUAL_B' -Value $script:visualB
    Set-TestEnvironment -Name 'INPUT_VISUAL_B_DELAY_MS' -Value '0'
    Set-TestEnvironment -Name 'INPUT_VISUAL_FAILURE' -Value ''

    Invoke-TestCase -Name 'stale evidence is rejected without ADB' -Body {
        $evidence = New-Evidence -Name 'stale' -CapturedAt ([DateTimeOffset]::UtcNow.AddMinutes(-10))
        Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence age is .+ Capture a fresh screenshot\.$' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'future evidence is rejected without ADB' -Body {
        $evidence = New-Evidence -Name 'future' -CapturedAt ([DateTimeOffset]::UtcNow.AddMinutes(10))
        Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence age is .+ Capture a fresh screenshot\.$' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'preexisting screenshot hash mismatch is rejected before resolution' -Body {
        $evidence = New-Evidence -Name 'preexisting-hash-mismatch'
        try {
            [IO.File]::WriteAllBytes($script:screenshot, [byte[]](5, 6, 7, 8))
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: screenshot hash does not match its evidence sidecar\.$' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
            }
        } finally {
            [IO.File]::WriteAllBytes($script:screenshot, $script:screenshotBytes)
        }
    }

    Invoke-TestCase -Name 'evidence expiring during resolution is rejected before receipt and ADB' -Body {
        $evidence = New-Evidence -Name 'expires-during-resolution' -CapturedAt ([DateTimeOffset]::UtcNow.AddSeconds(-3.5))
        try {
            Set-TestEnvironment -Name 'INPUT_RESOLVER_DELAY_MS' -Value '2000'
            Assert-RejectedAfterResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence age is .+ Capture a fresh screenshot\.$' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -MaxEvidenceAgeSeconds 5
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_RESOLVER_DELAY_MS' -Value '0'
        }
    }

    Invoke-TestCase -Name 'screenshot changes during resolution are rejected before receipt and ADB' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Name = 'hash'; Pattern = '^Input refused: screenshot hash does not match its evidence sidecar\.$' },
            [pscustomobject]@{ Name = 'delete'; Pattern = '^Input refused: screenshot is missing:' }
        )) {
            [IO.File]::WriteAllBytes($script:screenshot, $script:screenshotBytes)
            $evidence = New-Evidence -Name "screenshot-$($case.Name)-during-resolution"
            try {
                Set-TestEnvironment -Name 'INPUT_SCREENSHOT_MUTATION' -Value $case.Name
                Assert-RejectedAfterResolution -EvidencePath $evidence -MessagePattern $case.Pattern -Body {
                    & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
                }
            } finally {
                Set-TestEnvironment -Name 'INPUT_SCREENSHOT_MUTATION' -Value 'none'
                [IO.File]::WriteAllBytes($script:screenshot, $script:screenshotBytes)
            }
        }
    }

    Invoke-TestCase -Name 'missing tap coordinates are rejected before evidence access' -Body {
        $missingEvidence = Join-Path $tempRoot 'does-not-exist.json'
        Assert-RejectedBeforeResolution -EvidencePath $missingEvidence -MessagePattern '^Tap requires -X and -Y\.$' -Body {
            & $helper -Action Tap -EvidenceJson $missingEvidence
        }
    }

    Invoke-TestCase -Name 'missing swipe coordinates are rejected before target resolution' -Body {
        foreach ($missingName in @('X', 'Y', 'X2', 'Y2')) {
            $evidence = New-Evidence -Name "swipe-missing-$missingName"
            $parameters = @{
                Action = 'Swipe'
                EvidenceJson = $evidence
                X = 10
                Y = 20
                X2 = 30
                Y2 = 40
            }
            [void]$parameters.Remove($missingName)
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern "^Swipe requires -$missingName\.$" -Body {
                & $helper @parameters
            }
        }
    }

    Invoke-TestCase -Name 'tap and swipe bounds are rejected before target resolution' -Body {
        $cases = @(
            [pscustomobject]@{ Name = 'tap-negative'; Action = 'Tap'; Arguments = @{ X = -1; Y = 0 }; Pattern = '^Tap coordinate is outside the captured image:' },
            [pscustomobject]@{ Name = 'tap-width'; Action = 'Tap'; Arguments = @{ X = 640; Y = 0 }; Pattern = '^Tap coordinate is outside the captured image:' },
            [pscustomobject]@{ Name = 'swipe-negative'; Action = 'Swipe'; Arguments = @{ X = 0; Y = 0; X2 = -1; Y2 = 0 }; Pattern = '^Swipe coordinates must be non-negative\.$' },
            [pscustomobject]@{ Name = 'swipe-height'; Action = 'Swipe'; Arguments = @{ X = 0; Y = 0; X2 = 1; Y2 = 360 }; Pattern = '^Swipe coordinate is outside the captured image:' }
        )
        foreach ($case in $cases) {
            $evidence = New-Evidence -Name $case.Name
            $parameters = @{
                Action = $case.Action
                EvidenceJson = $evidence
            }
            foreach ($entry in $case.Arguments.GetEnumerator()) {
                $parameters[$entry.Key] = $entry.Value
            }
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern $case.Pattern -Body {
                & $helper @parameters
            }
        }
    }

    Invoke-TestCase -Name 'Stable must be boolean true before target resolution' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Name = 'boolean-false'; Value = $false },
            [pscustomobject]@{ Name = 'string-false'; Value = 'false' }
        )) {
            $evidence = New-Evidence -Name "stable-$($case.Name)"
            Set-EvidenceProperty -Path $evidence -Name 'Stable' -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused:' -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'evidence schema version must be integer one' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Name = 'wrong-value'; Value = 2 },
            [pscustomobject]@{ Name = 'string-value'; Value = '1' }
        )) {
            $evidence = New-Evidence -Name "schema-$($case.Name)"
            Set-EvidenceProperty -Path $evidence -Name 'SchemaVersion' -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence SchemaVersion must be integer 1\.$' -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }

        $floatingEvidence = New-Evidence -Name 'schema-floating-value'
        $floatingText = Get-Content -LiteralPath $floatingEvidence -Raw
        $floatingText = $floatingText -replace '"SchemaVersion"\s*:\s*1', '"SchemaVersion": 1.0'
        [IO.File]::WriteAllText($floatingEvidence, $floatingText, [Text.Encoding]::ASCII)
        Assert-RejectedBeforeResolution -EvidencePath $floatingEvidence -MessagePattern '^Input refused: evidence SchemaVersion must be integer 1\.$' -Body {
            & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $floatingEvidence
        }
    }

    Invoke-TestCase -Name 'evidence root and Fingerprint must be JSON objects' -Body {
        $rootArray = Join-Path $tempRoot 'root-array.json'
        [IO.File]::WriteAllText($rootArray, '[]', [Text.Encoding]::ASCII)
        Assert-RejectedBeforeResolution -EvidencePath $rootArray -MessagePattern '^Input refused: evidence root must be a JSON object\.$' -Body {
            & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $rootArray
        }

        $evidence = New-Evidence -Name 'fingerprint-string'
        Set-EvidenceProperty -Path $evidence -Name 'Fingerprint' -Value 'not-an-object'
        Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence Fingerprint must be a JSON object\.$' -Body {
            & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'capture time and screenshot path require canonical JSON types' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Field = 'CapturedAtUtc'; Name = 'numeric-time'; Value = 123; Pattern = '^Input refused: evidence CapturedAtUtc must be a non-empty JSON string\.$' },
            [pscustomobject]@{ Field = 'ScreenshotPath'; Name = 'array-path'; Value = @('offline.png'); Pattern = '^Input refused: evidence ScreenshotPath must be a non-empty JSON string\.$' }
        )) {
            $evidence = New-Evidence -Name $case.Name
            Set-EvidenceProperty -Path $evidence -Name $case.Field -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern $case.Pattern -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'evidence dimensions must be positive integers' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Field = 'Width'; Name = 'zero-width'; Value = 0 },
            [pscustomobject]@{ Field = 'Height'; Name = 'negative-height'; Value = -1 },
            [pscustomobject]@{ Field = 'Width'; Name = 'string-width'; Value = '1080' },
            [pscustomobject]@{ Field = 'Height'; Name = 'floating-height'; Value = 1920.5 }
        )) {
            $evidence = New-Evidence -Name $case.Name
            Set-EvidenceProperty -Path $evidence -Name $case.Field -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern "^Input refused: evidence $($case.Field) must be a positive integer\.$" -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'evidence SHA256 must be exactly 64 hexadecimal characters' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Name = 'short'; Value = 'abcd' },
            [pscustomobject]@{ Name = 'non-hex'; Value = ('g' * 64) },
            [pscustomobject]@{ Name = 'non-string'; Value = 1234 }
        )) {
            $evidence = New-Evidence -Name "sha-$($case.Name)"
            Set-EvidenceProperty -Path $evidence -Name 'Sha256' -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern '^Input refused: evidence Sha256 must be a 64-character hexadecimal string\.$' -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'fingerprint fields require their canonical JSON types' -Body {
        $invalidFields = @(
            [pscustomobject]@{ Field = 'VmIndex'; Value = '0' },
            [pscustomobject]@{ Field = 'VmIndex'; Value = 2147483648 },
            [pscustomobject]@{ Field = 'BootId'; Value = 123 },
            [pscustomobject]@{ Field = 'AndroidId'; Value = $true },
            [pscustomobject]@{ Field = 'GamePid'; Value = 1234 },
            [pscustomobject]@{ Field = 'ForegroundPackage'; Value = @('com.huanmeng.zhanjian2') },
            [pscustomobject]@{ Field = 'ForegroundActivity'; Value = 7 },
            [pscustomobject]@{ Field = 'PhysicalSize'; Value = 10801920 },
            [pscustomobject]@{ Field = 'OverrideSize'; Value = $false },
            [pscustomobject]@{ Field = 'Rotation'; Value = '0' }
        )
        foreach ($case in $invalidFields) {
            $evidence = New-Evidence -Name "fingerprint-type-$($case.Field)"
            Set-FingerprintProperty -Path $evidence -Name $case.Field -Value $case.Value
            Assert-RejectedBeforeResolution -EvidencePath $evidence -MessagePattern "^Input refused: evidence Fingerprint\.$($case.Field) has an invalid type\.$" -Body {
                & $helper -Action Tap -X 0 -Y 0 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'nullable fingerprint fields match capture output contract' -Body {
        $evidence = New-Evidence -Name 'nullable-fingerprint'
        foreach ($fieldName in @('VmIndex', 'BootId', 'OverrideSize', 'Rotation')) {
            Set-FingerprintProperty -Path $evidence -Name $fieldName -Value $null
        }
        $before = Get-InputCallCount
        try {
            Set-TestEnvironment -Name 'INPUT_NULLABLE_FINGERPRINT' -Value '1'
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence | Out-Null
        } finally {
            Set-TestEnvironment -Name 'INPUT_NULLABLE_FINGERPRINT' -Value '0'
        }
        $after = Get-InputCallCount
        if ($after -ne ($before + 1)) {
            throw "Expected one ADB call for nullable capture fields; got $($after - $before)."
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'sent') { throw "Expected receipt.Status=sent; got $($receipt.Status)." }
    }

    Invoke-TestCase -Name 'ForegroundActivity mismatch is rejected without ADB' -Body {
        $evidence = New-Evidence -Name 'activity-mismatch' -ForegroundActivity 'OtherActivity'
        Assert-NoAdbCall -MessagePattern '^Input refused because the target changed: ForegroundActivity expected=' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'case-only ForegroundActivity mismatch is rejected without ADB' -Body {
        $evidence = New-Evidence -Name 'activity-case-mismatch' -ForegroundActivity 'main'
        Assert-NoAdbCall -MessagePattern '^Input refused because the target changed: ForegroundActivity expected=' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'invalid GamePackage is rejected before target resolution' -Body {
        $evidence = New-Evidence -Name 'invalid-package'
        $resolverCallsBefore = Get-ResolverCallCount
        $adbCallsBefore = Get-AdbCallCount
        Assert-ParameterValidationFailure -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -GamePackage 'com.example;bad'
        }
        $resolverCallsAfter = Get-ResolverCallCount
        $adbCallsAfter = Get-AdbCallCount
        if ($resolverCallsAfter -ne $resolverCallsBefore) {
            throw 'Invalid input GamePackage reached the target resolver.'
        }
        if ($adbCallsAfter -ne $adbCallsBefore) {
            throw 'Invalid input GamePackage reached ADB.'
        }
    }

    Invoke-TestCase -Name 'visual evidence TTL is fixed to one through thirty seconds' -Body {
        foreach ($invalidAge in @(0, 31)) {
            $evidence = New-Evidence -Name "invalid-ttl-$invalidAge"
            $resolverCallsBefore = Get-ResolverCallCount
            $adbCallsBefore = Get-AdbCallCount
            Assert-ParameterValidationFailure -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -MaxEvidenceAgeSeconds $invalidAge
            }
            if ((Get-ResolverCallCount) -ne $resolverCallsBefore -or (Get-AdbCallCount) -ne $adbCallsBefore) {
                throw "Invalid TTL $invalidAge reached resolver or ADB."
            }
        }

        $staleByDefault = New-Evidence -Name 'stale-by-ten-second-default' -CapturedAt ([DateTimeOffset]::UtcNow.AddSeconds(-11))
        Assert-RejectedBeforeResolution -EvidencePath $staleByDefault -MessagePattern '^Input refused: evidence age is .+ Capture a fresh screenshot\.$' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $staleByDefault
        }
    }

    Invoke-TestCase -Name 'KeyEvent requires an explicit visual guard point' -Body {
        foreach ($missingName in @('GuardX', 'GuardY')) {
            $missingEvidence = Join-Path $tempRoot "missing-key-guard-$missingName.json"
            $parameters = @{
                Action = 'KeyEvent'
                KeyCode = 66
                GuardX = 320
                GuardY = 180
                EvidenceJson = $missingEvidence
            }
            [void]$parameters.Remove($missingName)
            Assert-NoResolverOrAdbCall -MessagePattern "^KeyEvent requires -GuardX and -GuardY\.$" -Body {
                & $helper @parameters
            }
        }
    }

    Invoke-TestCase -Name 'Back and system-navigation keys are rejected without ADB' -Body {
        foreach ($keyCode in @(4, 280)) {
            $evidence = New-Evidence -Name "blocked-key-$keyCode"
            Assert-NoAdbCall -MessagePattern "^KeyEvent key code $keyCode is not allowed\. Allowed key codes: 66, 67, 112, 279\.$" -Body {
                & $helper -Action KeyEvent -KeyCode $keyCode -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'matching live A/B frames pass before one ordered input' -Body {
        $evidence = New-Evidence -Name 'visual-integration-match'
        $sequenceBefore = if (Test-Path -LiteralPath $script:sequenceLog) { @(Get-Content -LiteralPath $script:sequenceLog).Count } else { 0 }
        $inputBefore = Get-InputCallCount
        & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence | Out-Null
        if ((Get-InputCallCount) -ne ($inputBefore + 1)) {
            throw 'Expected exactly one input after the visual check.'
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'sent') { throw "Expected receipt.Status=sent; got $($receipt.Status)." }
        if ($receipt.VisualGuard.Decision -ne 'matched' -or -not $receipt.VisualGuard.Passed) {
            throw 'Receipt did not record a passing visual comparison.'
        }
        if ($receipt.VisualGuard.FrameGapMs -lt 120 -or $receipt.VisualGuard.FrameGapMs -gt 2000) {
            throw "Expected an approximately 180 ms A/B gap; got $($receipt.VisualGuard.FrameGapMs) ms."
        }
        foreach ($metric in @('DynamicFraction', 'GlobalMeanRgbDelta', 'GlobalMeanGradientDelta', 'GlobalChangedFraction', 'LocalMeanRgbDelta', 'LocalMeanGradientDelta', 'LocalChangedFraction')) {
            if ($null -eq $receipt.VisualGuard.PSObject.Properties[$metric]) {
                throw "Receipt is missing visual metric $metric."
            }
        }

        $newSequence = @(Get-Content -LiteralPath $script:sequenceLog | Select-Object -Skip $sequenceBefore)
        $sequenceText = $newSequence -join "`n"
        if ($sequenceText -notmatch '(?s)^resolve-\d+\nadb -s offline shell screencap -p .+-a\.png\nadb -s offline shell screencap -p .+-b\.png\nadb -s offline pull .+-a\.png .+\nadb -s offline pull .+-b\.png .+\nresolve-\d+\nadb -s offline shell input tap 100 200') {
            throw "Unexpected visual/input sequence:`n$sequenceText"
        }
        $remoteCaptures = @($newSequence | Where-Object { $_ -match 'shell screencap -p (.+\.png)$' } | ForEach-Object { $Matches[1] })
        if ($remoteCaptures.Count -ne 2 -or $remoteCaptures[0] -eq $remoteCaptures[1]) {
            throw 'Expected two unique remote A/B PNG paths.'
        }
        $leakedFrames = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'codex-visual-*.png' -File -ErrorAction SilentlyContinue)
        if ($leakedFrames.Count -ne 0) { throw 'Visual check leaked local temporary PNG files.' }
    }

    Invoke-TestCase -Name 'changed live tap target consumes evidence without input' -Body {
        $evidence = New-Evidence -Name 'visual-integration-local-change'
        $changedA = Join-Path $tempRoot 'integration-changed-a.png'
        $changedB = Join-Path $tempRoot 'integration-changed-b.png'
        New-SyntheticFrame -Path $changedA -Variant 'tap-changed'
        Copy-Item -LiteralPath $changedA -Destination $changedB
        try {
            Set-TestEnvironment -Name 'INPUT_VISUAL_A' -Value $changedA
            Set-TestEnvironment -Name 'INPUT_VISUAL_B' -Value $changedB
            Assert-NoInputCall -MessagePattern '^Input refused: visual guard rejected the live screen: local-changed\.' -Body {
                & $helper -Action Tap -X 320 -Y 180 -EvidenceJson $evidence
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_VISUAL_A' -Value $script:visualA
            Set-TestEnvironment -Name 'INPUT_VISUAL_B' -Value $script:visualB
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'visual-rejected' -or $receipt.VisualGuard.Decision -ne 'local-changed') {
            throw "Expected visual-rejected/local-changed receipt; got $($receipt.Status)/$($receipt.VisualGuard.Decision)."
        }
        Assert-NoInputCall -MessagePattern '^Input refused: this screenshot evidence was already consumed\.' -Body {
            & $helper -Action Tap -X 320 -Y 180 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'screencap failure consumes evidence before visual checking' -Body {
        $evidence = New-Evidence -Name 'visual-screencap-failure'
        try {
            Set-TestEnvironment -Name 'INPUT_VISUAL_FAILURE' -Value 'screencap-a'
            Assert-NoInputCall -MessagePattern '^Visual freshness check failed or may be incomplete: live frame A screencap\.' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_VISUAL_FAILURE' -Value ''
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'visual-check-error-or-unknown') {
            throw "Expected consumed visual-check-error-or-unknown receipt; got $($receipt.Status)."
        }
    }

    Invoke-TestCase -Name 'second resolver fingerprint change blocks input after A/B capture' -Body {
        $evidence = New-Evidence -Name 'visual-second-fingerprint-change'
        $resolverBefore = Get-ResolverCallCount
        try {
            Set-TestEnvironment -Name 'INPUT_SECOND_FOREGROUND_ACTIVITY' -Value 'OtherActivity'
            Assert-NoInputCall -MessagePattern '^Input refused because the target changed during visual checking:' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_SECOND_FOREGROUND_ACTIVITY' -Value ''
        }
        if ((Get-ResolverCallCount) -ne ($resolverBefore + 2)) {
            throw 'Expected resolver calls immediately before and after live A/B capture.'
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'target-changed-before-input') {
            throw "Expected target-changed-before-input receipt; got $($receipt.Status)."
        }
    }

    Invoke-TestCase -Name 'TTL expiration during visual checking blocks input and consumes evidence' -Body {
        $evidence = New-Evidence -Name 'visual-ttl-expired' -CapturedAt ([DateTimeOffset]::UtcNow.AddMilliseconds(-200))
        try {
            Set-TestEnvironment -Name 'INPUT_SECOND_RESOLVER_DELAY_MS' -Value '1200'
            Assert-NoInputCall -MessagePattern '^Input refused: evidence expired during visual checking\.' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -MaxEvidenceAgeSeconds 1
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_SECOND_RESOLVER_DELAY_MS' -Value '0'
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'evidence-expired-before-input') {
            throw "Expected evidence-expired-before-input receipt; got $($receipt.Status)."
        }
    }

    Invoke-TestCase -Name 'live frame B cannot age more than three seconds before input' -Body {
        $evidence = New-Evidence -Name 'visual-live-frame-expired'
        try {
            Set-TestEnvironment -Name 'INPUT_SECOND_RESOLVER_DELAY_MS' -Value '3300'
            Assert-NoInputCall -MessagePattern '^Input refused: live screen evidence expired before input\.' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -MaxEvidenceAgeSeconds 30
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_SECOND_RESOLVER_DELAY_MS' -Value '0'
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'live-frame-expired-before-input' -or $receipt.LiveFrameAgeSeconds -le 3) {
            throw "Expected an expired live-frame receipt; got $($receipt.Status), age=$($receipt.LiveFrameAgeSeconds)."
        }
    }

    Invoke-TestCase -Name 'live frame age includes a slow successful B screencap' -Body {
        $evidence = New-Evidence -Name 'visual-slow-live-b'
        try {
            Set-TestEnvironment -Name 'INPUT_VISUAL_B_DELAY_MS' -Value '3300'
            Assert-NoInputCall -MessagePattern '^Input refused: live screen evidence expired before input\.' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence -MaxEvidenceAgeSeconds 30
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_VISUAL_B_DELAY_MS' -Value '0'
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'live-frame-expired-before-input' -or $receipt.LiveFrameAgeSeconds -le 3) {
            throw "Expected slow B screencap to expire the live frame; got $($receipt.Status), age=$($receipt.LiveFrameAgeSeconds)."
        }
    }

    Invoke-TestCase -Name 'allowlisted key codes are each sent exactly once' -Body {
        foreach ($keyCode in @(66, 67, 112, 279)) {
            $evidence = New-Evidence -Name "allowed-key-$keyCode"
            $before = Get-InputCallCount
            & $helper -Action KeyEvent -KeyCode $keyCode -GuardX 320 -GuardY 180 -EvidenceJson $evidence | Out-Null
            $after = Get-InputCallCount
            if ($after -ne ($before + 1)) { throw "Expected one input call for key $keyCode; got $($after - $before)." }
            $lastCall = @(Get-InputCalls)[-1]
            if ($lastCall -ne "-s offline shell input keyevent $keyCode") {
                throw "Unexpected ADB call '$lastCall'."
            }
            $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
            if ($receipt.Status -ne 'sent') { throw "Expected receipt.Status=sent; got $($receipt.Status)." }
            Assert-NoAdbCall -MessagePattern '^Input refused: this screenshot evidence was already consumed\.' -Body {
                & $helper -Action KeyEvent -KeyCode $keyCode -GuardX 320 -GuardY 180 -EvidenceJson $evidence
            }
        }
    }

    Invoke-TestCase -Name 'tap sends once and evidence is single-use' -Body {
        $evidence = New-Evidence -Name 'tap'
        $before = Get-InputCallCount
        & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence | Out-Null
        $after = Get-InputCallCount
        if ($after -ne ($before + 1)) { throw "Expected one input call; got $($after - $before)." }
        $lastCall = @(Get-InputCalls)[-1]
        if ($lastCall -ne '-s offline shell input tap 100 200') {
            throw "Unexpected ADB call '$lastCall'."
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'sent') { throw "Expected receipt.Status=sent; got $($receipt.Status)." }
        Assert-NoAdbCall -MessagePattern '^Input refused: this screenshot evidence was already consumed\.' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'swipe sends ordered coordinates and duration exactly once' -Body {
        $evidence = New-Evidence -Name 'swipe-success'
        $before = Get-InputCallCount
        & $helper -Action Swipe -X 10 -Y 20 -X2 300 -Y2 300 -DurationMs 725 -EvidenceJson $evidence | Out-Null
        $after = Get-InputCallCount
        if ($after -ne ($before + 1)) { throw "Expected one swipe input call; got $($after - $before)." }
        $lastCall = @(Get-InputCalls)[-1]
        if ($lastCall -ne '-s offline shell input swipe 10 20 300 300 725') {
            throw "Unexpected swipe ADB call '$lastCall'."
        }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'sent') { throw "Expected receipt.Status=sent; got $($receipt.Status)." }
        Assert-NoAdbCall -MessagePattern '^Input refused: this screenshot evidence was already consumed\.' -Body {
            & $helper -Action Swipe -X 10 -Y 20 -X2 300 -Y2 300 -DurationMs 725 -EvidenceJson $evidence
        }
    }

    Invoke-TestCase -Name 'ADB failure consumes evidence with an unknown-error receipt' -Body {
        $evidence = New-Evidence -Name 'adb-failure'
        $before = Get-InputCallCount
        try {
            Set-TestEnvironment -Name 'INPUT_ADB_FAIL' -Value '1'
            Assert-Throws -MessagePattern '^ADB input failed or may have partially executed: Tap\.' -Body {
                & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
            }
        } finally {
            Set-TestEnvironment -Name 'INPUT_ADB_FAIL' -Value '0'
        }
        $after = Get-InputCallCount
        if ($after -ne ($before + 1)) { throw "Expected one failing input call; got $($after - $before)." }
        $receipt = Get-Content -LiteralPath "$evidence.consumed.json" -Raw | ConvertFrom-Json
        if ($receipt.Status -ne 'adb-error-or-unknown') {
            throw "Expected receipt.Status=adb-error-or-unknown; got $($receipt.Status)."
        }
        Assert-NoAdbCall -MessagePattern '^Input refused: this screenshot evidence was already consumed\.' -Body {
            & $helper -Action Tap -X 100 -Y 200 -EvidenceJson $evidence
        }
    }

    if ($failures.Count -gt 0) {
        throw "Offline input helper tests failed ($($failures.Count)):`n - $($failures -join "`n - ")"
    }
    Write-Output 'Offline input helper tests passed.'
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetFileName($resolvedTemp) -match '^[0-9a-fA-F]{32}$' -and
        (Split-Path -Parent $resolvedTemp) -eq $tempParent) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
