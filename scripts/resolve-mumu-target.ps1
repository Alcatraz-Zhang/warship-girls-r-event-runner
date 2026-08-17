[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Find', 'Info')]
    [string]$Action = 'Find',

    [ValidateRange(0, 2147483647)]
    [Nullable[int]]$VmIndex = $null,

    [ValidatePattern('^(?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z][A-Za-z0-9_]*$')]
    [string]$GamePackage = 'com.huanmeng.zhanjian2',

    [switch]$AllowGameStopped,

    [switch]$RequireForeground,

    [ValidateRange(1, 60000)]
    [int]$TcpTimeoutMs = 100,

    [ValidateRange(100, 120000)]
    [int]$ProcessTimeoutMs = 10000
)

$ErrorActionPreference = 'Stop'
$boundedRunner = Join-Path $PSScriptRoot 'invoke-bounded-process.ps1'
if (-not (Test-Path -LiteralPath $boundedRunner -PathType Leaf)) {
    throw "Bounded process runner not found: $boundedRunner"
}
. $boundedRunner

function Invoke-AdbProcess {
    param([string[]]$Arguments)
    $result = Invoke-BoundedProcess -FilePath $script:AdbPath -ArgumentList $Arguments -TimeoutMs $ProcessTimeoutMs
    if ($result.TimedOut) {
        $commandText = ($Arguments -join ' ')
        throw "ADB command timed out after $ProcessTimeoutMs ms. Command: $commandText"
    }
    return $result
}

function Add-ResolvedPath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path,
        [ValidateSet('Leaf', 'Container')][string]$PathType
    )
    if (-not $Path) { return }
    if (Test-Path -LiteralPath $Path -PathType $PathType) {
        $resolved = (Resolve-Path -LiteralPath $Path).Path
        if (-not $List.Contains($resolved)) { [void]$List.Add($resolved) }
    }
}

function Get-InstallRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:MUMU_HOME)) {
        if (-not (Test-Path -LiteralPath $env:MUMU_HOME -PathType Container)) {
            throw "MUMU_HOME does not name an existing directory: $($env:MUMU_HOME)"
        }
        Add-ResolvedPath -List $roots -Path $env:MUMU_HOME -PathType Container
        return $roots.ToArray()
    }

    $known = @(
        'D:\Program Files\Netease\MuMu Player 12',
        'C:\Program Files\Netease\MuMu Player 12'
    )
    if ($env:ProgramFiles) {
        $known += (Join-Path $env:ProgramFiles 'Netease\MuMu Player 12')
    }
    foreach ($path in $known) {
        Add-ResolvedPath -List $roots -Path $path -PathType Container
    }

    try {
        foreach ($process in @(Get-Process -Name MuMuNxMain -ErrorAction SilentlyContinue)) {
            if ($process.Path) {
                $root = Split-Path -Parent (Split-Path -Parent $process.Path)
                Add-ResolvedPath -List $roots -Path $root -PathType Container
            }
        }
    } catch { }

    return $roots.ToArray()
}

function Resolve-CliPath {
    param([string[]]$InstallRoots)
    if (-not [string]::IsNullOrWhiteSpace($env:MUMU_CLI_PATH)) {
        if (-not (Test-Path -LiteralPath $env:MUMU_CLI_PATH -PathType Leaf)) {
            throw "MUMU_CLI_PATH does not name an existing file: $($env:MUMU_CLI_PATH)"
        }
        return (Resolve-Path -LiteralPath $env:MUMU_CLI_PATH).Path
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $InstallRoots) {
        Add-ResolvedPath -List $paths -Path (Join-Path $root 'nx_main\mumu-cli.exe') -PathType Leaf
    }
    if ($paths.Count -gt 0) { return $paths[0] }
    return $null
}

