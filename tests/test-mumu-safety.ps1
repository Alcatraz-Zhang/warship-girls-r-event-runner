[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$listeners = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$environmentNames = @(
    'MUMU_HOME',
    'MUMU_VM_ROOT',
    'MUMU_ADB_PATH',
    'MUMU_CLI_PATH',
    'ProgramFiles',
    'PATH',
    'SAFETY_CLI_JSON',
    'SAFETY_CLI_LOG',
    'SAFETY_CLI_DELAY_MS',
    'SAFETY_ADB_LOG',
    'SAFETY_ADB_DELAY_MS',
    'SAFETY_SERIAL1',
    'SAFETY_SERIAL2',
    'SAFETY_MODEL1',
    'SAFETY_MODEL2',
    'SAFETY_BOOT1',
    'SAFETY_BOOT2',
    'SAFETY_ANDROID1',
    'SAFETY_ANDROID2',
    'SAFETY_PID1',
    'SAFETY_PID2',
    'SAFETY_PS1',
    'SAFETY_PS2',
    'SAFETY_FOREGROUND1',
    'SAFETY_FOREGROUND2',
    'SAFETY_LIST_SERIAL2',
    'SAFETY_PNG_SOURCE',
    'SAFETY_INPUT_LOG',
    'CAPTURE_COUNTER_FILE',
    'CAPTURE_ACTIVITY_BEFORE',
    'CAPTURE_ACTIVITY_AFTER',
    'CAPTURE_DELAY_MS',
    'CAPTURE_PNG_SOURCE',
    'CAPTURE_SCREENCAP_DELAY_MS',
    'CAPTURE_PULL_DELAY_MS',
    'CAPTURE_RM_DELAY_MS',
    'CAPTURE_RM_EXIT_CODE',
    'CAPTURE_ADB_LOG'
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

function Write-CliState {
    param([object]$State)
    $json = $State | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($script:cliJson, $json, [Text.Encoding]::ASCII)
}

function Get-CliCallCount {
    if (-not (Test-Path -LiteralPath $script:cliLog -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $script:cliLog).Count
}

function Get-AdbCallCount {
    if (-not (Test-Path -LiteralPath $script:adbLog -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $script:adbLog).Count
}

function Clear-PendingConnections {
    param([Net.Sockets.TcpListener]$Listener)
    while ($Listener.Pending()) {
        $client = $Listener.AcceptTcpClient()
        $client.Dispose()
    }
}

function Set-DeviceState {
    param(
        [string]$Serial1,
        [string]$Serial2 = '',
        [string]$Boot1 = '',
        [string]$Boot2 = '',
        [string]$Android1 = 'android-a',
        [string]$Android2 = 'android-b',
        [string]$Model1 = 'FakeModel',
        [string]$Model2 = 'FakeModel',
        [string]$Pid1 = '1234',
        [string]$Pid2 = '1234',
        [string]$Ps1 = '1234 com.huanmeng.zhanjian2',
        [string]$Ps2 = '1234 com.huanmeng.zhanjian2',
        [bool]$ListSerial2 = $true
    )
    Set-TestEnvironment -Name 'SAFETY_SERIAL1' -Value $Serial1
    Set-TestEnvironment -Name 'SAFETY_SERIAL2' -Value $Serial2
    Set-TestEnvironment -Name 'SAFETY_MODEL1' -Value $Model1
    Set-TestEnvironment -Name 'SAFETY_MODEL2' -Value $Model2
    Set-TestEnvironment -Name 'SAFETY_BOOT1' -Value $Boot1
    Set-TestEnvironment -Name 'SAFETY_BOOT2' -Value $Boot2
    Set-TestEnvironment -Name 'SAFETY_ANDROID1' -Value $Android1
    Set-TestEnvironment -Name 'SAFETY_ANDROID2' -Value $Android2
    Set-TestEnvironment -Name 'SAFETY_PID1' -Value $Pid1
    Set-TestEnvironment -Name 'SAFETY_PID2' -Value $Pid2
    Set-TestEnvironment -Name 'SAFETY_PS1' -Value $Ps1
    Set-TestEnvironment -Name 'SAFETY_PS2' -Value $Ps2
    Set-TestEnvironment -Name 'SAFETY_FOREGROUND1' -Value 'com.huanmeng.zhanjian2'
    Set-TestEnvironment -Name 'SAFETY_FOREGROUND2' -Value 'com.huanmeng.zhanjian2'
    Set-TestEnvironment -Name 'SAFETY_LIST_SERIAL2' -Value $(if ($ListSerial2) { '1' } else { '0' })
}

function Write-VmConfig {
    param([string]$VmRoot, [int]$Port)
    $configDirectory = Join-Path $VmRoot 'configs'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $config = [ordered]@{
        vm = [ordered]@{
            nat = [ordered]@{
                port_forward = [ordered]@{ adb = [ordered]@{ host_port = $Port } }
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Join-Path $configDirectory 'vm_config.json'), $config, [Text.Encoding]::ASCII)
}

function Invoke-ResolverInfo {
    param([Nullable[int]]$VmIndex = $null)
    $parameters = @{ Action = 'Info'; TcpTimeoutMs = 200 }
    if ($null -ne $VmIndex) { $parameters.VmIndex = $VmIndex }
    $json = & $script:resolver @parameters
    if (-not $json) { throw 'Resolver returned no JSON.' }
    return ($json | ConvertFrom-Json)
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    if ([IO.Path]::GetFileName($tempRoot) -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Temporary root is not GUID-named.'
    }

    $listener1 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener1.Start(64)
    [void]$listeners.Add($listener1)
    $listener2 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener2.Start(64)
    [void]$listeners.Add($listener2)
    $port1 = ([Net.IPEndPoint]$listener1.LocalEndpoint).Port
    $port2 = ([Net.IPEndPoint]$listener2.LocalEndpoint).Port
    $serial1 = "127.0.0.1:$port1"
    $serial2 = "127.0.0.1:$port2"

    $fakeHome = Join-Path $tempRoot 'mumu-home'
    $fakeVmRoot = Join-Path $tempRoot 'vm-root'
    New-Item -ItemType Directory -Path $fakeHome, $fakeVmRoot -Force | Out-Null
    $script:cliJson = Join-Path $tempRoot 'cli.json'
    $script:cliLog = Join-Path $tempRoot 'cli.log'
    $script:adbLog = Join-Path $tempRoot 'adb.log'
    Write-CliState -State @{}

    $fakeCli = Join-Path $tempRoot 'mumu-cli.cmd'
    [IO.File]::WriteAllText($fakeCli, @'
@echo off
if "%SAFETY_CLI_JSON%"=="" exit /b 90
echo %*>> "%SAFETY_CLI_LOG%"
if not "%SAFETY_CLI_DELAY_MS%"=="" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command Start-Sleep -Milliseconds %SAFETY_CLI_DELAY_MS%
type "%SAFETY_CLI_JSON%"
exit /b 0
'@, [Text.Encoding]::ASCII)

    $fakeAdb = Join-Path $tempRoot 'adb.cmd'
    [IO.File]::WriteAllText($fakeAdb, @'
@echo off
setlocal EnableExtensions
if not "%SAFETY_ADB_LOG%"=="" echo %*>> "%SAFETY_ADB_LOG%"
if not "%SAFETY_ADB_DELAY_MS%"=="" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command Start-Sleep -Milliseconds %SAFETY_ADB_DELAY_MS%
if "%1"=="devices" goto devices
if "%1"=="connect" goto connect
if not "%1"=="-s" exit /b 91
if "%2"=="%SAFETY_SERIAL1%" goto serial1
if "%2"=="%SAFETY_SERIAL2%" goto serial2
exit /b 92

:devices
echo List of devices attached
if not "%SAFETY_SERIAL1%"=="" echo %SAFETY_SERIAL1% device model:Fake transport_id:1
if "%SAFETY_LIST_SERIAL2%"=="1" if not "%SAFETY_SERIAL2%"=="" echo %SAFETY_SERIAL2% device model:Fake transport_id:2
exit /b 0

:connect
if "%2"=="%SAFETY_SERIAL1%" goto connected1
if "%2"=="%SAFETY_SERIAL2%" goto connected2
exit /b 93
:connected1
if "%SAFETY_SERIAL1%"=="" exit /b 93
echo connected to %2
exit /b 0
:connected2
if "%SAFETY_SERIAL2%"=="" exit /b 93
echo connected to %2
exit /b 0

:serial1
set "FAKE_MODEL=%SAFETY_MODEL1%"
set "FAKE_BOOT=%SAFETY_BOOT1%"
set "FAKE_ANDROID=%SAFETY_ANDROID1%"
set "FAKE_PID=%SAFETY_PID1%"
set "FAKE_PS=%SAFETY_PS1%"
set "FAKE_FOREGROUND=%SAFETY_FOREGROUND1%"
goto respond
:serial2
set "FAKE_MODEL=%SAFETY_MODEL2%"
set "FAKE_BOOT=%SAFETY_BOOT2%"
set "FAKE_ANDROID=%SAFETY_ANDROID2%"
set "FAKE_PID=%SAFETY_PID2%"
set "FAKE_PS=%SAFETY_PS2%"
set "FAKE_FOREGROUND=%SAFETY_FOREGROUND2%"
goto respond

:respond
shift
shift
if "%1"=="get-state" goto get_state
if "%1"=="pull" goto pull
if not "%1"=="shell" exit /b 94
if "%2"=="getprop" goto model
if "%2"=="cat" goto boot
if "%2"=="settings" goto android
if "%2"=="pidof" goto pid
if "%2"=="ps" goto ps
if "%2"=="wm" if "%3"=="size" goto wm_size
if "%2"=="dumpsys" if "%3"=="window" goto window
if "%2"=="dumpsys" if "%3"=="activity" goto activity
if "%2"=="dumpsys" if "%3"=="input" goto input
if "%2"=="screencap" goto screencap
if "%2"=="rm" exit /b 0
if "%2"=="input" goto send_input
exit /b 95
:get_state
echo device
exit /b 0
:model
echo(%FAKE_MODEL%
exit /b 0
:boot
echo(%FAKE_BOOT%
exit /b 0
:android
echo(%FAKE_ANDROID%
exit /b 0
:pid
echo(%FAKE_PID%
exit /b 0
:ps
echo PID NAME
if defined FAKE_PS echo %FAKE_PS%
exit /b 0
:wm_size
echo Physical size: 1080x1920
exit /b 0
:window
echo mCurrentFocus=Window{0 u0 %FAKE_FOREGROUND%/.MainActivity}
exit /b 0
:activity
echo mResumedActivity: ActivityRecord{0 u0 %FAKE_FOREGROUND%/.MainActivity t1}
exit /b 0
:input
echo SurfaceOrientation: 0
exit /b 0
:screencap
exit /b 0
:pull
if "%SAFETY_PNG_SOURCE%"=="" exit /b 96
copy /y "%SAFETY_PNG_SOURCE%" "%3" >nul
exit /b %ERRORLEVEL%
:send_input
if "%SAFETY_INPUT_LOG%"=="" exit /b 97
echo %* >> "%SAFETY_INPUT_LOG%"
exit /b 0
'@, [Text.Encoding]::ASCII)

    Set-TestEnvironment -Name 'MUMU_HOME' -Value $fakeHome
    Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
    Set-TestEnvironment -Name 'MUMU_ADB_PATH' -Value $fakeAdb
    Set-TestEnvironment -Name 'MUMU_CLI_PATH' -Value $fakeCli
    Set-TestEnvironment -Name 'SAFETY_CLI_JSON' -Value $script:cliJson
    Set-TestEnvironment -Name 'SAFETY_CLI_LOG' -Value $script:cliLog
    Set-TestEnvironment -Name 'SAFETY_ADB_LOG' -Value $script:adbLog
    Set-TestEnvironment -Name 'SAFETY_CLI_DELAY_MS' -Value ''
    Set-TestEnvironment -Name 'SAFETY_ADB_DELAY_MS' -Value ''
    $script:resolver = Join-Path $repo 'scripts/resolve-mumu-target.ps1'
    $script:runner = Join-Path $repo 'scripts/invoke-bounded-process.ps1'

    $runnerFixture = Join-Path $tempRoot 'runner fixture'
    New-Item -ItemType Directory -Path $runnerFixture -Force | Out-Null
    $runnerCmd = Join-Path $runnerFixture 'echo args.cmd'
    [IO.File]::WriteAllText($runnerCmd, @'
@echo off
echo stdout:%~1
echo stderr:%~2 1>&2
if "%~3"=="nonzero" exit /b 23
exit /b 0
'@, [Text.Encoding]::ASCII)
    $runnerArgsScript = Join-Path $runnerFixture 'echo-args.ps1'
    [IO.File]::WriteAllText($runnerArgsScript, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Values)
$Values | ConvertTo-Json -Compress
'@, [Text.Encoding]::ASCII)
    $runnerChildScript = Join-Path $tempRoot 'runner-child.ps1'
    [IO.File]::WriteAllText($runnerChildScript, @'
param([string]$PidFile)
[IO.File]::WriteAllText($PidFile, [string]$PID, [Text.Encoding]::ASCII)
Start-Sleep -Seconds 30
'@, [Text.Encoding]::ASCII)
    $runnerParentScript = Join-Path $tempRoot 'runner-parent.ps1'
    [IO.File]::WriteAllText($runnerParentScript, @'
param([string]$ChildScript, [string]$PidFile)
$powershell = Join-Path $PSHOME 'powershell.exe'
Start-Sleep -Milliseconds 250
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $powershell
$startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$ChildScript`" `"$PidFile`""
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($startInfo)
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path -LiteralPath $PidFile -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 20
}
Start-Sleep -Seconds 30
'@, [Text.Encoding]::ASCII)
    $runnerDaemonChildScript = Join-Path $tempRoot 'runner-daemon-child.ps1'
    [IO.File]::WriteAllText($runnerDaemonChildScript, @'
param([string]$MarkerPath)
Start-Sleep -Milliseconds 800
[IO.File]::WriteAllText($MarkerPath, 'completed', [Text.Encoding]::ASCII)
'@, [Text.Encoding]::ASCII)
    $runnerDaemonParentScript = Join-Path $tempRoot 'runner-daemon-parent.ps1'
    [IO.File]::WriteAllText($runnerDaemonParentScript, @'
param([string]$ChildScript, [string]$MarkerPath)
$powershell = Join-Path $PSHOME 'powershell.exe'
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $powershell
$startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$ChildScript`" `"$MarkerPath`""
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
[void][Diagnostics.Process]::Start($startInfo)
'@, [Text.Encoding]::ASCII)

    Invoke-TestCase -Name 'bounded runner supports cmd stdout stderr and zero exit' -Body {
        if (-not (Test-Path -LiteralPath $script:runner -PathType Leaf)) {
            throw "Bounded runner not found: $($script:runner)"
        }
        . $script:runner
        $result = Invoke-BoundedProcess -FilePath $runnerCmd -ArgumentList @('hello world', 'problem text') -TimeoutMs 5000
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            throw "Expected successful bounded process; timedOut=$($result.TimedOut) exit=$($result.ExitCode)."
        }
        if ($result.StdOut.Trim() -cne 'stdout:hello world') {
            throw "Unexpected stdout '$($result.StdOut)'."
        }
        if ($result.StdErr.Trim() -cne 'stderr:problem text') {
            throw "Unexpected stderr '$($result.StdErr)'."
        }
    }

    Invoke-TestCase -Name 'bounded runner returns nonzero exit without discarding both streams' -Body {
        . $script:runner
        $result = Invoke-BoundedProcess -FilePath $runnerCmd -ArgumentList @('out', 'err', 'nonzero') -TimeoutMs 5000
        if ($result.TimedOut -or $result.ExitCode -ne 23) {
            throw "Expected exit 23 without timeout; timedOut=$($result.TimedOut) exit=$($result.ExitCode)."
        }
        if ($result.StdOut.Trim() -cne 'stdout:out' -or $result.StdErr.Trim() -cne 'stderr:err') {
            throw "Nonzero result lost output: stdout='$($result.StdOut)' stderr='$($result.StdErr)'."
        }
    }

    Invoke-TestCase -Name 'bounded runner preserves a successful command persistent child' -Body {
        . $script:runner
        $powershellExe = Join-Path $PSHOME 'powershell.exe'
        $markerPath = Join-Path $tempRoot 'runner-daemon-completed.txt'
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
        $result = Invoke-BoundedProcess -FilePath $powershellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerDaemonParentScript, $runnerDaemonChildScript, $markerPath) -TimeoutMs 5000
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            throw "Expected successful daemon parent; timedOut=$($result.TimedOut) exit=$($result.ExitCode)."
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(4)
        while (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw 'Successful command child was killed when the bounded runner released its job.'
        }
    }

    Invoke-TestCase -Name 'bounded runner preserves executable argument-array boundaries' -Body {
        . $script:runner
        $powershellExe = Join-Path $PSHOME 'powershell.exe'
        $expected = @('plain', 'with space', 'quote"inside', '', 'tail\')
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerArgsScript) + $expected
        $result = Invoke-BoundedProcess -FilePath $powershellExe -ArgumentList $arguments -TimeoutMs 5000
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            throw "Argument probe failed; timedOut=$($result.TimedOut) exit=$($result.ExitCode) stderr='$($result.StdErr)'."
        }
        $actual = $result.StdOut | ConvertFrom-Json
        if ($actual.Count -ne $expected.Count) {
            throw "Expected $($expected.Count) arguments; got $($actual.Count): '$($result.StdOut)'."
        }
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ([string]$actual[$i] -cne [string]$expected[$i]) {
                throw "Argument $i changed from '$($expected[$i])' to '$($actual[$i])'."
            }
        }
    }

    Invoke-TestCase -Name 'bounded runner kills a timed-out process tree within a bound' -Body {
        . $script:runner
        $powershellExe = Join-Path $PSHOME 'powershell.exe'
        $childPidFile = Join-Path $tempRoot 'runner-child.pid'
        if (Test-Path -LiteralPath $childPidFile) { Remove-Item -LiteralPath $childPidFile -Force }
        $started = [DateTime]::UtcNow
        $result = Invoke-BoundedProcess -FilePath $powershellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerParentScript, $runnerChildScript, $childPidFile) -TimeoutMs 1500
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if (-not $result.TimedOut -or $null -ne $result.ExitCode) {
            throw "Expected timeout with null exit; timedOut=$($result.TimedOut) exit=$($result.ExitCode)."
        }
        if ($elapsedMs -gt 5000) { throw "Timed-out runner returned too slowly: $elapsedMs ms." }
        if (-not (Test-Path -LiteralPath $childPidFile -PathType Leaf)) {
            throw "Child PID file was not created before timeout. stderr='$($result.StdErr)'"
        }
        $childPid = [int](Get-Content -LiteralPath $childPidFile -Raw)
        Start-Sleep -Milliseconds 1000
        if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
            throw "Timed-out child process $childPid survived tree termination."
        }
    }

    Invoke-TestCase -Name 'bounded runner timeout parameter rejects values outside safety bounds' -Body {
        . $script:runner
        foreach ($invalidTimeout in @(99, 120001)) {
            Assert-ParameterValidationFailure -Body {
                Invoke-BoundedProcess -FilePath $runnerCmd -ArgumentList @('a', 'b') -TimeoutMs $invalidTimeout
            }
        }
    }

    $explicitHome = Join-Path $tempRoot 'explicit-home'
    $explicitHomeVm = Join-Path $explicitHome 'vms\MuMuPlayer-12.0-7'
    $explicitVmRoot = Join-Path $tempRoot 'MuMuPlayer-12.0-7'
    $ambientProgramFiles = Join-Path $tempRoot 'ambient-program-files'
    $ambientInstall = Join-Path $ambientProgramFiles 'Netease\MuMu Player 12'
    $ambientVmRoot = Join-Path $ambientInstall 'vms\MuMuPlayer-12.0-99'
    Write-VmConfig -VmRoot $explicitHomeVm -Port $port1
    Write-VmConfig -VmRoot $explicitVmRoot -Port $port1
    Write-VmConfig -VmRoot $ambientVmRoot -Port $port2

    Invoke-TestCase -Name 'explicit MUMU_HOME excludes ambient install roots' -Body {
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 -Boot1 '11111111-2222-4333-8444-555555555551' -Boot2 '11111111-2222-4333-8444-555555555552' -ListSerial2 $false
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $explicitHome
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $null
            Set-TestEnvironment -Name 'ProgramFiles' -Value $ambientProgramFiles
            $info = Invoke-ResolverInfo
            if ($info.Serial -ne $serial1) {
                throw "Expected explicit-home serial $serial1; got $($info.Serial)."
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $fakeHome
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
            Set-TestEnvironment -Name 'ProgramFiles' -Value $savedEnvironment['ProgramFiles']
        }
    }

    Invoke-TestCase -Name 'explicit MUMU_VM_ROOT excludes install-root VM directories' -Body {
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 -Boot1 '11111111-2222-4333-8444-555555555551' -Boot2 '11111111-2222-4333-8444-555555555552' -ListSerial2 $false
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $null
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $explicitVmRoot
            Set-TestEnvironment -Name 'ProgramFiles' -Value $ambientProgramFiles
            $info = Invoke-ResolverInfo
            if ($info.Serial -ne $serial1) {
                throw "Expected explicit VM-root serial $serial1; got $($info.Serial)."
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $fakeHome
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
            Set-TestEnvironment -Name 'ProgramFiles' -Value $savedEnvironment['ProgramFiles']
        }
    }

    Invoke-TestCase -Name 'invalid explicit MUMU_HOME fails closed' -Body {
        $missingPath = Join-Path $tempRoot 'missing-home'
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $missingPath
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
            Assert-Throws -MessagePattern ([regex]::Escape("MUMU_HOME does not name an existing directory: $missingPath")) -Body {
                Invoke-ResolverInfo
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_HOME' -Value $fakeHome
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
        }
    }

    Invoke-TestCase -Name 'invalid explicit MUMU_VM_ROOT fails closed' -Body {
        $missingPath = Join-Path $tempRoot 'missing-vm-root'
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $missingPath
            Assert-Throws -MessagePattern ([regex]::Escape("MUMU_VM_ROOT does not name an existing directory: $missingPath")) -Body {
                Invoke-ResolverInfo
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
        }
    }

    Invoke-TestCase -Name 'invalid explicit MUMU_CLI_PATH fails closed' -Body {
        $missingPath = Join-Path $tempRoot 'missing-cli.cmd'
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1
            Set-TestEnvironment -Name 'MUMU_CLI_PATH' -Value $missingPath
            Assert-Throws -MessagePattern ([regex]::Escape("MUMU_CLI_PATH does not name an existing file: $missingPath")) -Body {
                Invoke-ResolverInfo
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_CLI_PATH' -Value $fakeCli
        }
    }

    Invoke-TestCase -Name 'invalid explicit MUMU_ADB_PATH fails closed' -Body {
        $missingPath = Join-Path $tempRoot 'missing-adb.cmd'
        try {
            Write-CliState -State @{}
            Set-DeviceState -Serial1 $serial1
            Set-TestEnvironment -Name 'MUMU_ADB_PATH' -Value $missingPath
            Set-TestEnvironment -Name 'PATH' -Value $tempRoot
            Assert-Throws -MessagePattern ([regex]::Escape("MUMU_ADB_PATH does not name an existing file: $missingPath")) -Body {
                Invoke-ResolverInfo
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_ADB_PATH' -Value $fakeAdb
            Set-TestEnvironment -Name 'PATH' -Value $savedEnvironment['PATH']
        }
    }

    Invoke-TestCase -Name 'unknown VmIndex never falls back to an unindexed candidate' -Body {
        Write-CliState -State @{}
        Set-DeviceState -Serial1 $serial1
        Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 999$' -Body {
            Invoke-ResolverInfo -VmIndex 999
        }
    }

    Invoke-TestCase -Name 'missing CLI index cannot masquerade as VmIndex zero' -Body {
        Write-CliState -State ([ordered]@{
            malformed = [ordered]@{ is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 0$' -Body {
            Invoke-ResolverInfo -VmIndex 0
        }
    }

    Invoke-TestCase -Name 'only strict CLI boolean true contributes an indexed candidate' -Body {
        foreach ($case in @(
            [pscustomobject]@{ Name = 'boolean-false'; IncludeStarted = $true; Started = $false },
            [pscustomobject]@{ Name = 'string-false'; IncludeStarted = $true; Started = 'false' },
            [pscustomobject]@{ Name = 'missing'; IncludeStarted = $false; Started = $null }
        )) {
            $instance = [ordered]@{ index = 12; adb_port = $port1 }
            if ($case.IncludeStarted) {
                $instance.is_process_started = $case.Started
            }
            Write-CliState -State ([ordered]@{ vm12 = $instance })
            Set-DeviceState -Serial1 $serial1 -ListSerial2 $false
            Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 12$' -Body {
                Invoke-ResolverInfo -VmIndex 12
            }
        }
    }

    Invoke-TestCase -Name 'stopped CLI VmIndex rejects a reused stale config port before probing' -Body {
        $staleVmRoot = Join-Path $tempRoot 'stopped-root\MuMuPlayer-12.0-12'
        Write-VmConfig -VmRoot $staleVmRoot -Port $port1
        try {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $staleVmRoot
            foreach ($stoppedValue in @($false, 'false')) {
                Write-CliState -State ([ordered]@{
                    vm12 = [ordered]@{ index = 12; is_process_started = $stoppedValue; adb_port = $port1 }
                })
                Set-DeviceState -Serial1 $serial1 -Boot1 '11111111-2222-4333-8444-555555555551' -ListSerial2 $false
                Clear-PendingConnections -Listener $listener1
                Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 12$' -Body {
                    Invoke-ResolverInfo -VmIndex 12
                }
                if ($listener1.Pending()) {
                    throw "Stopped CLI value '$stoppedValue' allowed the stale config port to reach the TCP probe."
                }
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
        }
    }

    Invoke-TestCase -Name 'unscoped discovery never assigns identity from a stopped CLI root' -Body {
        $staleVmRoot = Join-Path $tempRoot 'stopped-unscoped\MuMuPlayer-12.0-12'
        Write-VmConfig -VmRoot $staleVmRoot -Port $port1
        try {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $staleVmRoot
            Write-CliState -State ([ordered]@{
                vm12 = [ordered]@{ index = 12; is_process_started = $false; adb_port = $port1 }
            })
            Set-DeviceState -Serial1 $serial1 -Boot1 '11111111-2222-4333-8444-555555555551' -ListSerial2 $false
            $info = Invoke-ResolverInfo
            if ($info.Source -ne 'adb-connected' -or $null -ne $info.VmIndex) {
                throw "Stopped root leaked into unscoped discovery as source=$($info.Source) VmIndex=$($info.VmIndex)."
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
        }
    }

    Invoke-TestCase -Name 'running CLI VmIndex cannot be rescued by a reused stale config port' -Body {
        $staleVmRoot = Join-Path $tempRoot 'running-root\MuMuPlayer-12.0-12'
        Write-VmConfig -VmRoot $staleVmRoot -Port $port1
        try {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $staleVmRoot
            Write-CliState -State ([ordered]@{
                vm12 = [ordered]@{ index = 12; is_process_started = $true; adb_port = $port2 }
            })
            Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 `
                -Boot1 '11111111-2222-4333-8444-555555555551' `
                -Boot2 '11111111-2222-4333-8444-555555555552' `
                -Pid2 '' -Ps2 ''
            Clear-PendingConnections -Listener $listener1
            Clear-PendingConnections -Listener $listener2
            Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 12$' -Body {
                Invoke-ResolverInfo -VmIndex 12
            }
            if ($listener1.Pending()) {
                throw 'The stale config port reached the TCP probe after the authoritative CLI port failed qualification.'
            }
            if (-not $listener2.Pending()) {
                throw 'The authoritative CLI port did not reach the TCP probe.'
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
        }
    }

    Invoke-TestCase -Name 'explicit VmIndex fails closed when CLI mapping is unavailable' -Body {
        $fallbackVmRoot = Join-Path $tempRoot 'fallback-explicit\MuMuPlayer-12.0-12'
        Write-VmConfig -VmRoot $fallbackVmRoot -Port $port1
        try {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fallbackVmRoot
            [IO.File]::WriteAllText($script:cliJson, '{', [Text.Encoding]::ASCII)
            Set-DeviceState -Serial1 $serial1 -Boot1 '11111111-2222-4333-8444-555555555551' -ListSerial2 $false
            Clear-PendingConnections -Listener $listener1
            Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 12$' -Body {
                Invoke-ResolverInfo -VmIndex 12
            }
            if ($listener1.Pending()) {
                throw 'An indexed config port reached the TCP probe without an authoritative CLI mapping.'
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
            Write-CliState -State @{}
        }
    }

    Invoke-TestCase -Name 'unscoped discovery preserves config fallback when CLI is unavailable' -Body {
        $fallbackVmRoot = Join-Path $tempRoot 'fallback-unscoped\MuMuPlayer-12.0-12'
        Write-VmConfig -VmRoot $fallbackVmRoot -Port $port1
        try {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fallbackVmRoot
            [IO.File]::WriteAllText($script:cliJson, '{', [Text.Encoding]::ASCII)
            Set-DeviceState -Serial1 $serial1 -Boot1 '11111111-2222-4333-8444-555555555551' -ListSerial2 $false
            $info = Invoke-ResolverInfo
            if ($info.Serial -ne $serial1 -or $info.Source -ne 'vm-config') {
                throw "Expected unscoped vm-config fallback on $serial1; got source=$($info.Source) serial=$($info.Serial)."
            }
            if ($null -ne $info.VmIndex) {
                throw "Unverified directory index leaked into fallback output as VmIndex $($info.VmIndex)."
            }
        } finally {
            Set-TestEnvironment -Name 'MUMU_VM_ROOT' -Value $fakeVmRoot
            Write-CliState -State @{}
        }
    }

    Invoke-TestCase -Name 'negative VmIndex is rejected during parameter binding' -Body {
        Write-CliState -State @{}
        Set-DeviceState -Serial1 $serial1
        $caught = $null
        try {
            Invoke-ResolverInfo -VmIndex -1 | Out-Null
        } catch {
            $caught = $_
        }
        if ($null -eq $caught) {
            throw 'Expected negative VmIndex parameter validation, but the command succeeded.'
        }
        if ($caught.FullyQualifiedErrorId -notmatch 'ParameterArgumentValidationError') {
            throw "Expected parameter validation; got '$($caught.FullyQualifiedErrorId)': $($caught.Exception.Message)"
        }
    }

    Invoke-TestCase -Name 'invalid GamePackage values are rejected before discovery' -Body {
        Write-CliState -State ([ordered]@{
            vm6 = [ordered]@{ index = 6; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Clear-PendingConnections -Listener $listener1
        foreach ($invalidPackage in @('com.example.bad;value', 'com.example bad', '-com.example', 'single')) {
            $cliCallsBefore = Get-CliCallCount
            Assert-ParameterValidationFailure -Body {
                & $script:resolver -Action Info -GamePackage $invalidPackage -TcpTimeoutMs 200
            }
            $cliCallsAfter = Get-CliCallCount
            if ($cliCallsAfter -ne $cliCallsBefore) {
                throw "Invalid package '$invalidPackage' reached the fake CLI."
            }
            if ($listener1.Pending()) {
                throw "Invalid package '$invalidPackage' reached the TCP probe."
            }
        }
    }

    Invoke-TestCase -Name 'invalid TCP timeout values are rejected before discovery' -Body {
        Write-CliState -State ([ordered]@{
            vm6 = [ordered]@{ index = 6; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Clear-PendingConnections -Listener $listener1
        foreach ($invalidTimeout in @(-1, 0, 60001)) {
            $cliCallsBefore = Get-CliCallCount
            Assert-ParameterValidationFailure -Body {
                & $script:resolver -Action Info -TcpTimeoutMs $invalidTimeout
            }
            $cliCallsAfter = Get-CliCallCount
            if ($cliCallsAfter -ne $cliCallsBefore) {
                throw "Invalid timeout '$invalidTimeout' reached the fake CLI."
            }
            if ($listener1.Pending()) {
                throw "Invalid timeout '$invalidTimeout' reached the TCP probe."
            }
        }
    }

    Invoke-TestCase -Name 'invalid process timeout values are rejected before discovery' -Body {
        Write-CliState -State ([ordered]@{
            vm6 = [ordered]@{ index = 6; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        foreach ($invalidTimeout in @(99, 120001)) {
            $cliCallsBefore = Get-CliCallCount
            Assert-ParameterValidationFailure -Body {
                & $script:resolver -Action Info -ProcessTimeoutMs $invalidTimeout
            }
            if ((Get-CliCallCount) -ne $cliCallsBefore) {
                throw "Invalid process timeout '$invalidTimeout' reached the fake CLI."
            }
        }
    }

    Invoke-TestCase -Name 'MuMu CLI timeout is fatal and never falls back to ADB' -Body {
        Write-CliState -State ([ordered]@{
            vm6 = [ordered]@{ index = 6; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Set-TestEnvironment -Name 'SAFETY_CLI_DELAY_MS' -Value '1500'
        $adbCallsBefore = Get-AdbCallCount
        $started = [DateTime]::UtcNow
        try {
            Assert-Throws -MessagePattern '^MuMu CLI timed out after 100 ms\.$' -Body {
                & $script:resolver -Action Info -ProcessTimeoutMs 100 -TcpTimeoutMs 200
            }
        } finally {
            Set-TestEnvironment -Name 'SAFETY_CLI_DELAY_MS' -Value ''
        }
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($elapsedMs -gt 5000) { throw "CLI timeout returned too slowly: $elapsedMs ms." }
        if ((Get-AdbCallCount) -ne $adbCallsBefore) {
            throw 'CLI timeout reached ADB discovery.'
        }
    }

    Invoke-TestCase -Name 'ADB timeout is fatal and bounded' -Body {
        Write-CliState -State ([ordered]@{
            vm6 = [ordered]@{ index = 6; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Set-TestEnvironment -Name 'SAFETY_ADB_DELAY_MS' -Value '1500'
        $started = [DateTime]::UtcNow
        try {
            Assert-Throws -MessagePattern '^ADB command timed out after 100 ms\.' -Body {
                & $script:resolver -Action Info -VmIndex 6 -ProcessTimeoutMs 100 -TcpTimeoutMs 200
            }
        } finally {
            Set-TestEnvironment -Name 'SAFETY_ADB_DELAY_MS' -Value ''
        }
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($elapsedMs -gt 5000) { throw "ADB timeout returned too slowly: $elapsedMs ms." }
    }

    Invoke-TestCase -Name 'known VmIndex resolves its indexed candidate' -Body {
        Write-CliState -State ([ordered]@{
            vm7 = [ordered]@{ index = 7; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Clear-PendingConnections -Listener $listener1
        $cliCallsBefore = Get-CliCallCount
        $info = Invoke-ResolverInfo -VmIndex 7
        if ($info.VmIndex -ne 7 -or $info.Serial -ne $serial1) {
            throw "Expected vm=7 serial=$serial1; got vm=$($info.VmIndex) serial=$($info.Serial)."
        }
        if ($info.AdbPath -ne $fakeAdb -or $info.CliPath -ne $fakeCli) {
            throw "Resolver escaped fake tools: adb='$($info.AdbPath)' cli='$($info.CliPath)'."
        }
        $cliCallsAfter = Get-CliCallCount
        if ($cliCallsAfter -ne ($cliCallsBefore + 1)) {
            throw "Expected one fake CLI call; got $($cliCallsAfter - $cliCallsBefore)."
        }
        $lastCliCall = @(Get-Content -LiteralPath $script:cliLog)[-1]
        if ($lastCliCall -ne 'info --vmindex all') {
            throw "Unexpected fake CLI call '$lastCliCall'."
        }
        if (-not $listener1.Pending()) {
            throw 'Resolver did not pass through the random TCP listener gate.'
        }
    }

    Invoke-TestCase -Name 'shared strict running CLI port is rejected independent of property order before probing' -Body {
        $orders = @(
            [ordered]@{
                vm7 = [ordered]@{ index = 7; is_process_started = $true; adb_port = $port1 }
                vm8 = [ordered]@{ index = 8; is_process_started = $true; adb_port = $port1 }
            },
            [ordered]@{
                vm8 = [ordered]@{ index = 8; is_process_started = $true; adb_port = $port1 }
                vm7 = [ordered]@{ index = 7; is_process_started = $true; adb_port = $port1 }
            }
        )
        Set-DeviceState -Serial1 $serial1 -ListSerial2 $false
        foreach ($state in $orders) {
            foreach ($requestedIndex in @(7, 8)) {
                Write-CliState -State $state
                Clear-PendingConnections -Listener $listener1
                $adbCallsBefore = Get-AdbCallCount
                Assert-Throws -MessagePattern '^Ambiguous MuMu CLI running VmIndex-to-port mapping\.$' -Body {
                    Invoke-ResolverInfo -VmIndex $requestedIndex
                }
                if ((Get-AdbCallCount) -ne $adbCallsBefore) {
                    throw "Shared-port order reached ADB discovery for VmIndex $requestedIndex."
                }
                if ($listener1.Pending()) {
                    throw "Shared-port order reached the TCP probe for VmIndex $requestedIndex."
                }
            }

            Write-CliState -State $state
            Clear-PendingConnections -Listener $listener1
            $adbCallsBefore = Get-AdbCallCount
            Assert-Throws -MessagePattern '^Ambiguous MuMu CLI running VmIndex-to-port mapping\.$' -Body {
                Invoke-ResolverInfo
            }
            if ((Get-AdbCallCount) -ne $adbCallsBefore) {
                throw 'Unscoped shared-port discovery reached ADB probing.'
            }
            if ($listener1.Pending()) {
                throw 'Unscoped shared-port discovery reached the TCP probe.'
            }
        }
    }

    Invoke-TestCase -Name 'one strict running CLI index with multiple ports is rejected before probing' -Body {
        Write-CliState -State ([ordered]@{
            first = [ordered]@{ index = 7; is_process_started = $true; adb_port = $port1 }
            second = [ordered]@{ index = 7; is_process_started = $true; adb_port = $port2 }
        })
        Set-DeviceState -Serial1 $serial1 -Serial2 $serial2
        Clear-PendingConnections -Listener $listener1
        Clear-PendingConnections -Listener $listener2
        $adbCallsBefore = Get-AdbCallCount
        Assert-Throws -MessagePattern '^Ambiguous MuMu CLI running VmIndex-to-port mapping\.$' -Body {
            Invoke-ResolverInfo -VmIndex 7
        }
        if ((Get-AdbCallCount) -ne $adbCallsBefore) {
            throw 'Multi-port index reached ADB probing.'
        }
        if ($listener1.Pending() -or $listener2.Pending()) {
            throw 'Multi-port index reached a TCP probe.'
        }
    }

    Invoke-TestCase -Name 'missing BootId keeps equal AndroidId and model devices distinct' -Body {
        Write-CliState -State ([ordered]@{
            vm1 = [ordered]@{ index = 1; is_process_started = $true; adb_port = $port1 }
            vm2 = [ordered]@{ index = 2; is_process_started = $true; adb_port = $port2 }
        })
        Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 -Boot1 '' -Boot2 '' -Android1 'same-android' -Android2 'same-android'
        Assert-Throws -MessagePattern '^Multiple distinct MuMu targets matched\.' -Body {
            Invoke-ResolverInfo
        }
    }

    Invoke-TestCase -Name 'invalid BootId cannot merge serial aliases' -Body {
        Write-CliState -State ([ordered]@{
            vm1 = [ordered]@{ index = 1; is_process_started = $true; adb_port = $port1 }
            vm2 = [ordered]@{ index = 2; is_process_started = $true; adb_port = $port2 }
        })
        Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 -Boot1 'not-a-uuid' -Boot2 'not-a-uuid' -Android1 'same-android' -Android2 'same-android'
        Assert-Throws -MessagePattern '^Multiple distinct MuMu targets matched\.' -Body {
            Invoke-ResolverInfo
        }
    }

    Invoke-TestCase -Name 'equal valid BootId merges aliases despite auxiliary AndroidId differences' -Body {
        $bootId = '11111111-2222-4333-8444-555555555555'
        Write-CliState -State ([ordered]@{
            vm5 = [ordered]@{ index = 5; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1 -Serial2 $serial2 -Boot1 $bootId -Boot2 $bootId -Android1 'android-a' -Android2 'android-b'
        $info = Invoke-ResolverInfo -VmIndex 5
        $aliases = @($info.Aliases)
        if ($info.VmIndex -ne 5 -or $aliases.Count -ne 2 -or $aliases -notcontains $serial1 -or $aliases -notcontains $serial2) {
            throw "Expected both aliases for VmIndex 5; got '$($aliases -join ',')'."
        }
    }

    Invoke-TestCase -Name 'similar package in ps is not a game PID' -Body {
        Write-CliState -State ([ordered]@{
            vm3 = [ordered]@{ index = 3; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1 -Pid1 '' -Ps1 '4321 com.huanmeng.zhanjian2.helper'
        Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 3$' -Body {
            Invoke-ResolverInfo -VmIndex 3
        }
    }

    Invoke-TestCase -Name 'exact package in ps returns its numeric PID' -Body {
        Write-CliState -State ([ordered]@{
            vm4 = [ordered]@{ index = 4; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1 -Pid1 '' -Ps1 '4321 com.huanmeng.zhanjian2'
        $info = Invoke-ResolverInfo -VmIndex 4
        if ([string]$info.GamePid -ne '4321') {
            throw "Expected numeric GamePid 4321; got '$($info.GamePid)'."
        }
    }

    Invoke-TestCase -Name 'foreground package comparison is case-sensitive' -Body {
        Write-CliState -State ([ordered]@{
            vm8 = [ordered]@{ index = 8; is_process_started = $true; adb_port = $port1 }
        })
        Set-DeviceState -Serial1 $serial1
        Set-TestEnvironment -Name 'SAFETY_FOREGROUND1' -Value 'COM.HUANMENG.ZHANJIAN2'
        try {
            Assert-Throws -MessagePattern '^No MuMu target matched VmIndex 8$' -Body {
                & $script:resolver -Action Info -VmIndex 8 -RequireForeground -TcpTimeoutMs 200
            }
        } finally {
            Set-TestEnvironment -Name 'SAFETY_FOREGROUND1' -Value 'com.huanmeng.zhanjian2'
        }
    }

    Invoke-TestCase -Name 'null BootId survives resolver capture and fresh input evidence' -Body {
        $integrationRoot = Join-Path $tempRoot 'bootid-contract'
        $integrationPng = Join-Path $integrationRoot 'source.png'
        $inputLog = Join-Path $integrationRoot 'input.log'
        New-Item -ItemType Directory -Path $integrationRoot -Force | Out-Null
        $minimalPng = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
        [IO.File]::WriteAllBytes($integrationPng, $minimalPng)
        Set-TestEnvironment -Name 'SAFETY_PNG_SOURCE' -Value $integrationPng
        Set-TestEnvironment -Name 'SAFETY_INPUT_LOG' -Value $inputLog

        foreach ($case in @(
            [pscustomobject]@{ Name = 'missing'; Value = '' },
            [pscustomobject]@{ Name = 'invalid'; Value = 'not-a-uuid' }
        )) {
            $caseOutput = Join-Path $integrationRoot $case.Name
            New-Item -ItemType Directory -Path $caseOutput -Force | Out-Null
            Write-CliState -State ([ordered]@{
                vm11 = [ordered]@{ index = 11; is_process_started = $true; adb_port = $port1 }
            })
            Set-DeviceState -Serial1 $serial1 -Boot1 $case.Value -ListSerial2 $false
            Clear-PendingConnections -Listener $listener1

            $resolverJson = & $script:resolver -Action Info -VmIndex 11 -RequireForeground -TcpTimeoutMs 200
            if ($resolverJson -notmatch '"BootId"\s*:\s*null') {
                throw "Resolver serialized $($case.Name) BootId as a non-null JSON value: $resolverJson"
            }
            $resolved = $resolverJson | ConvertFrom-Json
            if ($null -ne $resolved.BootId) {
                throw "Resolver returned $($case.Name) BootId as '$($resolved.BootId)' instead of null."
            }

            $captureScript = Join-Path $repo 'scripts/capture-mumu-state.ps1'
            $captureResult = (& $captureScript -OutputDirectory $caseOutput -VmIndex 11 -RequireForeground) | ConvertFrom-Json
            $evidenceText = [IO.File]::ReadAllText($captureResult.EvidenceJson, [Text.Encoding]::UTF8)
            $evidence = $evidenceText | ConvertFrom-Json
            $bootProperty = $evidence.Fingerprint.PSObject.Properties['BootId']
            if ($null -eq $bootProperty -or $null -ne $bootProperty.Value) {
                throw "Capture did not preserve $($case.Name) BootId as Fingerprint.BootId=null."
            }
            if ($evidenceText -notmatch '"BootId"\s*:\s*null') {
                throw 'Capture sidecar did not serialize BootId as JSON null.'
            }

            $beforeCalls = if (Test-Path -LiteralPath $inputLog -PathType Leaf) {
                @(Get-Content -LiteralPath $inputLog).Count
            } else { 0 }
            $inputScript = Join-Path $repo 'scripts/send-mumu-input.ps1'
            & $inputScript -Action Tap -X 0 -Y 0 -EvidenceJson $captureResult.EvidenceJson | Out-Null
            $afterCalls = @(Get-Content -LiteralPath $inputLog).Count
            if ($afterCalls -ne ($beforeCalls + 1)) {
                throw "Expected one input for $($case.Name) BootId evidence; got $($afterCalls - $beforeCalls)."
            }
            $receipt = Get-Content -LiteralPath "$($captureResult.EvidenceJson).consumed.json" -Raw | ConvertFrom-Json
            if ($receipt.Status -ne 'sent') {
                throw "Expected sent receipt for $($case.Name) BootId evidence; got '$($receipt.Status)'."
            }
        }
    }

    $captureRoot = Join-Path $tempRoot 'capture'
    $captureOutput = Join-Path $captureRoot 'output'
    New-Item -ItemType Directory -Path $captureRoot, $captureOutput -Force | Out-Null
    $capture = Join-Path $captureRoot 'capture-mumu-state.ps1'
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/capture-mumu-state.ps1') -Destination $capture
    $boundedRunnerSource = Join-Path $repo 'scripts/invoke-bounded-process.ps1'
    if (Test-Path -LiteralPath $boundedRunnerSource -PathType Leaf) {
        Copy-Item -LiteralPath $boundedRunnerSource -Destination $captureRoot
    }
    $captureResolver = Join-Path $captureRoot 'resolve-mumu-target.ps1'
    [IO.File]::WriteAllText($captureResolver, @'
param([string]$Action, [string]$GamePackage, [bool]$AllowGameStopped, [bool]$RequireForeground, [int]$VmIndex, [int]$ProcessTimeoutMs)
$count = 0
if (Test-Path -LiteralPath $env:CAPTURE_COUNTER_FILE -PathType Leaf) {
    $count = [int](Get-Content -LiteralPath $env:CAPTURE_COUNTER_FILE -Raw)
}
$count++
[IO.File]::WriteAllText($env:CAPTURE_COUNTER_FILE, [string]$count, [Text.Encoding]::ASCII)
$activity = if ($count -eq 1) { $env:CAPTURE_ACTIVITY_BEFORE } else { $env:CAPTURE_ACTIVITY_AFTER }
[pscustomobject]@{
    AdbPath = (Join-Path $PSScriptRoot 'adb.cmd')
    Serial = 'offline'
    VmIndex = 0
    BootId = '11111111-2222-4333-8444-555555555555'
    AndroidId = 'android'
    GamePid = '1234'
    ForegroundPackage = $GamePackage
    ForegroundActivity = $activity
    PhysicalSize = '1080x1920'
    OverrideSize = ''
    Rotation = 0
} | ConvertTo-Json -Compress
'@, [Text.Encoding]::ASCII)
    $captureAdb = Join-Path $captureRoot 'adb.cmd'
    [IO.File]::WriteAllText($captureAdb, @'
@echo off
if not "%CAPTURE_ADB_LOG%"=="" echo %*>> "%CAPTURE_ADB_LOG%"
if not "%1"=="-s" exit /b 81
if not "%2"=="offline" exit /b 82
if "%3"=="pull" goto pull
if "%3"=="shell" if "%4"=="screencap" goto screencap
if "%3"=="shell" if "%4"=="rm" goto cleanup
exit /b 83
:screencap
if not "%CAPTURE_DELAY_MS%"=="0" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command Start-Sleep -Milliseconds %CAPTURE_DELAY_MS%
if not "%CAPTURE_SCREENCAP_DELAY_MS%"=="" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command Start-Sleep -Milliseconds %CAPTURE_SCREENCAP_DELAY_MS%
exit /b 0
:pull
if not "%CAPTURE_PULL_DELAY_MS%"=="" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command Start-Sleep -Milliseconds %CAPTURE_PULL_DELAY_MS%
copy /y "%CAPTURE_PNG_SOURCE%" "%~5" >nul
exit /b %ERRORLEVEL%
:cleanup
if not "%CAPTURE_RM_DELAY_MS%"=="" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command Start-Sleep -Milliseconds %CAPTURE_RM_DELAY_MS%
if not "%CAPTURE_RM_EXIT_CODE%"=="" exit /b %CAPTURE_RM_EXIT_CODE%
exit /b 0
'@, [Text.Encoding]::ASCII)
    $pngSource = Join-Path $captureRoot 'source.png'
    $minimalPng = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
    [IO.File]::WriteAllBytes($pngSource, $minimalPng)
    $counterFile = Join-Path $captureRoot 'counter.txt'
    $captureAdbLog = Join-Path $captureRoot 'adb.log'
    Set-TestEnvironment -Name 'CAPTURE_COUNTER_FILE' -Value $counterFile
    Set-TestEnvironment -Name 'CAPTURE_PNG_SOURCE' -Value $pngSource
    Set-TestEnvironment -Name 'CAPTURE_ADB_LOG' -Value $captureAdbLog
    Set-TestEnvironment -Name 'CAPTURE_SCREENCAP_DELAY_MS' -Value ''
    Set-TestEnvironment -Name 'CAPTURE_PULL_DELAY_MS' -Value ''
    Set-TestEnvironment -Name 'CAPTURE_RM_DELAY_MS' -Value ''
    Set-TestEnvironment -Name 'CAPTURE_RM_EXIT_CODE' -Value ''

    Invoke-TestCase -Name 'capture rejects a ForegroundActivity change' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'DialogActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '0'
        Assert-Throws -MessagePattern '^Target changed during capture\.' -Body {
            & $capture -OutputDirectory $captureOutput | Out-Null
        }
        $sidecar = @(Get-ChildItem -LiteralPath $captureOutput -Filter '*.json')
        if ($sidecar.Count -ne 1) { throw "Expected one unstable sidecar; got $($sidecar.Count)." }
        $evidence = Get-Content -LiteralPath $sidecar[0].FullName -Raw | ConvertFrom-Json
        if ($evidence.Stable) { throw 'Activity-changing evidence was marked stable.' }
    }

    Invoke-TestCase -Name 'capture rejects a case-only ForegroundActivity change' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'mainActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '0'
        Assert-Throws -MessagePattern '^Target changed during capture\.' -Body {
            & $capture -OutputDirectory $captureOutput | Out-Null
        }
        $sidecar = @(Get-ChildItem -LiteralPath $captureOutput -Filter '*.json')
        if ($sidecar.Count -ne 1) { throw "Expected one unstable sidecar; got $($sidecar.Count)." }
        $evidence = Get-Content -LiteralPath $sidecar[0].FullName -Raw | ConvertFrom-Json
        if ($evidence.Stable) { throw 'Case-only Activity-changing evidence was marked stable.' }
    }

    Invoke-TestCase -Name 'capture rejects invalid GamePackage before target resolution' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Assert-ParameterValidationFailure -Body {
            & $capture -OutputDirectory $captureOutput -GamePackage 'com.example bad'
        }
        if (Test-Path -LiteralPath $counterFile) {
            throw 'Invalid capture GamePackage reached the target resolver.'
        }
        if (@(Get-ChildItem -LiteralPath $captureOutput -File).Count -ne 0) {
            throw 'Invalid capture GamePackage created output files.'
        }
    }

    Invoke-TestCase -Name 'capture rejects invalid process timeout before target resolution' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        foreach ($invalidTimeout in @(99, 120001)) {
            Assert-ParameterValidationFailure -Body {
                & $capture -OutputDirectory $captureOutput -ProcessTimeoutMs $invalidTimeout
            }
        }
        if (Test-Path -LiteralPath $counterFile) {
            throw 'Invalid capture process timeout reached the target resolver.'
        }
        if (@(Get-ChildItem -LiteralPath $captureOutput -File).Count -ne 0) {
            throw 'Invalid capture process timeout created output files.'
        }
    }

    Invoke-TestCase -Name 'capture screencap timeout remains primary over cleanup failure' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        if (Test-Path -LiteralPath $captureAdbLog) { Remove-Item -LiteralPath $captureAdbLog -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '0'
        Set-TestEnvironment -Name 'CAPTURE_SCREENCAP_DELAY_MS' -Value '1500'
        Set-TestEnvironment -Name 'CAPTURE_RM_EXIT_CODE' -Value '72'
        $started = [DateTime]::UtcNow
        try {
            Assert-Throws -MessagePattern '^Remote screencap timed out after 300 ms\.$' -Body {
                & $capture -OutputDirectory $captureOutput -ProcessTimeoutMs 300 | Out-Null
            }
        } finally {
            Set-TestEnvironment -Name 'CAPTURE_SCREENCAP_DELAY_MS' -Value ''
            Set-TestEnvironment -Name 'CAPTURE_RM_EXIT_CODE' -Value ''
        }
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($elapsedMs -gt 5000) { throw "Capture timeout returned too slowly: $elapsedMs ms." }
        if (-not (Test-Path -LiteralPath $captureAdbLog -PathType Leaf) -or
            (Get-Content -LiteralPath $captureAdbLog -Raw) -notmatch 'shell rm -f') {
            throw 'Capture timeout did not attempt bounded remote cleanup.'
        }
        if (@(Get-ChildItem -LiteralPath $captureOutput -Filter '*.json').Count -ne 0) {
            throw 'Failed capture emitted a valid evidence sidecar.'
        }
    }

    Invoke-TestCase -Name 'capture pull timeout is bounded and emits no evidence sidecar' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        if (Test-Path -LiteralPath $captureAdbLog) { Remove-Item -LiteralPath $captureAdbLog -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '0'
        Set-TestEnvironment -Name 'CAPTURE_PULL_DELAY_MS' -Value '1500'
        $started = [DateTime]::UtcNow
        try {
            Assert-Throws -MessagePattern '^Screenshot pull timed out after 300 ms\.$' -Body {
                & $capture -OutputDirectory $captureOutput -ProcessTimeoutMs 300 | Out-Null
            }
        } finally {
            Set-TestEnvironment -Name 'CAPTURE_PULL_DELAY_MS' -Value ''
        }
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($elapsedMs -gt 5000) { throw "Screenshot pull timeout returned too slowly: $elapsedMs ms." }
        if (-not (Test-Path -LiteralPath $captureAdbLog -PathType Leaf) -or
            (Get-Content -LiteralPath $captureAdbLog -Raw) -notmatch 'shell rm -f') {
            throw 'Screenshot pull timeout did not attempt bounded remote cleanup.'
        }
        if (@(Get-ChildItem -LiteralPath $captureOutput -Filter '*.json').Count -ne 0) {
            throw 'Pull-timeout capture emitted a valid evidence sidecar.'
        }
    }

    Invoke-TestCase -Name 'capture cleanup timeout is bounded and emits no evidence sidecar' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '0'
        Set-TestEnvironment -Name 'CAPTURE_RM_DELAY_MS' -Value '1500'
        $started = [DateTime]::UtcNow
        try {
            Assert-Throws -MessagePattern '^Remote screenshot cleanup timed out after 300 ms\.$' -Body {
                & $capture -OutputDirectory $captureOutput -ProcessTimeoutMs 300 | Out-Null
            }
        } finally {
            Set-TestEnvironment -Name 'CAPTURE_RM_DELAY_MS' -Value ''
        }
        $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($elapsedMs -gt 5000) { throw "Capture cleanup timeout returned too slowly: $elapsedMs ms." }
        if (@(Get-ChildItem -LiteralPath $captureOutput -Filter '*.json').Count -ne 0) {
            throw 'Cleanup-timeout capture emitted a valid evidence sidecar.'
        }
    }

    Invoke-TestCase -Name 'capture timestamp is fixed before delayed screencap' -Body {
        if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
        Get-ChildItem -LiteralPath $captureOutput -File | Remove-Item -Force
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_BEFORE' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_ACTIVITY_AFTER' -Value 'MainActivity'
        Set-TestEnvironment -Name 'CAPTURE_DELAY_MS' -Value '2100'
        $started = [DateTimeOffset]::UtcNow
        $result = (& $capture -OutputDirectory $captureOutput) | ConvertFrom-Json
        $finished = [DateTimeOffset]::UtcNow
        $evidence = Get-Content -LiteralPath $result.EvidenceJson -Raw | ConvertFrom-Json
        if ($evidence.CapturedAtUtc -is [DateTime]) {
            $captured = ([DateTimeOffset]$evidence.CapturedAtUtc).ToUniversalTime()
        } else {
            $captured = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$evidence.CapturedAtUtc, [ref]$captured)) {
                throw "CapturedAtUtc is invalid: '$($evidence.CapturedAtUtc)'."
            }
            $captured = $captured.ToUniversalTime()
        }
        if (($captured - $started).TotalSeconds -lt -0.5) {
            throw "CapturedAtUtc predates the invocation: captured=$captured started=$started."
        }
        if (($captured - $started).TotalSeconds -gt 1.25) {
            throw "CapturedAtUtc was recorded too late: $captured (started $started)."
        }
        if (($finished - $captured).TotalSeconds -lt 1.5) {
            throw "CapturedAtUtc does not conservatively precede screenshot completion: captured=$captured finished=$finished."
        }
    }

    if ($failures.Count -gt 0) {
        throw "MuMu safety tests failed ($($failures.Count)):`n - $($failures -join "`n - ")"
    }
    Write-Output 'Offline MuMu safety tests passed.'
}
finally {
    foreach ($listener in $listeners) {
        try { $listener.Stop() } catch { }
    }
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
