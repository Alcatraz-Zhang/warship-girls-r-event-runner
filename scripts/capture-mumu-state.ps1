[CmdletBinding(PositionalBinding = $false)]
param(
    [Nullable[int]]$VmIndex = $null,

    [ValidatePattern('^(?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z][A-Za-z0-9_]*$')]
    [string]$GamePackage = 'com.huanmeng.zhanjian2',

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [switch]$AllowGameStopped,

    [switch]$RequireForeground,

    [ValidateRange(100, 120000)]
    [int]$ProcessTimeoutMs = 10000
)

$ErrorActionPreference = 'Stop'
$boundedRunner = Join-Path $PSScriptRoot 'invoke-bounded-process.ps1'
if (-not (Test-Path -LiteralPath $boundedRunner -PathType Leaf)) {
    throw "Bounded process runner not found: $boundedRunner"
}
. $boundedRunner
$resolver = Join-Path $PSScriptRoot 'resolve-mumu-target.ps1'
if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
    throw "Resolver not found: $resolver"
}

function Get-TargetInfo {
    $parameters = @{
        Action      = 'Info'
        GamePackage = $GamePackage
        ProcessTimeoutMs = $ProcessTimeoutMs
    }
    if ($null -ne $VmIndex) { $parameters.VmIndex = $VmIndex }
    if ($AllowGameStopped) { $parameters.AllowGameStopped = $true }
    if ($RequireForeground) { $parameters.RequireForeground = $true }
    $json = & $resolver @parameters
    if (-not $json) { throw 'Target resolution failed.' }
    return ($json | ConvertFrom-Json)
}

function Get-PngDimensions {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 24
        if ($stream.Read($header, 0, 24) -ne 24) { throw 'PNG is too short.' }
        $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        for ($i = 0; $i -lt $signature.Count; $i++) {
            if ($header[$i] -ne $signature[$i]) { throw 'Screenshot is not a PNG.' }
        }
        $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($header, 16))
        $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($header, 20))
        return [pscustomobject]@{ Width = $width; Height = $height }
    } finally {
        $stream.Dispose()
    }
}

function Get-Fingerprint {
    param([object]$Info)
    return [ordered]@{
        VmIndex            = $Info.VmIndex
        BootId             = $Info.BootId
        AndroidId          = $Info.AndroidId
        GamePid            = $Info.GamePid
        ForegroundPackage  = $Info.ForegroundPackage
        ForegroundActivity = $Info.ForegroundActivity
        PhysicalSize       = $Info.PhysicalSize
        OverrideSize       = $Info.OverrideSize
        Rotation           = $Info.Rotation
    }
}

function Compare-Fingerprint {
    param([object]$Before, [object]$After)
    $keys = @('VmIndex', 'BootId', 'AndroidId', 'GamePid', 'ForegroundPackage', 'ForegroundActivity', 'PhysicalSize', 'OverrideSize', 'Rotation')
    foreach ($key in $keys) {
        if ([string]$Before.$key -cne [string]$After.$key) { return $false }
    }
    return $true
}

$captureStartedUtc = [DateTime]::UtcNow
$capturedAtUtc = $captureStartedUtc.ToString('o')
$before = Get-TargetInfo
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
[void][System.IO.Directory]::CreateDirectory($outputRoot)

$timestamp = $captureStartedUtc.ToString('yyyyMMddTHHmmssfffZ')
$vmLabel = if ($null -eq $before.VmIndex) { 'auto' } else { [string]$before.VmIndex }
$bootLabel = if ($before.BootId) { ([string]$before.BootId -replace '-', '').Substring(0, 8) } else { 'nobootid' }
$pidLabel = if ($before.GamePid) { [string]$before.GamePid } else { 'stopped' }
$nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$baseName = "mumu-$timestamp-vm$vmLabel-$bootLabel-p$pidLabel-$nonce"
$pngPath = Join-Path $outputRoot "$baseName.png"
$jsonPath = Join-Path $outputRoot "$baseName.json"
$unstablePath = Join-Path $outputRoot "$baseName.unstable.png"
$remotePath = "/sdcard/Download/$baseName.png"

$adb = [string]$before.AdbPath
$serial = [string]$before.Serial
$primaryError = $null
$cleanupError = $null
try {
    $screencapResult = Invoke-BoundedProcess -FilePath $adb -ArgumentList @('-s', $serial, 'shell', 'screencap', '-p', $remotePath) -TimeoutMs $ProcessTimeoutMs
    if ($screencapResult.TimedOut) {
        throw "Remote screencap timed out after $ProcessTimeoutMs ms."
    }
    if ($screencapResult.ExitCode -ne 0) { throw 'Remote screencap failed.' }

    $pullResult = Invoke-BoundedProcess -FilePath $adb -ArgumentList @('-s', $serial, 'pull', $remotePath, $pngPath) -TimeoutMs $ProcessTimeoutMs
    if ($pullResult.TimedOut) {
        throw "Screenshot pull timed out after $ProcessTimeoutMs ms."
    }
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pngPath -PathType Leaf)) {
        throw 'Screenshot pull failed.'
    }
} catch {
    $primaryError = $_
}

try {
    $cleanupResult = Invoke-BoundedProcess -FilePath $adb -ArgumentList @('-s', $serial, 'shell', 'rm', '-f', $remotePath) -TimeoutMs $ProcessTimeoutMs
    if ($cleanupResult.TimedOut) {
        throw "Remote screenshot cleanup timed out after $ProcessTimeoutMs ms."
    }
    if ($cleanupResult.ExitCode -ne 0) { throw 'Remote screenshot cleanup failed.' }
} catch {
    $cleanupError = $_
}

if ($primaryError -or $cleanupError) {
    if (Test-Path -LiteralPath $pngPath -PathType Leaf) {
        Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue
    }
}
if ($primaryError) {
    $PSCmdlet.ThrowTerminatingError($primaryError)
}
if ($cleanupError) {
    $PSCmdlet.ThrowTerminatingError($cleanupError)
}

$dimensions = Get-PngDimensions -Path $pngPath
$hash = (Get-FileHash -LiteralPath $pngPath -Algorithm SHA256).Hash
$after = Get-TargetInfo
$stable = Compare-Fingerprint -Before $before -After $after

if (-not $stable) {
    Move-Item -LiteralPath $pngPath -Destination $unstablePath
    $pngPath = $unstablePath
}

$evidence = [ordered]@{
    SchemaVersion  = 1
    CapturedAtUtc  = $capturedAtUtc
    Stable         = $stable
    ScreenshotPath = $pngPath
    Width          = $dimensions.Width
    Height         = $dimensions.Height
    Sha256         = $hash
    Fingerprint    = Get-Fingerprint -Info $before
    TargetBefore   = $before
    TargetAfter    = $after
}

[pscustomobject]$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8

if (-not $stable) {
    throw "Target changed during capture. Unstable evidence: $jsonPath"
}

[pscustomobject]@{
    ScreenshotPath = $pngPath
    EvidenceJson   = $jsonPath
    Width          = $dimensions.Width
    Height         = $dimensions.Height
    Sha256         = $hash
    Serial         = $before.Serial
    VmIndex        = $before.VmIndex
    GamePid        = $before.GamePid
} | ConvertTo-Json -Compress
