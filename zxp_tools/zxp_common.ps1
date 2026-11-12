#Requires -Version 5.1

function Get-ZxpProjectMetadata {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $manifestPath = Join-Path $ProjectRoot 'CSXS\manifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Project manifest was not found: $manifestPath"
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    $manifestRoot = $manifest.ExtensionManifest
    if (-not $manifestRoot) {
        throw "Project manifest has no ExtensionManifest root: $manifestPath"
    }

    $bundleName = $manifestRoot.GetAttribute('ExtensionBundleName').Trim()
    $bundleId = $manifestRoot.GetAttribute('ExtensionBundleId').Trim()
    $packageName = Get-ZxpPackageNameFromBundle -BundleName $bundleName -BundleId $bundleId

    $version = $manifestRoot.GetAttribute('ExtensionBundleVersion')
    if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
        throw "Project manifest contains an invalid release version: '$version'."
    }

    return [pscustomobject]@{
        BundleName = $bundleName
        BundleId = $bundleId
        PackageName = $packageName
        Version = $version
    }
}

function Get-ZxpPackageNameFromBundle {
    param(
        [AllowEmptyString()][string]$BundleName,
        [AllowEmptyString()][string]$BundleId
    )

    $name = $BundleName.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $BundleId.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'The manifest must declare ExtensionBundleName or ExtensionBundleId.'
    }

    $packageName = $name -replace '[^A-Za-z0-9._-]+', '.'
    $packageName = $packageName.Trim([char[]]@('.', '-', '_'))
    if ([string]::IsNullOrWhiteSpace($packageName)) {
        throw 'The bundle name does not contain any characters that can be used in a package filename.'
    }
    if ($packageName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        $packageName = "_$packageName"
    }
    return $packageName
}

function Get-ZxpReleaseDirectoryName {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    return "$PackageName.$Version"
}

function Get-ZxpPackageFileName {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    return "$(Get-ZxpReleaseDirectoryName -PackageName $PackageName -Version $Version).zxp"
}

function Get-ZxpSigningCertificateSerial {
    param([Parameter(Mandatory = $true)][string]$ZxpPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZxpPath)
    try {
        $signatureEntry = $archive.GetEntry('META-INF/signatures.xml')
        if (-not $signatureEntry) {
            throw "ZXP package does not contain META-INF/signatures.xml: $ZxpPath"
        }

        $stream = $signatureEntry.Open()
        try {
            $settings = [System.Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $xmlReader = [System.Xml.XmlReader]::Create($stream, $settings)
            try {
                $document = [System.Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.Load($xmlReader)
            }
            finally {
                $xmlReader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    $certificateNode = $document.SelectSingleNode("//*[local-name()='X509Certificate']")
    if (-not $certificateNode -or [string]::IsNullOrWhiteSpace($certificateNode.InnerText)) {
        throw "ZXP signature does not contain an X.509 signing certificate: $ZxpPath"
    }

    $certificateBytes = [Convert]::FromBase64String(($certificateNode.InnerText -replace '\s', ''))
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
    try {
        if ([string]::IsNullOrWhiteSpace($certificate.SerialNumber)) {
            throw "Could not read the signing certificate serial number from: $ZxpPath"
        }
        return $certificate.SerialNumber.ToUpperInvariant()
    }
    finally {
        $certificate.Dispose()
        [Array]::Clear($certificateBytes, 0, $certificateBytes.Length)
    }
}
