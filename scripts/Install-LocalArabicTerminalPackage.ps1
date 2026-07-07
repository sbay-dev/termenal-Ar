param(
    [string]$PackageRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$root = (Resolve-Path $PackageRoot).Path

$msix = Get-ChildItem $root -Recurse -Filter "CascadiaPackage_*.msix" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $msix) {
    throw "No CascadiaPackage MSIX file was found under '$root'."
}

$dependency = Get-ChildItem $root -Recurse -Filter "Microsoft.UI.Xaml.2.8.appx" -File |
    Where-Object { $_.FullName -match "\\Dependencies\\x64\\" } |
    Select-Object -First 1

if (-not $dependency) {
    throw "The x64 Microsoft.UI.Xaml.2.8 dependency was not found under '$root'."
}

Write-Host "Installing Arabic RTL Terminal from:"
Write-Host "  $($msix.FullName)"

Add-AppxPackage -Path $msix.FullName -DependencyPath $dependency.FullName -ForceApplicationShutdown

Write-Host "Arabic RTL Terminal installed successfully."
