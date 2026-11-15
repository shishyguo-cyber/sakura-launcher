# Release publish of Sakura for Windows x64 (framework-dependent: needs the .NET 10 Desktop Runtime).
#   powershell -ExecutionPolicy Bypass -File launcher-windows\scripts\publish-release.ps1 -Output <new folder> [-Offline]
# -Offline restores from an empty local package source, proving nothing is downloaded (the app has no NuGet
#  dependencies; it only needs the SDK's reference and app-host packs).
# A full rebuild with debug information turned off: an incremental publish once reused an older DLL that still
# carried the builder's PDB path. Deterministic + CI build settings also map source paths.
param(
    [Parameter(Mandatory)] [string] $Output,
    [switch] $Offline
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$project = Join-Path (Split-Path $PSScriptRoot -Parent) 'GardenBoot.App\GardenBoot.App.csproj'
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path $Output) { throw "Output already exists; choose a new folder: $Output" }

$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'false',
            '-p:DebugType=none', '-p:DebugSymbols=false', '-p:Deterministic=true', '-p:ContinuousIntegrationBuild=true')
$restore = @()
if ($Offline) {
    $empty = Join-Path ([IO.Path]::GetTempPath()) ('sakura-empty-nuget-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty | Out-Null
    $restore = @('--source', $empty)
}
try {
    dotnet build $project @common @restore '-t:Rebuild'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dotnet publish $project @common --no-build -o $Output
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if ($Offline -and (Test-Path $empty)) { Remove-Item $empty -Recurse -Force }
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