function Resolve-AdbPath {
    param([string[]]$InstallRoots)
    if (-not [string]::IsNullOrWhiteSpace($env:MUMU_ADB_PATH)) {
        if (-not (Test-Path -LiteralPath $env:MUMU_ADB_PATH -PathType Leaf)) {
            throw "MUMU_ADB_PATH does not name an existing file: $($env:MUMU_ADB_PATH)"
        }
        return (Resolve-Path -LiteralPath $env:MUMU_ADB_PATH).Path
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $InstallRoots) {
        Add-ResolvedPath -List $paths -Path (Join-Path $root 'shell\adb.exe') -PathType Leaf
    }
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) {
        Add-ResolvedPath -List $paths -Path $command.Source -PathType Leaf
    }
    if ($paths.Count -eq 0) {
        throw 'adb.exe was not found. Set MUMU_ADB_PATH or MUMU_HOME.'
    }
    return $paths[0]
}

function Get-VmRoots {
    param([string[]]$InstallRoots)
    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:MUMU_VM_ROOT)) {
        if (-not (Test-Path -LiteralPath $env:MUMU_VM_ROOT -PathType Container)) {
            throw "MUMU_VM_ROOT does not name an existing directory: $($env:MUMU_VM_ROOT)"
        }
        Add-ResolvedPath -List $roots -Path $env:MUMU_VM_ROOT -PathType Container
        return $roots.ToArray()
    }
    foreach ($installRoot in $InstallRoots) {
        $vmsRoot = Join-Path $installRoot 'vms'
        if (Test-Path -LiteralPath $vmsRoot -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $vmsRoot -Directory -ErrorAction SilentlyContinue)) {
                if (-not $roots.Contains($directory.FullName)) { [void]$roots.Add($directory.FullName) }
            }
        }
    }
    return $roots.ToArray()
}

function Get-RootVmIndex {
    param([string]$Root)
    $name = Split-Path -Leaf $Root
    if ($name -match '-(?<index>\d+)$') { return [int]$Matches.index }
    return $null
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[object]]$List,
        [object]$Port,
        [string]$Source,
        [int]$Priority,
        [Nullable[int]]$CandidateVmIndex = $null
    )
    $parsedPort = 0
    $portText = ([string]$Port) -replace '\s+', ''
    if (-not [int]::TryParse($portText, [ref]$parsedPort)) { return }
    if ($parsedPort -lt 1 -or $parsedPort -gt 65535) { return }
    if ($null -ne $VmIndex -and $null -ne $CandidateVmIndex -and $CandidateVmIndex -ne $VmIndex) { return }

    $existing = @($List | Where-Object { $_.Port -eq $parsedPort }) | Select-Object -First 1
    if ($existing) {
        if ($Priority -lt $existing.Priority) {
            $existing.Priority = $Priority
            $existing.Source = $Source
        }
        if ($null -eq $existing.VmIndex -and $null -ne $CandidateVmIndex) {
            $existing.VmIndex = $CandidateVmIndex
        }
        if (-not $existing.Sources.Contains($Source)) { [void]$existing.Sources.Add($Source) }
        return
    }

    $sources = [System.Collections.Generic.List[string]]::new()
    [void]$sources.Add($Source)
    [void]$List.Add([pscustomobject]@{
        Port     = $parsedPort
        Source   = $Source
        Sources  = $sources
        Priority = $Priority
        VmIndex  = $CandidateVmIndex
    })
}

function Get-ConnectedLoopbackPorts {
    $text = (Invoke-AdbProcess -Arguments @('devices', '-l')).StdOut
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*(?:127\.0\.0\.1|localhost):(?<port>\d+)\s+(?:device|offline|unauthorized)\b') {
            [int]$Matches.port
        }
    }
}

