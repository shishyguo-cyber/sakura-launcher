# Release publish of Sakura for Windows x64: self-contained folder, no trimming or single-file EXE.
#   powershell -ExecutionPolicy Bypass -File launcher-windows\scripts\publish-release.ps1 -Output <new folder> -RuntimeVersion <10.0.patch> [-Offline -OfflineSource <local feed>]
# -Offline uses only a pre-provisioned, repository-external folder of .nupkg files, never an empty source.
# Prepare Microsoft.NETCore.App.Runtime.win-x64 and Microsoft.WindowsDesktop.App.Runtime.win-x64 at the
# requested RuntimeVersion first; see docs/DEVELOPMENT.md. Check the actual non-IPE route BEFORE downloading.
# SDK reference packs must be installed. An older SDK may also need Microsoft.NETCore.App.Host.win-x64
# at RuntimeVersion in the feed. No downloads are performed by -Offline.
# Runtime security fixes require updating RuntimeVersion, rebuilding and redistributing Sakura.
# A full rebuild with debug information turned off avoids reusing DLLs with the builder's PDB path.
param(
    [Parameter(Mandatory)] [string] $Output,
    [Parameter(Mandatory)] [ValidatePattern('^10\.0\.[0-9]+$')] [string] $RuntimeVersion,
    [switch] $Offline,
    [string] $OfflineSource
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$project = Join-Path (Split-Path $PSScriptRoot -Parent) 'GardenBoot.App\GardenBoot.App.csproj'
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path $Output) { throw "Output already exists; choose a new folder: $Output" }
if ($OfflineSource -and -not $Offline) { throw 'OfflineSource requires -Offline' }

$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
            "-p:RuntimeFrameworkVersion=$RuntimeVersion", '-p:PublishTrimmed=false', '-p:PublishSingleFile=false',
            '-p:DebugType=none', '-p:DebugSymbols=false', '-p:Deterministic=true', '-p:ContinuousIntegrationBuild=true',
            '-p:NuGetAudit=false')
$restore = @()
$cache = $null
if ($Offline) {
    if (-not $OfflineSource -or -not (Test-Path $OfflineSource -PathType Container)) {
        throw 'Pass -OfflineSource <pre-provisioned .nupkg folder outside the repository>; see docs/DEVELOPMENT.md'
    }
    $OfflineSource = (Resolve-Path $OfflineSource).Path
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
    if ($OfflineSource -eq $repo -or $OfflineSource.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OfflineSource must be outside the repository (do not commit runtime packages)'
    }
    foreach ($id in @('Microsoft.NETCore.App.Runtime.win-x64', 'Microsoft.WindowsDesktop.App.Runtime.win-x64')) {
        $package = Join-Path $OfflineSource "$id.$RuntimeVersion.nupkg"
        if (-not (Test-Path $package -PathType Leaf)) { throw "Missing offline package: $id $RuntimeVersion" }
    }
    $dotnetRoot = Split-Path (Get-Command dotnet -ErrorAction Stop).Source -Parent
    $hostPack = Join-Path $dotnetRoot "packs\Microsoft.NETCore.App.Host.win-x64\$RuntimeVersion"
    $hostPackage = Join-Path $OfflineSource "Microsoft.NETCore.App.Host.win-x64.$RuntimeVersion.nupkg"
    if (-not (Test-Path $hostPack -PathType Container) -and -not (Test-Path $hostPackage -PathType Leaf)) {
        throw "SDK lacks the matching app-host pack; provision Microsoft.NETCore.App.Host.win-x64 $RuntimeVersion in OfflineSource"
    }
    # A fresh cache prevents a warm global NuGet cache from hiding an incomplete offline feed.
    # Keep all writes beside the requested output, including when running in a restricted build root.
    $cache = Join-Path (Split-Path $Output -Parent) ('.sakura-nuget-' + [Guid]::NewGuid().ToString('N'))
    $common += "-p:RestorePackagesPath=$cache"
    $restore = @('--source', $OfflineSource)
}
try {
    dotnet build $project @common @restore '-t:Rebuild'
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed: $LASTEXITCODE" }
    dotnet publish $project @common --no-build --no-restore -o $Output
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed: $LASTEXITCODE" }
} finally {
    if ($cache -and (Test-Path $cache)) { Remove-Item $cache -Recurse -Force }
}

# Fail if a framework-dependent/incomplete directory was accidentally handed to the packager.
foreach ($required in @('Sakura.exe', 'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'PresentationFramework.dll')) {
    if (-not (Test-Path (Join-Path $Output $required) -PathType Leaf)) { throw "Missing self-contained file: $required" }
}
$config = Get-Content (Join-Path $Output 'Sakura.runtimeconfig.json') -Raw | ConvertFrom-Json
$frameworks = @($config.runtimeOptions.includedFrameworks)
foreach ($name in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
    if (-not ($frameworks | Where-Object { $_.name -eq $name -and $_.version -eq $RuntimeVersion })) {
        throw "Runtime version mismatch: $name must be $RuntimeVersion"
    }
}

Get-ChildItem $Output -Recurse -Filter *.pdb | Remove-Item -Force
$leaks = foreach ($file in Get-ChildItem $Output -Recurse -File -Include *.dll, *.exe) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $wide = [Text.Encoding]::Unicode.GetString($bytes)
    if ($ascii -match '[A-Za-z]:\\Users\\' -or $wide -match '[A-Za-z]:\\Users\\') { $file.Name }
}
if ($leaks) { throw ('Builder paths remain in: ' + ($leaks -join ', ')) }
Write-Output "Published to $Output"
$total = (Get-ChildItem $Output -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Output "Self-contained runtime $RuntimeVersion; directory bytes: $total; builder-path scan: clean"
