#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CertificatesDirectory,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SignToolPath = (Join-Path $PSScriptRoot 'ZXPSignCmd.exe')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zxp_common.ps1')

function Set-RestrictedFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $accessRules = @(
        ('*{0}:(F)' -f $currentUserSid.Value),
        '*S-1-5-18:(F)',
        '*S-1-5-32-544:(F)'
    )
    & icacls.exe $Path /inheritance:r /grant:r $accessRules | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restrict file permissions with icacls (exit code $LASTEXITCODE): $Path"
    }
}

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectRoot
$signTool = [System.IO.Path]::GetFullPath($SignToolPath)
if ([string]::IsNullOrWhiteSpace($CertificatesDirectory)) {
    $CertificatesDirectory = Join-Path $projectRoot 'certificates'
}
$certificatesDirectory = [System.IO.Path]::GetFullPath($CertificatesDirectory)
$temporaryCertificatePath = Join-Path $certificatesDirectory ('.' + [guid]::NewGuid().ToString('N') + '.p12')
$certificatePath = $null
$passwordPath = $null
$certificate = $null
$createdCertificate = $false
$createdPassword = $false

if (-not (Test-Path -LiteralPath $signTool -PathType Leaf)) {
    throw "ZXPSignCmd.exe was not found. Set its path in ZXP Manager: $signTool"
}
if (Test-Path -LiteralPath $certificatesDirectory) {
    $certificatesDirectoryItem = Get-Item -LiteralPath $certificatesDirectory -Force
    if (-not $certificatesDirectoryItem.PSIsContainer -or
        ($certificatesDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to use a non-directory or reparse-point certificates path: $certificatesDirectory"
    }
}
else {
    New-Item -ItemType Directory -Path $certificatesDirectory | Out-Null
}

$randomBytes = New-Object byte[] 32
$randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $randomGenerator.GetBytes($randomBytes)
}
finally {
    $randomGenerator.Dispose()
}
$password = [BitConverter]::ToString($randomBytes).Replace('-', '')
[Array]::Clear($randomBytes, 0, $randomBytes.Length)

try {
    & $signTool `
        -selfSignedCert `
        'UA' `
        'Kyiv' `
        $projectMetadata.BundleName `
        "$($projectMetadata.BundleName) Test Signing" `
        $password `
        $temporaryCertificatePath `
        -validityDays 3650

    if ($LASTEXITCODE -ne 0) {
        throw "ZXPSignCmd failed to create the test certificate (exit code $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $temporaryCertificatePath -PathType Leaf)) {
        throw 'ZXPSignCmd reported success but did not create the certificate file.'
    }

    Set-RestrictedFileAcl -Path $temporaryCertificatePath
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $temporaryCertificatePath,
        $password,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )
    $serialNumber = $certificate.SerialNumber
    if ([string]::IsNullOrWhiteSpace($serialNumber) -or $serialNumber -notmatch '^[0-9A-Fa-f]+$') {
        throw 'Could not read a valid serial number from the generated certificate.'
    }

    $serialNumber = $serialNumber.ToUpperInvariant()
    $certificatePath = Join-Path $certificatesDirectory "$serialNumber.p12"
    $passwordPath = Join-Path $certificatesDirectory "$serialNumber.password.txt"
    if ((Test-Path -LiteralPath $certificatePath) -or (Test-Path -LiteralPath $passwordPath)) {
        throw "Refusing to overwrite existing files for certificate serial $serialNumber."
    }
    $certificate.Dispose()
    $certificate = $null
    Move-Item -LiteralPath $temporaryCertificatePath -Destination $certificatePath
    $createdCertificate = $true

    [System.IO.File]::WriteAllText(
        $passwordPath,
        $password,
        [System.Text.UTF8Encoding]::new($false)
    )
    $createdPassword = $true

    Set-RestrictedFileAcl -Path $certificatePath
    Set-RestrictedFileAcl -Path $passwordPath
}
catch {
    if ($createdPassword -and (Test-Path -LiteralPath $passwordPath)) {
        Remove-Item -LiteralPath $passwordPath -Force
    }
    if ($createdCertificate -and (Test-Path -LiteralPath $certificatePath)) {
        Remove-Item -LiteralPath $certificatePath -Force
    }
    throw
}
finally {
    if ($certificate) {
        $certificate.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryCertificatePath) {
        Remove-Item -LiteralPath $temporaryCertificatePath -Force
    }
    $password = $null
}

Write-Host 'Test self-signed certificate created and protected with Windows file permissions.' -ForegroundColor Green
Write-Host "Serial number: $serialNumber" -ForegroundColor Cyan
Write-Host "Certificate: $certificatePath" -ForegroundColor Cyan
Write-Host "Password file: $passwordPath" -ForegroundColor Cyan
Write-Host 'The password is not displayed. Do not commit either file.' -ForegroundColor Yellow
