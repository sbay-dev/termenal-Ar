<#
.SYNOPSIS
Applies the RTL-VT Arabic Atlas renderer solution to a Windows Terminal checkout.

.DESCRIPTION
This helper copies the current RTL/Arabic renderer files from a patched source
checkout into a target Windows Terminal checkout. By default it copies only the
renderer files that are suitable for a focused upstream contribution.

Private OpenConsole defaults and local command-line build fixes are opt-in.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tools\Apply-RTLArabicSupport.ps1 -CheckOnly

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tools\Apply-RTLArabicSupport.ps1 `
  -SourceRoot X:\source\windows-terminal-arabic `
  -RepositoryRoot X:\source\terminal-clean `
  -Branch rtl-arabic-atlas-support
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot,
    [string]$RepositoryRoot,
    [string]$Branch = 'rtl-arabic-atlas-support',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Platform = 'x64',
    [switch]$NoBranch,
    [switch]$AllowDirty,
    [switch]$CheckOnly,
    [switch]$BuildOpenConsole,
    [switch]$IncludeOpenConsoleDefaults,
    [switch]$IncludeBuildFixes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Find-GitRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    $root = (& git -C $StartPath rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $root) {
        return (Resolve-ExistingPath $root.Trim())
    }

    return (Resolve-ExistingPath $StartPath)
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $Root`: git $($Arguments -join ' ')"
    }
}

function Assert-TerminalCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $required = @(
        'src\renderer\atlas\AtlasEngine.cpp',
        'src\renderer\atlas\AtlasEngine.h',
        'src\renderer\atlas\DWriteTextAnalysis.cpp',
        'src\renderer\atlas\DWriteTextAnalysis.h',
        'src\renderer\atlas\common.h',
        'tools\OpenConsole.psm1'
    )

    foreach ($relative in $required) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Not a compatible Windows Terminal checkout. Missing: $relative"
        }
    }
}

function Assert-SourceMarkers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $checks = @{
        'src\renderer\atlas\DWriteTextAnalysis.cpp' = @('IsStrongRtlChar', 'HasAnyStrongRtl', 'AnalyzeBidi', 'SetBidiLevel')
        'src\renderer\atlas\DWriteTextAnalysis.h' = @('HasAnyStrongRtl', 'bidiResults')
        'src\renderer\atlas\AtlasEngine.cpp' = @('runIsRtl', 'HasAnyStrongRtl', 'row.rtl', 'isRightToLeft')
        'src\renderer\atlas\AtlasEngine.h' = @('bidiResults')
        'src\renderer\atlas\common.h' = @('BidiAnalysisSinkResult', 'bool rtl')
        'src\cascadia\TerminalControl\ControlCore.cpp' = @('rtlvtVisualToLogicalColumn', '_repositionCursorWithMouse')
    }

    foreach ($relative in $checks.Keys) {
        $path = Join-Path $Root $relative
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($marker in $checks[$relative]) {
            if ($text.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
                throw "Source checkout does not contain RTL Arabic marker '$marker' in $relative"
            }
        }
    }
}

function Test-DirtyGitTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $status = (& git -C $Root status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return [bool]$status
}

function Switch-ContributionBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    $current = (& git -C $Root branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return
    }

    if ($current.Trim() -eq $Name) {
        return
    }

    $existing = (& git -C $Root branch --list $Name)
    if ($existing) {
        Invoke-Git -Root $Root -Arguments @('switch', $Name)
    } else {
        Invoke-Git -Root $Root -Arguments @('switch', '-c', $Name)
    }
}

function Copy-SolutionFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [switch]$AllowNew
    )

    $source = Join-Path $SourceRoot $RelativePath
    $target = Join-Path $RepositoryRoot $RelativePath

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source file missing: $RelativePath"
    }

    if (-not (Test-Path -LiteralPath $target)) {
        if (-not $AllowNew) {
            throw "Target file missing: $RelativePath"
        }
        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        }
    }

    if ($CheckOnly) {
        Write-Host "OK: $RelativePath"
        return
    }

    $resolvedSource = (Resolve-Path -LiteralPath $source).ProviderPath
    $resolvedTarget = if (Test-Path -LiteralPath $target) { (Resolve-Path -LiteralPath $target).ProviderPath } else { $target }

    if ($resolvedSource -ieq $resolvedTarget) {
        Write-Host "Already in target: $RelativePath"
        return
    }

    if ($PSCmdlet.ShouldProcess($target, "copy RTL Arabic solution file")) {
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host "Applied: $RelativePath"
    }
}

$scriptRoot = Get-ScriptRoot
if (-not $SourceRoot) {
    $SourceRoot = Join-Path $scriptRoot '..'
}
if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $scriptRoot '..'
}

$SourceRoot = Find-GitRoot (Resolve-ExistingPath $SourceRoot)
$RepositoryRoot = Find-GitRoot (Resolve-ExistingPath $RepositoryRoot)

Assert-TerminalCheckout -Root $SourceRoot
Assert-TerminalCheckout -Root $RepositoryRoot
Assert-SourceMarkers -Root $SourceRoot

$coreFiles = @(
    'src\renderer\atlas\common.h',
    'src\renderer\atlas\DWriteTextAnalysis.h',
    'src\renderer\atlas\DWriteTextAnalysis.cpp',
    'src\renderer\atlas\AtlasEngine.h',
    'src\renderer\atlas\AtlasEngine.cpp',
    'src\cascadia\TerminalControl\ControlCore.cpp'
)

$files = New-Object System.Collections.Generic.List[string]
$coreFiles | ForEach-Object { [void]$files.Add($_) }

if ($IncludeOpenConsoleDefaults) {
    [void]$files.Add('src\host\settings.cpp')
}

if ($IncludeBuildFixes) {
    [void]$files.Add('src\cppwinrt.build.pre.props')
    [void]$files.Add('src\cascadia\TerminalSettingsEditor\Microsoft.Terminal.Settings.Editor.vcxproj')
}

if (-not $CheckOnly) {
    if ((Test-DirtyGitTree -Root $RepositoryRoot) -and -not $AllowDirty) {
        throw "Target checkout has uncommitted changes. Commit/stash them or pass -AllowDirty."
    }

    if (-not $NoBranch) {
        Switch-ContributionBranch -Root $RepositoryRoot -Name $Branch
    }
}

foreach ($relative in $files) {
    Copy-SolutionFile -RelativePath $relative
}

if (-not $CheckOnly) {
    Invoke-Git -Root $RepositoryRoot -Arguments @('diff', '--check')
}

if ($BuildOpenConsole) {
    if ($CheckOnly) {
        throw '-BuildOpenConsole cannot be combined with -CheckOnly.'
    }

    $modulePath = Join-Path $RepositoryRoot 'tools\OpenConsole.psm1'
    Import-Module $modulePath -Force
    Set-MsBuildDevEnvironment

    $solution = Join-Path $RepositoryRoot 'conhost.slnf'
    & msbuild $solution "/p:Configuration=$Configuration" "/p:Platform=$Platform" /m /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) {
        throw "OpenConsole build failed."
    }
}

Write-Host "RTL Arabic support application completed."