function Test-LocalTcpPort {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait($TcpTimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Invoke-AdbText {
    param([string]$Serial, [string[]]$Arguments)
    $result = Invoke-AdbProcess -Arguments (@('-s', $Serial) + @($Arguments))
    if ($result.ExitCode -ne 0) { return '' }
    return $result.StdOut.Trim()
}

function Get-NormalizedBootId {
    param([string]$Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed)) { return $null }
    if ($parsed -eq [guid]::Empty) { return $null }
    return $parsed.ToString('D')
}

function Get-ForegroundState {
    param([string]$Serial)
    $text = Invoke-AdbText -Serial $Serial -Arguments @('shell', 'dumpsys', 'window', 'windows')
    $match = [regex]::Match($text, '(?:mCurrentFocus|mFocusedApp).*?\s(?<package>[A-Za-z0-9._]+)\/(?<activity>[A-Za-z0-9._$]+)')
    if (-not $match.Success) {
        $text = Invoke-AdbText -Serial $Serial -Arguments @('shell', 'dumpsys', 'activity', 'activities')
        $match = [regex]::Match($text, 'mResumedActivity.*?\s(?<package>[A-Za-z0-9._]+)\/(?<activity>[A-Za-z0-9._$]+)')
    }
    if ($match.Success) {
        return [pscustomobject]@{
            Package  = $match.Groups['package'].Value
            Activity = $match.Groups['activity'].Value
        }
    }
    return [pscustomobject]@{ Package = ''; Activity = '' }
}

function Get-DisplayState {
    param([string]$Serial)
    $sizeText = Invoke-AdbText -Serial $Serial -Arguments @('shell', 'wm', 'size')
    $physical = ''
    $override = ''
    if ($sizeText -match 'Physical size:\s*(?<size>\d+x\d+)') { $physical = $Matches.size }
    if ($sizeText -match 'Override size:\s*(?<size>\d+x\d+)') { $override = $Matches.size }
    $inputText = Invoke-AdbText -Serial $Serial -Arguments @('shell', 'dumpsys', 'input')
    $rotation = $null
    if ($inputText -match 'SurfaceOrientation:\s*(?<rotation>\d+)') { $rotation = [int]$Matches.rotation }
    return [pscustomobject]@{
        PhysicalSize = $physical
        OverrideSize = $override
        Rotation     = $rotation
    }
}

function Test-GameDevice {
    param([object]$Candidate)
    $serial = "127.0.0.1:$($Candidate.Port)"
    if (-not (Test-LocalTcpPort -Port $Candidate.Port)) { return $null }
    [void](Invoke-AdbProcess -Arguments @('connect', $serial))
    if ((Invoke-AdbText -Serial $serial -Arguments @('get-state')) -cne 'device') { return $null }

    $model = Invoke-AdbText -Serial $serial -Arguments @('shell', 'getprop', 'ro.product.model')
    $bootId = Get-NormalizedBootId -Value (Invoke-AdbText -Serial $serial -Arguments @('shell', 'cat', '/proc/sys/kernel/random/boot_id'))
    $androidId = Invoke-AdbText -Serial $serial -Arguments @('shell', 'settings', 'get', 'secure', 'android_id')
    $pidText = Invoke-AdbText -Serial $serial -Arguments @('shell', 'pidof', '-s', $GamePackage)
    $gamePid = ''
    if ($pidText -match '^[1-9]\d*$') {
        $gamePid = $pidText
    } else {
        $processText = Invoke-AdbText -Serial $serial -Arguments @('shell', 'ps', '-A', '-o', 'PID,NAME')
        $matchingPids = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($processText -split "`r?`n")) {
            $processMatch = [regex]::Match($line, '^\s*(?<pid>[1-9]\d*)\s+(?<name>\S+)\s*$')
            if ($processMatch.Success -and $processMatch.Groups['name'].Value -ceq $GamePackage) {
                [void]$matchingPids.Add($processMatch.Groups['pid'].Value)
            }
        }
        if ($matchingPids.Count -eq 1) { $gamePid = $matchingPids[0] }
    }
    if (-not $gamePid -and (-not $AllowGameStopped -or $RequireForeground)) {
        return $null
    }

    $foreground = Get-ForegroundState -Serial $serial
    $isForeground = ($foreground.Package -ceq $GamePackage)
    if ($RequireForeground -and -not $isForeground) { return $null }
    $display = Get-DisplayState -Serial $serial

    return [pscustomobject]@{
        Serial             = $serial
        Port               = $Candidate.Port
        VmIndex            = $Candidate.VmIndex
        Source             = $Candidate.Source
        Sources            = $Candidate.Sources.ToArray()
        Priority           = $Candidate.Priority
        Model              = $model
        BootId             = $bootId
        AndroidId          = $androidId
        Game               = $GamePackage
        GamePid            = $gamePid
        ForegroundPackage  = $foreground.Package
        ForegroundActivity = $foreground.Activity
        IsForeground       = $isForeground
        PhysicalSize       = $display.PhysicalSize
        OverrideSize       = $display.OverrideSize
        Rotation           = $display.Rotation
    }
}

