param(
    [string]$Version = "v0.0.1.22-rtl-ar",
    [string]$InstallRoot = (Join-Path $env:TEMP "WindowsTerminalDev-ArabicRTL")
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

$repo = "sbay-dev/termenal-Ar"
$assetName = "WindowsTerminalDev-ArabicRTL-0.0.1.22-x64.zip"
$downloadUrl = "https://github.com/$repo/releases/download/$Version/$assetName"
$zipPath = Join-Path $InstallRoot $assetName
$extractPath = Join-Path $InstallRoot "extracted"

Remove-Item $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

Write-Host "Downloading Arabic RTL Terminal release $Version..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

Write-Host "Extracting package..."
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
Get-ChildItem $extractPath -Recurse -File | Unblock-File

$installScript = Get-ChildItem $extractPath -Recurse -Filter "Install-LocalArabicTerminalPackage.ps1" -File |
    Select-Object -First 1

if ($installScript) {
    & $installScript.FullName -PackageRoot $installScript.DirectoryName
    exit $LASTEXITCODE
}

$msix = Get-ChildItem $extractPath -Recurse -Filter "CascadiaPackage_*.msix" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $msix) {
    throw "No MSIX package was found in the release archive."
}

$dependency = Get-ChildItem $extractPath -Recurse -Filter "Microsoft.UI.Xaml.2.8.appx" -File |
    Where-Object { $_.FullName -match "\\Dependencies\\x64\\" } |
    Select-Object -First 1

if (-not $dependency) {
    throw "The x64 Microsoft.UI.Xaml dependency was not found in the release archive."
}

Write-Host "Installing Arabic RTL Terminal..."
Add-AppxPackage -Path $msix.FullName -DependencyPath $dependency.FullName -ForceApplicationShutdown

Write-Host "Arabic RTL Terminal installed successfully."
