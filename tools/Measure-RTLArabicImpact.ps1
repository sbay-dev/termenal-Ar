<#
.SYNOPSIS
Measures size and local build-time impact for the RTL Arabic contribution.

.DESCRIPTION
Builds a patched checkout and, unless -CurrentOnly is supplied, a detached
baseline worktree from -BaselineRef. It then compares selected renderer/control
artifacts by byte size.

The script intentionally reports raw numbers only. It does not decide whether a
delta is acceptable; that belongs in PR review.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$BaselineRef = 'origin/main',
    [string]$BaselineRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Platform = 'x64',
    [switch]$CurrentOnly,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Find-GitRoot {
    param([Parameter(Mandatory = $true)][string]$StartPath)
    $root = (& git -C $StartPath rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        throw "Not a git checkout: $StartPath"
    }
    return (Resolve-ExistingPath $root.Trim())
}

function Invoke-MSBuild {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$MsBuildPath,
        [string]$VcpkgRoot
    )

    $args = @(
        (Join-Path $Root $Project),
        "/p:Configuration=$Configuration",
        "/p:Platform=$Platform",
        "/p:SolutionDir=$Root\",
        '/p:WholeProgramOptimization=false',
        '/p:LinkTimeCodeGeneration=Default',
        '/m:1',
        '/v:minimal',
        '/nologo'
    )

    if ($VcpkgRoot) {
        $args += "/p:VcpkgRoot=$VcpkgRoot\"
    }

    & $MsBuildPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed for $Project in $Root"
    }
}

function Build-AffectedProjects {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$MsBuildPath,
        [string]$VcpkgRoot
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-MSBuild -Root $Root -Project 'src\renderer\atlas\atlas.vcxproj' -MsBuildPath $MsBuildPath -VcpkgRoot $VcpkgRoot
    Invoke-MSBuild -Root $Root -Project 'src\cascadia\TerminalControl\TerminalControlLib.vcxproj' -MsBuildPath $MsBuildPath -VcpkgRoot $VcpkgRoot
    Invoke-MSBuild -Root $Root -Project 'src\cascadia\TerminalControl\dll\TerminalControl.vcxproj' -MsBuildPath $MsBuildPath -VcpkgRoot $VcpkgRoot
    $sw.Stop()
    return $sw.Elapsed
}

function Get-ArtifactSizes {
    param([Parameter(Mandatory = $true)][string]$Root)

    $releaseRoot = Join-Path $Root "bin\$Platform\$Configuration"
    $relative = @(
        'ConRenderAtlas.lib',
        'Microsoft.Terminal.Control.Lib\Microsoft.Terminal.ControlLib.lib',
        'Microsoft.Terminal.Control\Microsoft.Terminal.Control.dll'
    )

    foreach ($path in $relative) {
        $full = Join-Path $releaseRoot $path
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full
            [pscustomobject]@{
                Artifact = $path
                Bytes = $item.Length
                MiB = [math]::Round($item.Length / 1MB, 3)
                LastWriteTime = $item.LastWriteTime
            }
        } else {
            [pscustomobject]@{
                Artifact = $path
                Bytes = $null
                MiB = $null
                LastWriteTime = $null
            }
        }
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}

$RepositoryRoot = Find-GitRoot (Resolve-ExistingPath $RepositoryRoot)
$msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild not found: $msbuild"
}

$vcpkgRoot = Join-Path $RepositoryRoot 'dep\vcpkg'
if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot 'scripts\buildsystems\msbuild\vcpkg.props'))) {
    $vcpkgRoot = $null
}

if (-not $SkipBuild) {
    $currentElapsed = Build-AffectedProjects -Root $RepositoryRoot -MsBuildPath $msbuild -VcpkgRoot $vcpkgRoot
} else {
    $currentElapsed = [TimeSpan]::Zero
}

$current = @(Get-ArtifactSizes -Root $RepositoryRoot)

if ($CurrentOnly) {
    [pscustomobject]@{
        Root = $RepositoryRoot
        BuildSeconds = [math]::Round($currentElapsed.TotalSeconds, 2)
    }
    $current | Format-Table -AutoSize
    return
}

if (-not $BaselineRoot) {
    $BaselineRoot = Join-Path (Split-Path -Parent $RepositoryRoot) 'windows-terminal-rtl-baseline'
}

if (-not (Test-Path -LiteralPath $BaselineRoot)) {
    & git -C $RepositoryRoot fetch origin --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'git fetch failed'
    }
    & git -C $RepositoryRoot worktree add --detach $BaselineRoot $BaselineRef
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed for $BaselineRef"
    }
}

foreach ($name in @('packages', 'dep\vcpkg')) {
    $source = Join-Path $RepositoryRoot $name
    $target = Join-Path $BaselineRoot $name
    if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $target)) {
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    }
}

if (-not $SkipBuild) {
    $baselineElapsed = Build-AffectedProjects -Root $BaselineRoot -MsBuildPath $msbuild -VcpkgRoot $vcpkgRoot
} else {
    $baselineElapsed = [TimeSpan]::Zero
}

$baseline = @(Get-ArtifactSizes -Root $BaselineRoot)

[pscustomobject]@{
    CurrentRoot = $RepositoryRoot
    BaselineRoot = $BaselineRoot
    BaselineRef = $BaselineRef
    CurrentBuildSeconds = [math]::Round($currentElapsed.TotalSeconds, 2)
    BaselineBuildSeconds = [math]::Round($baselineElapsed.TotalSeconds, 2)
}

$comparison = foreach ($artifact in $current.Artifact) {
    $c = $current | Where-Object Artifact -eq $artifact | Select-Object -First 1
    $b = $baseline | Where-Object Artifact -eq $artifact | Select-Object -First 1
    [pscustomobject]@{
        Artifact = $artifact
        BaselineBytes = $b.Bytes
        CurrentBytes = $c.Bytes
        DeltaBytes = if ($null -ne $b.Bytes -and $null -ne $c.Bytes) { $c.Bytes - $b.Bytes } else { $null }
        DeltaPercent = if ($b.Bytes) { [math]::Round((($c.Bytes - $b.Bytes) / $b.Bytes) * 100, 3) } else { $null }
    }
}

$comparison | Format-Table -AutoSize
