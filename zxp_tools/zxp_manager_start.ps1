#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$guiPath = Join-Path $PSScriptRoot 'zxp_manager_gui.ps1'

try {
    if ($ValidateOnly) {
        & $guiPath -ValidateOnly
    }
    else {
        & $guiPath
    }
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        $_.Exception.ToString(),
        'ZXP Manager failed to start',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
