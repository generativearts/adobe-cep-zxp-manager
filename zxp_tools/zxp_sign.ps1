#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]+$')]
    [string]$CertificateSerial,

    [string]$TimestampUrl = 'http://time.certum.pl/',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$StagingDirectory,
    [string]$OutputPath,
    [string]$CertificatesDirectory,
    [string]$SignToolPath = (Join-Path $PSScriptRoot 'ZXPSignCmd.exe')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zxp_common.ps1')

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$signTool = [System.IO.Path]::GetFullPath($SignToolPath)
if ([string]::IsNullOrWhiteSpace($CertificatesDirectory)) {
    $CertificatesDirectory = Join-Path $projectRoot 'certificates'
}
$certificatesDirectory = [System.IO.Path]::GetFullPath($CertificatesDirectory)
$manifestPath = Join-Path $projectRoot 'CSXS\manifest.xml'

if (-not (Test-Path -LiteralPath $signTool -PathType Leaf)) {
    throw "ZXPSignCmd.exe was not found. Set its path in ZXP Manager: $signTool"
}
foreach ($requiredPath in @($manifestPath, $certificatesDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required signing input not found: $requiredPath"
    }
}
if (-not [Uri]::IsWellFormedUriString($TimestampUrl, [UriKind]::Absolute) -or
    ([Uri]$TimestampUrl).Scheme -notin @('http', 'https')) {
    throw "Timestamp URL must be an absolute HTTP or HTTPS URL: $TimestampUrl"
}

$projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectRoot
$projectVersion = $projectMetadata.Version

$releaseDirectory = Join-Path (Join-Path $projectRoot 'staging') (Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $projectVersion)
if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
    $StagingDirectory = Join-Path $releaseDirectory 'staging'
}
$stagingDirectory = [System.IO.Path]::GetFullPath($StagingDirectory)
$stagedManifestPath = Join-Path $stagingDirectory 'CSXS\manifest.xml'
$serial = $CertificateSerial.ToUpperInvariant()
$certificatePath = Join-Path $certificatesDirectory "$serial.p12"
$passwordPath = Join-Path $certificatesDirectory "$serial.password.txt"

foreach ($requiredPath in @($stagingDirectory, $stagedManifestPath, $certificatePath, $passwordPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Required signing input not found: $requiredPath"
    }
}

[xml]$stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw
$version = [string]$stagedManifest.ExtensionManifest.GetAttribute('ExtensionBundleVersion')
if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
    throw "Staging manifest contains an invalid release version: '$version'."
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $projectRoot 'zxp_packages') (Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $version)
}
$outputPath = [System.IO.Path]::GetFullPath($OutputPath)

if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to overwrite an existing ZXP package: $outputPath"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null

$password = Get-Content -LiteralPath $passwordPath -Raw
if ([string]::IsNullOrWhiteSpace($password)) {
    throw "The password file is empty: $passwordPath"
}

$certificate = $null
try {
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath,
        $password,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )
    if ($certificate.SerialNumber -ne $serial) {
        throw "Certificate serial number does not match the requested serial $serial."
    }

    & $signTool `
        -sign `
        $stagingDirectory `
        $outputPath `
        $certificatePath `
        $password `
        -tsa $TimestampUrl

    if ($LASTEXITCODE -ne 0) {
        throw "ZXPSignCmd failed to sign the ZXP package (exit code $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'ZXPSignCmd reported success but did not create the ZXP package.'
    }
    if ((Get-Item -LiteralPath $outputPath).Length -le 0) {
        Remove-Item -LiteralPath $outputPath -Force
        throw 'ZXPSignCmd created an empty ZXP package.'
    }

    & (Join-Path $PSScriptRoot 'zxp_sign_verify.ps1') -ZxpPath $outputPath -ProjectRoot $projectRoot
}
catch {
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    throw
}
finally {
    if ($certificate) {
        $certificate.Dispose()
    }
    $password = $null
}

Write-Host 'ZXP package created and signed with a timestamp request.' -ForegroundColor Green
Write-Host "Version: $version" -ForegroundColor Cyan
Write-Host "Certificate serial: $serial" -ForegroundColor Cyan
Write-Host "Package: $outputPath" -ForegroundColor Cyan
Write-Host 'Signature and timestamp verification completed successfully.' -ForegroundColor Green