$installRoots = @(Get-InstallRoots)
$script:CliPath = Resolve-CliPath -InstallRoots $installRoots
$script:AdbPath = Resolve-AdbPath -InstallRoots $installRoots
$vmRoots = @(Get-VmRoots -InstallRoots $installRoots)
$candidates = [System.Collections.Generic.List[object]]::new()
$runningVmIndexes = [System.Collections.Generic.List[int]]::new()
$reportedVmIndexes = [System.Collections.Generic.List[int]]::new()
$strictRunningVmPorts = [System.Collections.Generic.List[object]]::new()
$cliInfoSucceeded = $false
$authoritativeVmPort = $null

# Live MuMu RPC state is the preferred canonical source.
if ($script:CliPath) {
    try {
        $cliResult = Invoke-BoundedProcess -FilePath $script:CliPath -ArgumentList @('info', '--vmindex', 'all') -TimeoutMs $ProcessTimeoutMs
        if ($cliResult.TimedOut) {
            throw [TimeoutException]::new("MuMu CLI timed out after $ProcessTimeoutMs ms.")
        }
        if ($cliResult.ExitCode -ne 0) {
            throw "MuMu CLI exited with code $($cliResult.ExitCode)."
        }
        $runtime = ($cliResult.StdOut | ConvertFrom-Json)
        if ($null -eq $runtime) { throw 'MuMu CLI returned no runtime state.' }
        foreach ($property in $runtime.PSObject.Properties) {
            $instance = $property.Value
            $indexText = [string]$instance.index
            $index = 0
            if (-not [int]::TryParse($indexText, [ref]$index) -or $index -lt 0) { continue }
            if (-not $reportedVmIndexes.Contains($index)) {
                [void]$reportedVmIndexes.Add($index)
            }
            $startedProperty = $instance.PSObject.Properties['is_process_started']
            $isStrictlyStarted = (
                $null -ne $startedProperty -and
                $startedProperty.Value -is [bool] -and
                $startedProperty.Value
            )
            if ($isStrictlyStarted -and -not $runningVmIndexes.Contains($index)) {
                [void]$runningVmIndexes.Add($index)
            }
            if ($isStrictlyStarted) {
                $cliPort = 0
                $cliPortText = ([string]$instance.adb_port) -replace '\s+', ''
                if ([int]::TryParse($cliPortText, [ref]$cliPort) -and $cliPort -ge 1 -and $cliPort -le 65535) {
                    [void]$strictRunningVmPorts.Add([pscustomobject]@{
                        VmIndex = $index
                        Port    = $cliPort
                    })
                    Add-Candidate -List $candidates -Port $cliPort -Source 'mumu-cli' -Priority 10 -CandidateVmIndex $index
                }
            }
        }
        $cliInfoSucceeded = $true
    } catch {
        if ($_.Exception -is [TimeoutException]) { throw }
        Write-Verbose "MuMu CLI info failed: $($_.Exception.Message)"
    }
}

# Keep the original live index-to-port relationships separate from the
# port-deduplicated probe list. Conflicting live identities are unsafe in both
# scoped and unscoped discovery and must be rejected before ADB or TCP probing.
if ($cliInfoSucceeded) {
    $portHasMultipleIndexes = @($strictRunningVmPorts |
        Group-Object Port |
        Where-Object { @($_.Group.VmIndex | Select-Object -Unique).Count -gt 1 }).Count -gt 0
    $indexHasMultiplePorts = @($strictRunningVmPorts |
        Group-Object VmIndex |
        Where-Object { @($_.Group.Port | Select-Object -Unique).Count -gt 1 }).Count -gt 0
    if ($portHasMultipleIndexes -or $indexHasMultiplePorts) {
        throw 'Ambiguous MuMu CLI running VmIndex-to-port mapping.'
    }
}

