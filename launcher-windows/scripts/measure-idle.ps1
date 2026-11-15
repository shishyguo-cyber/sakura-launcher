# Idle resource baseline (P-012): runs the built Sakura with an isolated test root and a target that never starts,
# lets it settle, then reports CPU time used per minute and memory. Writes nothing outside the given work folder.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Work,
    [int] $SettleSeconds = 15,
    [int] $SampleSeconds = 60
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $Work ("idle-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$never = Join-Path $root 'never\NotRunning.exe'
$p = Start-Process -FilePath $Exe -ArgumentList @('--test-root', $root, '--test-target-exe', $never) -PassThru
try {
    Start-Sleep -Seconds $SettleSeconds
    $p.Refresh(); $cpu0 = $p.TotalProcessorTime.TotalSeconds
    $peak = 0
    for ($i = 0; $i -lt $SampleSeconds; $i++) {
        Start-Sleep -Seconds 1
        $p.Refresh(); if ($p.HasExited) { throw "Sakura exited during sampling (code $($p.ExitCode))" }
        $peak = [Math]::Max($peak, $p.WorkingSet64)
    }
    $p.Refresh(); $cpu1 = $p.TotalProcessorTime.TotalSeconds
    [pscustomobject]@{
        cpuSecondsPerMinute = [Math]::Round(($cpu1 - $cpu0) * 60 / $SampleSeconds, 3)
        averageCpuPercentOfOneCore = [Math]::Round(($cpu1 - $cpu0) * 100 / $SampleSeconds, 2)
        workingSetMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
        peakWorkingSetMB = [Math]::Round($peak / 1MB, 1)
        privateMB = [Math]::Round($p.PrivateMemorySize64 / 1MB, 1)
        threads = $p.Threads.Count
        handles = $p.HandleCount
        processesOnMachine = (Get-Process).Count
    } | ConvertTo-Json
}
finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
