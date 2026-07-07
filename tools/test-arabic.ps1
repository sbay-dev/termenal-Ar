# RTL-VT visual launcher for the patched OpenConsole (Phase 1A+1B).
#
# This file intentionally stays ASCII-only. Arabic sample text is assembled
# from Unicode codepoints in memory, then passed to the inner PowerShell via
# -EncodedCommand (Base64 UTF-16LE). That avoids cmd/OEM/ANSI/UTF-8-BOM
# decoding problems such as "???", or mojibake like "ظ...".

param(
    [ValidateSet("cmd", "powershell")]
    [string]$Shell = "powershell",
    [switch]$Sample
)

$ErrorActionPreference = "Stop"

$exe = Join-Path $PSScriptRoot "..\bin\x64\Debug\OpenConsole.exe"
if (-not (Test-Path $exe)) {
    throw "OpenConsole.exe not found at $exe"
}

function U {
    param([int[]]$Codepoints)
    -join ($Codepoints | ForEach-Object { [char]$_ })
}

function Q {
    param([string]$Text)
    "'" + $Text.Replace("'", "''") + "'"
}

function Add-Line {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Text
    )
    [void]$Lines.Add("Write-Host " + (Q $Text))
}

function Start-OpenConsolePowerShell {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [switch]$NoExit
    )

    $body = $Lines -join "`r`n"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))

    $args = "powershell -NoProfile -ExecutionPolicy Bypass "
    if ($NoExit) {
        $args += "-NoExit "
    }
    $args += "-EncodedCommand $encoded"

    Start-Process -FilePath $exe -ArgumentList $args
}

if ($Sample) {
    $marhaba = U @(0x0645,0x0631,0x062D,0x0628,0x0627)
    $alalam = U @(0x0628,0x0627,0x0644,0x0639,0x0627,0x0644,0x0645)
    $min = U @(0x0645,0x0646)
    $terminal = U @(0x0627,0x0644,0x0637,0x0631,0x0641,0x064A,0x0629)
    $arabic = U @(0x0627,0x0644,0x0639,0x0631,0x0628,0x064A,0x0629)
    $salam = U @(0x0633,0x0644,0x0627,0x0645)
    $ikhtibar = U @(0x0627,0x062E,0x062A,0x0628,0x0627,0x0631)
    $kataba = U @(0x0643,0x062A,0x0628)
    $katib = U @(0x0643,0x0627,0x062A,0x0628)
    $maktub = U @(0x0645,0x0643,0x062A,0x0648,0x0628)
    $kitab = U @(0x0643,0x062A,0x0627,0x0628)
    $isolated = (U @(0x0643)) + " " + (U @(0x062A)) + " " + (U @(0x0628))

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8")
    [void]$lines.Add('$OutputEncoding = [System.Text.Encoding]::UTF8')
    [void]$lines.Add("chcp 65001 | Out-Null")

    Add-Line $lines "=== Phase 1A+1B Arabic sample ==="
    Add-Line $lines ""
    Add-Line $lines "Pure RTL paragraph:"
    Add-Line $lines "  $marhaba $alalam $min $terminal $arabic"
    Add-Line $lines ""
    Add-Line $lines "Mixed LTR + RTL with numbers and punctuation:"
    Add-Line $lines "  Hello $alalam 2026 [test] ($salam) 99%"
    Add-Line $lines ""
    Add-Line $lines "Punctuation-heavy:"
    Add-Line $lines "  `"$arabic`" : { `"$ikhtibar`" , 42 }"
    Add-Line $lines ""
    Add-Line $lines "Joined-form check:"
    Add-Line $lines "  $kataba  $katib  $maktub  $kitab"
    Add-Line $lines ""
    Add-Line $lines "Isolated vs joined comparison:"
    Add-Line $lines "  isolated (spaces between letters):"
    Add-Line $lines "  $isolated"
    Add-Line $lines "  joined (letters should connect):"
    Add-Line $lines "  $kataba"
    Add-Line $lines ""
    Add-Line $lines "Press Enter to close..."
    [void]$lines.Add("[void](Read-Host)")

    Write-Host "Launching OpenConsole Arabic sample through EncodedCommand..."
    Start-OpenConsolePowerShell -Lines $lines
}
elseif ($Shell -eq "powershell") {
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8")
    [void]$lines.Add('$OutputEncoding = [System.Text.Encoding]::UTF8')
    [void]$lines.Add("chcp 65001 | Out-Null")
    Add-Line $lines "RTL-VT patched OpenConsole. Paste or type Arabic now."
    Start-OpenConsolePowerShell -Lines $lines -NoExit
}
else {
    Start-Process -FilePath $exe -ArgumentList "cmd /k chcp 65001"
}