# A requested VM index is safe only when this invocation obtained one unique,
# strictly running index-to-port mapping from live MuMu RPC state. Directory
# names and stale logs cannot establish that identity after ports are reused.
if ($null -ne $VmIndex) {
    if (-not $cliInfoSucceeded -or
        -not $reportedVmIndexes.Contains($VmIndex) -or
        -not $runningVmIndexes.Contains($VmIndex)) {
        throw "No MuMu target matched VmIndex $VmIndex"
    }
    $mappedPorts = @($strictRunningVmPorts | Where-Object {
        $_.VmIndex -eq $VmIndex
    } | Select-Object -ExpandProperty Port -Unique)
    if ($mappedPorts.Count -ne 1) {
        throw "No MuMu target matched VmIndex $VmIndex"
    }
    $authoritativeVmPort = [int]$mappedPorts[0]
}

# VM configuration and current-boot logs are secondary sources.
foreach ($root in $vmRoots) {
    $rootIndex = Get-RootVmIndex -Root $root
    if ($null -ne $VmIndex) { continue }
    if ($cliInfoSucceeded -and $null -ne $rootIndex -and $reportedVmIndexes.Contains($rootIndex)) { continue }

    $configPath = Join-Path $root 'configs\vm_config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            Add-Candidate -List $candidates -Port $config.vm.nat.port_forward.adb.host_port -Source 'vm-config' -Priority 20
        } catch {
            Write-Verbose "VM config ignored: $configPath"
        }
    }

    $shellLog = Join-Path $root 'logs\shell.log'
    if (Test-Path -LiteralPath $shellLog -PathType Leaf) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $shellLog -Tail 5000 -ErrorAction SilentlyContinue)) {
                if ($line -match 'get available port\s+(?<port>\d+)\s+for base=0') {
                    Add-Candidate -List $candidates -Port $Matches.port -Source 'shell-log' -Priority 30
                }
            }
        } catch { }
    }

    $vboxLog = Join-Path $root 'logs\VBox.log'
    if (Test-Path -LiteralPath $vboxLog -PathType Leaf) {
        try {
            $pendingPort = $null
            foreach ($line in @(Get-Content -LiteralPath $vboxLog -Tail 5000 -ErrorAction SilentlyContinue)) {
                if ($line -match 'HostPort\s+<integer>.*?0x(?<hex>[0-9A-Fa-f]+)') {
                    $pendingPort = [Convert]::ToInt32($Matches.hex, 16)
                    continue
                }
                if ($line -match 'HostPort\s+<integer>.*?\((?<decimal>[\d\s]+)\)') {
                    $pendingPort = (($Matches.decimal) -replace '\s+', '')
                    continue
                }
                if ($line -match 'Name\s+<string>\s+=\s+"ADB_PORT[^"]*"') {
                    if ($pendingPort) {
                        Add-Candidate -List $candidates -Port $pendingPort -Source 'vbox-log' -Priority 40
                    }
                    $pendingPort = $null
                }
            }
        } catch { }
    }
}

foreach ($port in @(Get-ConnectedLoopbackPorts)) {
    Add-Candidate -List $candidates -Port $port -Source 'adb-connected' -Priority 50
}

$valid = [System.Collections.Generic.List[object]]::new()
$orderedCandidates = @($candidates | Sort-Object Priority, Port)
if ($null -ne $authoritativeVmPort) {
    foreach ($candidate in @($orderedCandidates | Where-Object { $_.Port -eq $authoritativeVmPort })) {
        $result = Test-GameDevice -Candidate $candidate
        if ($result) { [void]$valid.Add($result) }
    }
    if ($valid.Count -gt 0) {
        foreach ($candidate in @($orderedCandidates | Where-Object { $_.Port -ne $authoritativeVmPort })) {
            $result = Test-GameDevice -Candidate $candidate
            if ($result) { [void]$valid.Add($result) }
        }
    }
} else {
    foreach ($candidate in $orderedCandidates) {
        $result = Test-GameDevice -Candidate $candidate
        if ($result) { [void]$valid.Add($result) }
    }
}

