#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ZxpPath,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SignToolPath = (Join-Path $PSScriptRoot 'ZXPSignCmd.exe')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zxp_common.ps1')

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$signTool = [System.IO.Path]::GetFullPath($SignToolPath)

if (-not (Test-Path -LiteralPath $signTool -PathType Leaf)) {
    throw "ZXPSignCmd.exe was not found. Set its path in ZXP Manager: $signTool"
}

if ([string]::IsNullOrWhiteSpace($ZxpPath)) {
    $manifestPath = Join-Path $projectRoot 'CSXS\manifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Project manifest was not found: $manifestPath"
    }

    $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectRoot
    $packageFileName = Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $projectMetadata.Version
    $managedPackage = Join-Path (Join-Path $projectRoot 'zxp_packages') $packageFileName
    $legacyPackage = Join-Path (Join-Path (Join-Path $projectRoot 'staging') (Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $projectMetadata.Version)) $packageFileName
    $ZxpPath = if (Test-Path -LiteralPath $managedPackage -PathType Leaf) { $managedPackage } else { $legacyPackage }
}

$ZxpPath = [System.IO.Path]::GetFullPath($ZxpPath)
if (-not (Test-Path -LiteralPath $ZxpPath -PathType Leaf)) {
    throw "ZXP package was not found: $ZxpPath"
}
if ([System.IO.Path]::GetExtension($ZxpPath) -ine '.zxp') {
    throw "Expected a .zxp package: $ZxpPath"
}

$verificationOutput = @(& $signTool -verify $ZxpPath -certinfo 2>&1)
$verificationExitCode = $LASTEXITCODE
$verificationText = $verificationOutput -join [Environment]::NewLine
if ($verificationText) {
    Write-Host $verificationText
}

if ($verificationExitCode -ne 0) {
    throw "ZXPSignCmd verification failed with exit code $verificationExitCode."
}
if ($verificationText -notmatch '(?im)^Timestamp:\s*Valid\b') {
    throw 'The ZXP signature did not report a valid timestamp.'
}
if ($verificationText -notmatch '(?im)^Signature verified successfully\s*$') {
    throw 'ZXPSignCmd did not report successful signature verification.'
}

$certificateSerial = Get-ZxpSigningCertificateSerial -ZxpPath $ZxpPath
Write-Host "Signing certificate serial number: $certificateSerial" -ForegroundColor Cyan
Write-Host "ZXP signature and timestamp verified: $ZxpPath" -ForegroundColor Green
