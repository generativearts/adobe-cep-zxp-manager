#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$StagingRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zxp_common.ps1')

function Copy-RuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$ExcludeTests
    )

    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    foreach ($file in Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force) {
        if ($ExcludeTests -and $file.Name -match '\.(test|spec)\.[^.]+$') {
            continue
        }

        $relativePath = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $destinationPath = Join-Path $Destination $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
}

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$projectRoot = $projectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $StagingRoot = Join-Path $projectRoot 'staging'
}
$releaseRoot = [System.IO.Path]::GetFullPath($StagingRoot)
$manifestPath = Join-Path $projectRoot 'CSXS\manifest.xml'
$versionPath = Join-Path $projectRoot 'version.json'
$packagePath = Join-Path $projectRoot 'package.json'

foreach ($requiredPath in @(
    $manifestPath,
    $versionPath,
    $packagePath,
    (Join-Path $projectRoot 'font-registry.json'),
    (Join-Path $projectRoot 'client'),
    (Join-Path $projectRoot 'host')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required release input not found: $requiredPath"
    }
}

[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$manifestRoot = $manifest.ExtensionManifest
if (-not $manifestRoot -or -not $manifestRoot.ExtensionBundleVersion) {
    throw 'The CEP manifest does not declare ExtensionBundleVersion.'
}

$version = [string]$manifestRoot.ExtensionBundleVersion
if ($version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
    throw "Manifest version is not safe to use as a folder name: $version"
}
$projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectRoot

$versionData = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
$packageData = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
if ($versionData.version -ne $version -or $packageData.version -ne $version) {
    throw "Version mismatch: manifest=$version, version.json=$($versionData.version), package.json=$($packageData.version)"
}

$releaseDirectoryName = Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $version
$releaseDirectory = Join-Path $releaseRoot $releaseDirectoryName
$stagingDirectory = Join-Path $releaseDirectory 'staging'
$stagingRootFullPath = [System.IO.Path]::GetFullPath($releaseRoot).TrimEnd('\') + '\'
$releaseFullPath = [System.IO.Path]::GetFullPath($releaseDirectory)
$stagingFullPath = [System.IO.Path]::GetFullPath($stagingDirectory)

if (-not $releaseFullPath.StartsWith($stagingRootFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not $stagingFullPath.StartsWith($releaseFullPath.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved staging path is outside the expected release directory.'
}

foreach ($directoryPath in @($releaseRoot, $releaseDirectory)) {
    if (Test-Path -LiteralPath $directoryPath) {
        $directory = Get-Item -LiteralPath $directoryPath -Force
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to use a non-directory or reparse-point release path: $directoryPath"
        }
    }
}

New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
$buildDirectory = Join-Path $releaseDirectory ('.staging-build-' + [guid]::NewGuid().ToString('N'))
$backupDirectory = Join-Path $releaseDirectory ('.staging-previous-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $buildDirectory | Out-Null

    Copy-RuntimeDirectory -Source (Join-Path $projectRoot 'CSXS') -Destination (Join-Path $buildDirectory 'CSXS')
    Copy-RuntimeDirectory -Source (Join-Path $projectRoot 'client') -Destination (Join-Path $buildDirectory 'client') -ExcludeTests
    Copy-RuntimeDirectory -Source (Join-Path $projectRoot 'host') -Destination (Join-Path $buildDirectory 'host')
    Copy-Item -LiteralPath $versionPath -Destination (Join-Path $buildDirectory 'version.json')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'font-registry.json') -Destination (Join-Path $buildDirectory 'font-registry.json')

    foreach ($manifestFile in @(
        [string]$manifestRoot.DispatchInfoList.Extension.DispatchInfo.Resources.MainPath,
        [string]$manifestRoot.DispatchInfoList.Extension.DispatchInfo.Resources.ScriptPath
    )) {
        if ([string]::IsNullOrWhiteSpace($manifestFile)) {
            continue
        }

        $relativePath = $manifestFile -replace '^[.][/\\]', ''
        $relativePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $payloadPath = Join-Path $buildDirectory $relativePath
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
            throw "Manifest resource is missing from the release payload: $manifestFile"
        }
    }

    $copiedManifestPath = Join-Path $buildDirectory 'CSXS\manifest.xml'
    [xml]$copiedManifest = Get-Content -LiteralPath $copiedManifestPath -Raw
    if ([string]$copiedManifest.ExtensionManifest.ExtensionBundleVersion -ne $version) {
        throw 'Copied manifest version does not match the release version.'
    }

    if (Test-Path -LiteralPath $stagingDirectory) {
        $existingStage = Get-Item -LiteralPath $stagingDirectory -Force
        if (-not $existingStage.PSIsContainer -or ($existingStage.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace a non-directory or reparse-point staging path: $stagingDirectory"
        }
        if (Get-ChildItem -LiteralPath $stagingDirectory -Force -Recurse | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }) {
            throw "Refusing to replace staging that contains a reparse point: $stagingDirectory"
        }
        Move-Item -LiteralPath $stagingDirectory -Destination $backupDirectory
    }

    try {
        Move-Item -LiteralPath $buildDirectory -Destination $stagingDirectory
    }
    catch {
        if (Test-Path -LiteralPath $backupDirectory -PathType Container) {
            Move-Item -LiteralPath $backupDirectory -Destination $stagingDirectory
        }
        throw
    }

    if (Test-Path -LiteralPath $backupDirectory -PathType Container) {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force
    }
}
finally {
    if (Test-Path -LiteralPath $buildDirectory -PathType Container) {
        Remove-Item -LiteralPath $buildDirectory -Recurse -Force
    }
}

$payloadFileCount = @(Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse).Count
Write-Host "Release staging prepared: $stagingDirectory" -ForegroundColor Green
Write-Host "Version: $version | Runtime files: $payloadFileCount" -ForegroundColor Cyan
Write-Host "Default ZXP output path: $(Join-Path (Join-Path $projectRoot 'zxp_packages') (Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $version))" -ForegroundColor Cyan