# Only scan when every structured source failed and live MuMu RPC supplied no
# port. If RPC supplied a live port, scanning its aliases cannot fix a missing
# game process or foreground mismatch and would only delay the diagnosis.
$hasLiveCliPort = @($candidates | Where-Object { $_.Source -eq 'mumu-cli' }).Count -gt 0
if ($valid.Count -eq 0 -and -not $hasLiveCliPort) {
    $fallback = [System.Collections.Generic.List[object]]::new()
    Add-Candidate -List $fallback -Port 5555 -Source 'bounded-scan' -Priority 90
    foreach ($port in 16384..16400) {
        Add-Candidate -List $fallback -Port $port -Source 'bounded-scan' -Priority 90
    }
    foreach ($candidate in @($fallback | Sort-Object Port)) {
        $result = Test-GameDevice -Candidate $candidate
        if ($result) { [void]$valid.Add($result) }
        if (-not @($candidates | Where-Object Port -eq $candidate.Port)) {
            [void]$candidates.Add($candidate)
        }
    }
}

if ($valid.Count -eq 0) {
    if ($null -ne $VmIndex) {
        throw "No MuMu target matched VmIndex $VmIndex"
    }
    $ports = (@($candidates | Sort-Object Priority, Port | Select-Object -First 30).Port -join ', ')
    $mode = if ($RequireForeground) { 'foreground game' } elseif ($AllowGameStopped) { 'MuMu VM' } else { 'running game' }
    throw "No matching $mode was found. Probed loopback ports: $ports"
}

# Deduplicate serial aliases that identify the same Android boot.
$groups = @{}
foreach ($item in $valid) {
    $key = if ($item.BootId) {
        "boot:$($item.BootId)"
    } else {
        "serial:$($item.Serial)"
    }
    if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [System.Collections.Generic.List[object]]::new()
    }
    [void]$groups[$key].Add($item)
}

$eligibleGroups = @($groups.GetEnumerator())
if ($null -ne $VmIndex) {
    $eligibleGroups = @($eligibleGroups | Where-Object {
        @($_.Value | Where-Object { $null -ne $_.VmIndex -and $_.VmIndex -eq $VmIndex }).Count -gt 0
    })
    if ($eligibleGroups.Count -eq 0) {
        throw "No MuMu target matched VmIndex $VmIndex"
    }
}

if ($eligibleGroups.Count -ne 1) {
    $summary = @($eligibleGroups | ForEach-Object {
        $best = @($_.Value | Sort-Object Priority, Port)[0]
        "vm=$($best.VmIndex) serials=$((@($_.Value.Serial) -join '/')) android=$($best.AndroidId)"
    }) -join '; '
    throw "Multiple distinct MuMu targets matched. Specify -VmIndex. Candidates: $summary"
}

$members = @($eligibleGroups[0].Value | Sort-Object Priority, Port)
$selectableMembers = if ($null -ne $VmIndex) {
    @($members | Where-Object { $null -ne $_.VmIndex -and $_.VmIndex -eq $VmIndex })
} else {
    $members
}
$found = $selectableMembers[0]
$aliases = @($members.Serial | Select-Object -Unique)

$info = [ordered]@{
    Serial             = $found.Serial
    Port               = $found.Port
    VmIndex            = $found.VmIndex
    Source             = $found.Source
    Aliases            = $aliases
    Model              = $found.Model
    BootId             = $found.BootId
    AndroidId          = $found.AndroidId
    Game               = $found.Game
    GamePid            = $found.GamePid
    ForegroundPackage  = $found.ForegroundPackage
    ForegroundActivity = $found.ForegroundActivity
    IsForeground       = $found.IsForeground
    PhysicalSize       = $found.PhysicalSize
    OverrideSize       = $found.OverrideSize
    Rotation           = $found.Rotation
    AdbPath            = $script:AdbPath
    CliPath            = $script:CliPath
    RunningVmIndexes   = $runningVmIndexes.ToArray()
}

if ($Action -eq 'Find') {
    $found.Serial
} else {
    [pscustomobject]$info | ConvertTo-Json -Depth 5 -Compress
}
