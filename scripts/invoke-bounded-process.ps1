function ConvertTo-NativeProcessArgument {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

if ($env:OS -eq 'Windows_NT' -and -not ('BoundedProcess.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BoundedProcess {
    public static class NativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);

        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function New-BoundedProcessJob {
    if ($env:OS -ne 'Windows_NT' -or -not ('BoundedProcess.NativeMethods' -as [type])) {
        return [IntPtr]::Zero
    }

    return [BoundedProcess.NativeMethods]::CreateJobObject([IntPtr]::Zero, $null)
}

function Close-BoundedProcessJob {
    param([IntPtr]$Job)
    if ($Job -ne [IntPtr]::Zero) {
        [void][BoundedProcess.NativeMethods]::CloseHandle($Job)
    }
}

function Stop-BoundedProcessTree {
    param([Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }
    try {
        if ($Process.HasExited) { return }
    } catch {
        return
    }

    $treeKill = @($Process.GetType().GetMethods() | Where-Object {
        $_.Name -eq 'Kill' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType -eq [bool]
    }) | Select-Object -First 1
    if ($treeKill) {
        try {
            [void]$treeKill.Invoke($Process, @($true))
            return
        } catch { }
    }

    if ($env:OS -eq 'Windows_NT') {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            $killer = $null
            try {
                $killerInfo = [Diagnostics.ProcessStartInfo]::new()
                $killerInfo.FileName = $taskkill
                $killerInfo.Arguments = "/PID $($Process.Id) /T /F"
                $killerInfo.UseShellExecute = $false
                $killerInfo.CreateNoWindow = $true
                $killer = [Diagnostics.Process]::new()
                $killer.StartInfo = $killerInfo
                if ($killer.Start()) {
                    if (-not $killer.WaitForExit(2000)) {
                        try { $killer.Kill() } catch { }
                    }
                }
            } catch { } finally {
                if ($killer) { $killer.Dispose() }
            }
        }
    }

    try {
        if (-not $Process.HasExited) { $Process.Kill() }
    } catch { }
}

function Invoke-BoundedProcess {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [ValidateRange(100, 120000)]
        [int]$TimeoutMs = 10000
    )

    $resolvedFile = $FilePath
    if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
        $resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path
    }

    $effectiveFile = $resolvedFile
    $effectiveArguments = @($ArgumentList)
    $isBatchFile = [IO.Path]::GetExtension($resolvedFile) -match '^\.(?:cmd|bat)$'
    if ($isBatchFile) {
        $commandInterpreter = $env:ComSpec
        if ([string]::IsNullOrWhiteSpace($commandInterpreter)) {
            $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
        }
        $batchCommand = (@(ConvertTo-NativeProcessArgument -Value $resolvedFile) +
            @($effectiveArguments | ForEach-Object { ConvertTo-NativeProcessArgument -Value $_ })) -join ' '
        $effectiveFile = $commandInterpreter
        $effectiveArguments = @('/d', '/s', '/c', $batchCommand)
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $effectiveFile
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $nativeArgumentList = $startInfo.PSObject.Properties['ArgumentList']
    if ($isBatchFile) {
        $startInfo.Arguments = '/d /s /c "' + $batchCommand + '"'
    } elseif ($nativeArgumentList) {
        foreach ($argument in $effectiveArguments) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $startInfo.Arguments = (@($effectiveArguments | ForEach-Object {
            ConvertTo-NativeProcessArgument -Value $_
        }) -join ' ')
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stdoutTask = $null
    $stderrTask = $null
    $job = [IntPtr]::Zero
    try {
        if (-not $process.Start()) { throw "Process failed to start: $FilePath" }
        $job = New-BoundedProcessJob
        if ($job -ne [IntPtr]::Zero -and
            -not [BoundedProcess.NativeMethods]::AssignProcessToJobObject($job, $process.Handle)) {
            Close-BoundedProcessJob -Job $job
            $job = [IntPtr]::Zero
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutMs)
        if (-not $finished) {
            # Kill the observed tree first. This also covers a child that started
            # in the short interval before the parent was assigned to the job.
            if (-not $process.HasExited) { Stop-BoundedProcessTree -Process $process }
            if ($job -ne [IntPtr]::Zero) {
                [void][BoundedProcess.NativeMethods]::TerminateJobObject($job, 1)
                Close-BoundedProcessJob -Job $job
                $job = [IntPtr]::Zero
            }
            try { [void]$process.WaitForExit(2000) } catch { }
        } else {
            # The process has already exited; this bounded call only lets the
            # redirected stream events settle without introducing an unbounded wait.
            try { [void]$process.WaitForExit(100) } catch { }
        }

        foreach ($streamTask in @($stdoutTask, $stderrTask)) {
            if ($streamTask -and -not $streamTask.IsCompleted) {
                try { [void]$streamTask.Wait(500) } catch { }
            }
        }

        $stdout = if ($stdoutTask -and $stdoutTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
            [string]$stdoutTask.Result
        } else { '' }
        $stderr = if ($stderrTask -and $stderrTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
            [string]$stderrTask.Result
        } else { '' }
        $exitCode = if ($finished) { [Nullable[int]]$process.ExitCode } else { $null }

        return [pscustomobject]@{
            FilePath   = $resolvedFile
            Arguments  = @($ArgumentList)
            ExitCode   = $exitCode
            StdOut     = $stdout
            StdErr     = $stderr
            TimedOut   = -not $finished
            DurationMs = [long]$stopwatch.ElapsedMilliseconds
        }
    } finally {
        $stopwatch.Stop()
        $processStillRunning = $false
        try { $processStillRunning = -not $process.HasExited } catch { }
        if ($processStillRunning) {
            Stop-BoundedProcessTree -Process $process
            if ($job -ne [IntPtr]::Zero) {
                [void][BoundedProcess.NativeMethods]::TerminateJobObject($job, 1)
            }
            try { [void]$process.WaitForExit(2000) } catch { }
        }
        if ($job -ne [IntPtr]::Zero) { Close-BoundedProcessJob -Job $job }
        $process.Dispose()
    }
}
