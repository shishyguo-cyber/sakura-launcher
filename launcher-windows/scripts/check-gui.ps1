param([Parameter(Mandatory=$true)][string]$OutputRoot, [switch]$EscapeOnly, [string]$ProjectRoot='')
$ErrorActionPreference = 'Stop'
if ($ProjectRoot) { $project=[IO.Path]::GetFullPath($ProjectRoot) }
elseif ($PSScriptRoot) { $project=Split-Path $PSScriptRoot -Parent }
else { throw 'Inline invocation requires -ProjectRoot' }
$dev = Split-Path $project -Parent
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (-not $OutputRoot.StartsWith($dev + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Test output must stay inside the repository root' }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$app = Join-Path $project 'GardenBoot.App\bin\Release\net10.0-windows\Sakura.exe'
$fixture = Join-Path $project 'GardenBoot.GuiFixture\bin\Release\net10.0-windows\GardenBoot.TestTarget.exe'
$demo = Join-Path (Split-Path $app) 'demo-pack'
$children = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$report = [ordered]@{ status='running'; passed=$false; sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;
    chatGPTRestarted=$false; loginItemsChanged=$false; videoUsed='original demo-garden only' }

function Save-Report {
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'report.json'), ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
function Read-Events([string]$name) {
    $path = Join-Path $OutputRoot ($name + '\events.log')
    if (Test-Path $path) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    return ''
}
function Wait-Until([scriptblock]$condition, [string]$description, [double]$seconds=15) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $seconds) {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 80
    }
    throw ('Timed out: ' + $description)
}
function Start-Owned([string]$executable, [string[]]$arguments) {
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru
    $children.Add($process)
    return $process
}
function Stop-Owned($process) {
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'Owned process failed to exit' }
    }
}
function Prepare-Pack([string]$name, [int]$wait=6) {
    $folder=Join-Path $OutputRoot ($name + '\Packs\demo-garden')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Copy-Item (Join-Path $demo '*') $folder
    $manifest=Get-Content (Join-Path $folder 'manifest.json') -Raw | ConvertFrom-Json
    $manifest.maxWaitSeconds=$wait
    [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    # Keep controlled automatic scenes independent of the user's system animation preference.
    [IO.File]::WriteAllText((Join-Path $OutputRoot ($name+'\settings.json')), '{"Paused":false,"PlayDespiteReduceMotion":true}', [Text.UTF8Encoding]::new($false))
}
function Start-Watcher([string]$name, [string[]]$extra=@()) {
    $state=Join-Path $OutputRoot $name
    $process=Start-Owned $app (@('--test-root',('"'+$state+'"'),'--test-target-exe',('"'+$fixture+'"'))+$extra)
    Wait-Until { (Read-Events $name).Contains('monitor-started') } ($name+' monitor')
    return $process
}
function Event-Time([string]$name, [string]$token) {
    $line = (Read-Events $name) -split "`n" | Where-Object { $_.Contains($token) } | Select-Object -First 1
    if (-not $line) { throw ($name+': missing '+$token) }
    return [DateTimeOffset]::Parse(($line -split ' ')[0])
}
function Start-SettingsWatcher([string]$name) {
    # No --test-target-exe: the targets come from the test root's experience.json (TARGETS.md §5).
    $state=Join-Path $OutputRoot $name
    $process=Start-Owned $app @('--test-root',('"'+$state+'"'))
    Wait-Until { (Read-Events $name).Contains('monitor-started') } ($name+' monitor')
    return $process
}
function Assert-Order([string]$name, [string[]]$tokens) {
    $text=Read-Events $name
    $offset=0
    foreach ($token in $tokens) {
        $index=$text.IndexOf($token,$offset,[StringComparison]::Ordinal)
        if ($index -lt 0) { throw ($name+': missing/out-of-order '+$token) }
        $offset=$index+$token.Length
    }
}

try {
    if ($report.sessionId -eq 0 -or -not [Environment]::UserInteractive) { throw 'Run this test in the logged-in desktop session' }
    if ($EscapeOnly) {
        Prepare-Pack 'escape' 60
        $watcher=Start-Watcher 'escape'
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'escape').Contains('player-play segment=loop') } 'escape loop'
        $report.status='waiting-for-escape'; Save-Report
        Wait-Until { (Read-Events 'escape').Contains('player-finished reason=skipped') } 'physical Escape key' 55
        if ((Read-Events 'escape').Contains('skip-hotkey-unavailable')) { throw 'Escape hotkey was not available' }
        $report.escapeSkipObserved=$true
    } else {
        # Existing target baseline must not replay.
        $target=Start-Owned $fixture @('--window-delay','0')
        Wait-Until { $target.Refresh(); $target.MainWindowHandle -ne 0 } 'baseline window'
        Prepare-Pack 'baseline'
        $watcher=Start-Watcher 'baseline'
        Start-Sleep -Milliseconds 700
        if (-not (Read-Events 'baseline').Contains('baseline=1') -or (Read-Events 'baseline').Contains('launch-detected')) {
            throw 'Existing process incorrectly replayed'
        }
        $report.existingApplicationSkipped=$true
        Stop-Owned $watcher; Stop-Owned $target

        Prepare-Pack 'delayed'
        $watcher=Start-Watcher 'delayed'
        $target=Start-Owned $fixture @('--window-delay','3.3','--move','--move-after','0.4')
        Wait-Until { (Read-Events 'delayed').Contains('player-finished reason=') } 'delayed completion'
        if ((Read-Events 'delayed').Contains('reason=user-switched')) { throw 'Interrupted by foreground application change during delayed scene' }
        Assert-Order 'delayed' @('launch-detected','player-play segment=intro','player-play segment=loop','window-ready',
            'player-play segment=outro','player-handoff','fade-completed','player-finished reason=completed')
        if ((Read-Events 'delayed').Contains('reason=failed')) { throw 'Delayed scenario had a media failure' }
        $report.delayedWindowIntroLoopOutro=$true
        # P-006: nothing is shown before the first video frame.
        Assert-Order 'delayed' @('launch-detected','first-frame','player-show')
        $report.firstFrameDelayed=((Read-Events 'delayed') -split "`n" | Where-Object { $_ -match 'first-frame' } | Select-Object -First 1) -replace '^\S+ ',''
        $report.followObserved=(Read-Events 'delayed').Contains('player-follow')
        if (-not $report.followObserved) { throw 'Target window moved but no follow update was recorded' }
        Stop-Owned $watcher; Stop-Owned $target

        Prepare-Pack 'timeout'
        $watcher=Start-Watcher 'timeout'
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'timeout').Contains('player-finished reason=window-timeout') } 'window timeout'
        Assert-Order 'timeout' @('player-play segment=intro','player-play segment=loop','wait-timed-out','fade-completed','player-finished reason=window-timeout')
        $report.noWindowTimesOut=$true
        Stop-Owned $watcher; Stop-Owned $target

        Prepare-Pack 'preview'
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'preview\settings.json'), '{"Paused":true}', [Text.UTF8Encoding]::new($false))
        $watcher=Start-Watcher 'preview' @('--preview')
        Wait-Until { (Read-Events 'preview').Contains('player-finished reason=completed') } 'paused manual preview'
        Assert-Order 'preview' @('player-play segment=intro','player-play segment=loop','player-play segment=outro','fade-completed')
        $report.previewBypassesPause=$true
        Stop-Owned $watcher

        # P-003: first play of the day, then the same day is skipped; a snooze skips; rotation avoids repeating.
        $utf8=[Text.UTF8Encoding]::new($false)
        Prepare-Pack 'daily' 2
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'daily\experience.json'),
            '{"schemaVersion":2,"masterVolume":1,"muted":false,"packs":{},"playback":{"frequency":"firstOfDay","dayStartHour":4},"library":{"rotation":"fixed","favorites":[]}}', $utf8)
        $watcher=Start-Watcher 'daily'
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'daily').Contains('player-finished reason=window-timeout') } 'first play of the day'
        Stop-Owned $target
        Wait-Until { (Read-Events 'daily').Contains('target-exited') } 'daily target exit'
        $state=Get-Content (Join-Path $OutputRoot 'daily\playback-state.json') -Raw | ConvertFrom-Json
        if ($null -eq $state.targets.test.lastAutoPlayAt -or $state.targets.test.lastPackId -ne 'demo-garden') { throw 'Automatic play was not recorded' }
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'daily').Contains('playback-skipped reason=played-today') } 'second launch same day skipped'
        $report.firstOfDaySkipsSecondLaunch=$true
        Stop-Owned $target; Stop-Owned $watcher
        $until=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+600
        Prepare-Pack 'snooze' 2
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'snooze\playback-state.json'), ('{"schemaVersion":1,"snoozeUntil":'+$until+'}'), $utf8)
        $watcher=Start-Watcher 'snooze'
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'snooze').Contains('playback-skipped reason=snoozed') } 'snoozed launch skipped'
        $report.snoozeSkips=$true
        Stop-Owned $target; Stop-Owned $watcher

        Prepare-Pack 'rotation' 2
        $second=Join-Path $OutputRoot 'rotation\Packs\second-garden'
        Copy-Item (Join-Path $OutputRoot 'rotation\Packs\demo-garden') $second -Recurse
        $m=Get-Content (Join-Path $second 'manifest.json') -Raw | ConvertFrom-Json
        $m.id='second-garden'; $m.name='second'
        [IO.File]::WriteAllText((Join-Path $second 'manifest.json'), ($m | ConvertTo-Json -Depth 5), $utf8)
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'rotation\experience.json'),
            '{"schemaVersion":2,"masterVolume":1,"muted":false,"packs":{},"playback":{"frequency":"everyLaunch","dayStartHour":4},"library":{"rotation":"shuffleAll","favorites":[]}}', $utf8)
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'rotation\playback-state.json'), '{"schemaVersion":2,"targets":{"test":{"lastPackId":"demo-garden"}}}', $utf8)
        $watcher=Start-Watcher 'rotation'
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'rotation').Contains('player-finished reason=') } 'rotation play'
        Assert-Order 'rotation' @('pack-chosen id=second-garden rotation=shuffleAll','experience-applied pack=second-garden')
        $report.rotationAvoidsRepeat=$true
        Assert-Order 'rotation' @('first-frame','player-show')
        $report.firstFrameRotationNotWarmed=((Read-Events 'rotation') -split "`n" | Where-Object { $_ -match 'first-frame' } | Select-Object -First 1) -replace '^\S+ ',''
        Stop-Owned $target; Stop-Owned $watcher

        # P-004: a 4:3 target window gets the whole video (fit), the default 16:10 window stays filled.
        Prepare-Pack 'fit43' 8
        $watcher=Start-Watcher 'fit43'
        $target=Start-Owned $fixture @('--window-delay','1.5','--size','800x600')
        Wait-Until { (Read-Events 'fit43').Contains('player-finished reason=') } 'fit43 completion' 30
        Assert-Order 'fit43' @('window-ready','player-move','video-fit mode=fit requested=auto')
        # P-005: the overlay moves onto the window as soon as it is ready, not when the intro ends.
        $lag=((Event-Time 'fit43' 'player-move') - (Event-Time 'fit43' 'window-ready')).TotalSeconds
        if ($lag -gt 0.6) { throw ('Moved to the window '+$lag+'s after it was ready') }
        $report.movesAsSoonAsWindowReady=$true
        $report.narrowWindowShowsWholeVideo=$true
        Stop-Owned $target; Stop-Owned $watcher
        if (-not (Read-Events 'delayed').Contains('video-fit mode=fill requested=auto')) { throw 'Default 16:10 window should stay filled' }
        $report.wideWindowStaysFilled=$true

        # P-009: two apps with their own animations, one at a time, a disabled app never plays.
        $fixtureDir=Split-Path $fixture
        $fixtureB=Join-Path $fixtureDir 'GardenBoot.TestTargetB.exe'; $fixtureC=Join-Path $fixtureDir 'GardenBoot.TestTargetC.exe'
        Copy-Item $fixture $fixtureB -Force; Copy-Item $fixture $fixtureC -Force
        Prepare-Pack 'multi' 4
        $second=Join-Path $OutputRoot 'multi\Packs\second-garden'
        Copy-Item (Join-Path $OutputRoot 'multi\Packs\demo-garden') $second -Recurse
        $m=Get-Content (Join-Path $second 'manifest.json') -Raw | ConvertFrom-Json
        $m.id='second-garden'; $m.name='second'
        [IO.File]::WriteAllText((Join-Path $second 'manifest.json'), ($m | ConvertTo-Json -Depth 5), $utf8)
        $targets=@(
            @{ id='app-a'; name='A'; enabled=$true; animation='demo-garden'; windows=@{ path=$fixture } },
            @{ id='app-b'; name='B'; enabled=$true; animation='second-garden'; windows=@{ path=$fixtureB } },
            @{ id='app-c'; name='C'; enabled=$false; animation=$null; windows=@{ path=$fixtureC } })
        $experience=[ordered]@{ schemaVersion=3; masterVolume=1; muted=$false; packs=@{}; playback=@{ frequency='everyLaunch'; dayStartHour=4 };
                                library=@{ rotation='fixed'; favorites=@() }; targets=$targets }
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'multi\experience.json'), ($experience | ConvertTo-Json -Depth 6), $utf8)
        $watcher=Start-SettingsWatcher 'multi'
        if (-not (Read-Events 'multi').Contains('targets=app-a,app-b') -or (Read-Events 'multi').Contains('app-c')) { throw 'Enabled targets only: ' + (Read-Events 'multi') }
        $a=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'multi').Contains('pack-chosen id=demo-garden rotation=target target=app-a') } 'app A plays its own animation'
        $b=Start-Owned $fixtureB @('--no-window')
        Wait-Until { (Read-Events 'multi').Contains('playback-skipped reason=busy target=app-b') } 'second app while busy'
        Wait-Until { (Read-Events 'multi').Contains('player-finished reason=') } 'app A finished' 20
        Stop-Owned $a; Stop-Owned $b
        Wait-Until { (Read-Events 'multi').Contains('target-exited target=app-b') } 'app B exited'
        $c=Start-Owned $fixtureC @('--no-window')
        $b=Start-Owned $fixtureB @('--no-window')
        Wait-Until { (Read-Events 'multi').Contains('pack-chosen id=second-garden rotation=target target=app-b') } 'app B plays its own animation'
        Wait-Until { ((Read-Events 'multi') -split 'player-finished reason=').Count -ge 3 } 'app B finished' 20
        if ((Read-Events 'multi').Contains('target=app-c')) { throw 'Disabled app C was watched' }
        $state=Get-Content (Join-Path $OutputRoot 'multi\playback-state.json') -Raw | ConvertFrom-Json
        if ($state.targets.'app-a'.lastPackId -ne 'demo-garden' -or $state.targets.'app-b'.lastPackId -ne 'second-garden') { throw 'Per-app state not recorded' }
        $report.perAppAnimationsBusyAndDisabled=$true
        Stop-Owned $b; Stop-Owned $c; Stop-Owned $watcher

        # Opening Sakura again while it runs shows the running copy's settings instead of doing nothing.
        Prepare-Pack 'reopen'
        $watcher=Start-Watcher 'reopen'
        $second=Start-Owned $app @('--test-root',('"'+(Join-Path $OutputRoot 'reopen')+'"'),'--test-target-exe',('"'+$fixture+'"'),'--settings')
        if (-not $second.WaitForExit(5000)) { throw 'Second copy did not exit' }
        Wait-Until { (Read-Events 'reopen').Contains('reopen-requested') -and (Read-Events 'reopen').Contains('settings-opened') } 'running copy shows its settings'
        $report.secondLaunchShowsSettings=$true
        Stop-Owned $watcher

        # P-011: quiet (full-screen) skip, reappear after a tray-style hide, no reappear on minimize, "测试一下" verdicts.
        Prepare-Pack 'quiet' 3
        $watcher=Start-Watcher 'quiet' @('--test-quiet','fullscreen')
        $target=Start-Owned $fixture @('--no-window')
        Wait-Until { (Read-Events 'quiet').Contains('playback-skipped reason=quiet target=test detail=fullscreen') } 'quiet skip'
        if ((Read-Events 'quiet').Contains('player-show')) { throw 'Played while quiet' }
        $report.quietSkipsFullscreen=$true
        Stop-Owned $target; Stop-Owned $watcher

        Prepare-Pack 'reappear' 2
        $watcher=Start-Watcher 'reappear' @('--test-reappear')
        $target=Start-Owned $fixture @('--window-delay','0.3','--hide-after','5','--show-after','3.5')
        Wait-Until { (Read-Events 'reappear').Contains('kind=cold') } 'cold start'
        Wait-Until { (Read-Events 'reappear').Contains('launch-detected target=test kind=reappear') } 'reappear after hide/show' 20
        Wait-Until { ((Read-Events 'reappear') -split 'player-finished reason=').Count -ge 3 } 'reappear playback finished' 20
        $report.reappearAfterTrayHide=$true
        Stop-Owned $target; Stop-Owned $watcher

        Prepare-Pack 'minimize' 2
        $watcher=Start-Watcher 'minimize' @('--test-reappear')
        $target=Start-Owned $fixture @('--window-delay','0.3','--minimize-after','5','--restore-after','3.5')
        Wait-Until { (Read-Events 'minimize').Contains('kind=cold') } 'cold start (minimize scene)'
        Start-Sleep -Seconds 11
        if ((Read-Events 'minimize').Contains('target-reappeared')) { throw 'Restoring a minimized window counted as reappear' }
        $report.minimizeRestoreIgnored=$true
        Stop-Owned $target; Stop-Owned $watcher

        Prepare-Pack 'compat' 6
        $watcher=Start-Watcher 'compat' @('--test-compat','test','--test-compat-seconds','15')
        Wait-Until { (Read-Events 'compat').Contains('compat-start target=test running=false') } 'compat test started'
        $target=Start-Owned $fixture @('--window-delay','1.2')
        Wait-Until { (Read-Events 'compat').Contains('compat-result target=test verdict=good') } 'compat verdict good' 20
        $state=Get-Content (Join-Path $OutputRoot 'compat\playback-state.json') -Raw | ConvertFrom-Json
        if ($state.targets.test.compat.verdict -ne 'good' -or $null -ne $state.targets.test.lastAutoPlayAt) { throw 'Compat result stored without a daily record' }
        Stop-Owned $watcher
        Prepare-Pack 'compat2' 6
        $watcher=Start-Watcher 'compat2' @('--test-compat','test','--test-compat-seconds','4')
        Wait-Until { (Read-Events 'compat2').Contains('compat-result target=test verdict=alreadyRunning') } 'compat verdict alreadyRunning' 12
        $report.compatGoodAndAlreadyRunning=$true
        Stop-Owned $target; Stop-Owned $watcher

        # P-013: a video becomes a single-video pack through the normal import checks; a corrupt one changes nothing.
        $clip=Join-Path $OutputRoot 'night_garden-clip.MOV'
        Copy-Item (Join-Path $demo 'outro.mp4') $clip
        Prepare-Pack 'video-pack' 6
        $watcher=Start-Watcher 'video-pack' @('--test-create-video',('"'+$clip+'"'))
        Wait-Until { (Read-Events 'video-pack') -match 'pack-created-from-video id=(video-[0-9a-f]{8})' } 'pack created from video' 20
        # $Matches from inside Wait-Until's script block is not visible here; match again in this scope.
        if (-not ((Read-Events 'video-pack') -match 'pack-created-from-video id=(video-[0-9a-f]{8})')) { throw 'Lost created pack id' }
        $created=$Matches[1]
        $manifest=Get-Content (Join-Path $OutputRoot ('video-pack\Packs\' + $created + '\manifest.json')) -Raw | ConvertFrom-Json
        if ($manifest.name -ne 'night garden clip' -or $manifest.segments.video -ne 'video.mov') { throw ('Unexpected manifest: ' + ($manifest | ConvertTo-Json -Compress)) }
        # The success line is written just before the staging folder is removed; allow that cleanup to finish.
        Wait-Until { -not (Get-ChildItem (Join-Path $OutputRoot 'video-pack\Packs') -Directory -Force -Filter '.video-*') } 'staging folder removed' 5
        Stop-Owned $watcher
        $broken=Join-Path $OutputRoot 'broken.mp4'
        [IO.File]::WriteAllText($broken, 'not a video')
        Prepare-Pack 'video-pack-bad' 6
        $watcher=Start-Watcher 'video-pack-bad' @('--test-create-video',('"'+$broken+'"'))
        Wait-Until { (Read-Events 'video-pack-bad').Contains('pack-create-failed') } 'corrupt video rejected' 20
        if (Get-ChildItem (Join-Path $OutputRoot 'video-pack-bad\Packs') -Directory -Filter 'video-*') { throw 'Corrupt video entered the library' }
        $report.createPackFromVideo=$created
        Stop-Owned $watcher

        # Featured built-in pack: installed once, made current when nothing was chosen; removal is respected.
        Prepare-Pack 'featured' 6
        Remove-Item (Join-Path $OutputRoot 'featured\settings.json')
        $watcher=Start-Watcher 'featured' @('--test-featured')
        Wait-Until { (Read-Events 'featured').Contains('featured-made-current id=raiden-garden') } 'featured install' 60
        Wait-Until { (Read-Events 'featured').Contains('active=raiden-garden') } 'featured becomes current' 20
        if (-not (Test-Path (Join-Path $OutputRoot 'featured\Packs\raiden-garden\manifest.json'))) { throw 'Featured pack missing' }
        Stop-Owned $watcher
        Remove-Item (Join-Path $OutputRoot 'featured\Packs\raiden-garden') -Recurse -Force
        $watcher=Start-Watcher 'featured' @('--test-featured')
        Start-Sleep -Seconds 4
        if (([regex]::Matches((Read-Events 'featured'), 'featured=true')).Count -ne 1) { throw 'Removed featured pack came back' }
        $report.featuredInstalledOnce=$true
        Stop-Owned $watcher
    }
    $report.status='passed'; $report.passed=$true
} catch {
    $report.status='failed'; $report.error=$_.Exception.Message
    if ($report.error -like '*foreground application change*') { $report.status='interrupted' }
} finally {
    foreach ($child in $children) { try { Stop-Owned $child } catch {} }
    Save-Report
}
if (-not $report.passed) { exit 1 }
