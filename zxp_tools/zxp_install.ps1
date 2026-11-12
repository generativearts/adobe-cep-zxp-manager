#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ZxpPath,
    [string]$UPIAPath,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SignToolPath = (Join-Path $PSScriptRoot 'ZXPSignCmd.exe')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zxp_common.ps1')

function Find-InstalledExtensionManifest {
    param(
        [Parameter(Mandatory = $true)][string]$BundleId,
        [Parameter(Mandatory = $true)][string]$ExtensionId
    )

    $extensionRoots = @(
            (Join-Path $env:ProgramFiles 'Common Files\Adobe\CEP\extensions'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Common Files\Adobe\CEP\extensions' }),
        (Join-Path $env:APPDATA 'Adobe\CEP\extensions'),
        (Join-Path $env:LOCALAPPDATA 'Adobe\CEP\extensions')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

    foreach ($root in $extensionRoots) {
        foreach ($manifestFile in Get-ChildItem -LiteralPath $root -Filter 'manifest.xml' -File -Recurse -ErrorAction SilentlyContinue) {
            try {
                [xml]$manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw
                $manifestRoot = $manifest.ExtensionManifest
                $declaredBundleId = $manifestRoot.GetAttribute('ExtensionBundleId')
                $declaredExtensionId = $manifestRoot.ExtensionList.Extension.GetAttribute('Id')
                if ($declaredBundleId -eq $BundleId -and $declaredExtensionId -eq $ExtensionId) {
                    return [pscustomobject]@{
                        Path = $manifestFile.FullName
                        BundleVersion = $manifestRoot.GetAttribute('ExtensionBundleVersion')
                        ExtensionVersion = $manifestRoot.ExtensionList.Extension.GetAttribute('Version')
                    }
                }
            }
            catch {
                Write-Warning "Unable to inspect CEP manifest '$($manifestFile.FullName)': $($_.Exception.Message)"
            }
        }
    }
    return $null
}

$projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$manifestPath = Join-Path $projectRoot 'CSXS\manifest.xml'
$verifierPath = Join-Path $PSScriptRoot 'zxp_sign_verify.ps1'

if ([string]::IsNullOrWhiteSpace($UPIAPath)) {
    $upiaRelativePath = 'Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe'
    $upiaCandidates = @(
        (Join-Path $env:ProgramFiles $upiaRelativePath),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} $upiaRelativePath })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    $upiaCandidates = @($upiaCandidates)

    if (-not $upiaCandidates.Count) {
        throw 'UnifiedPluginInstallerAgent.exe was not found. Install/update Creative Cloud Desktop or pass -UPIAPath explicitly.'
    }

    $UPIAPath = $upiaCandidates[0]
}
else {
    $UPIAPath = [System.IO.Path]::GetFullPath($UPIAPath)
}

if (-not (Test-Path -LiteralPath $UPIAPath -PathType Leaf)) {
    throw "Unified Plugin Installer Agent was not found: $UPIAPath"
}

if ([string]::IsNullOrWhiteSpace($ZxpPath)) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Project manifest was not found: $manifestPath"
    }

    $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectRoot
    $packageFileName = Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $projectMetadata.Version
    $managedPackage = Join-Path (Join-Path $projectRoot 'zxp_packages') $packageFileName
    $legacyPackage = Join-Path (Join-Path (Join-Path $projectRoot 'staging') (Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $projectMetadata.Version)) $packageFileName
    if (Test-Path -LiteralPath $managedPackage -PathType Leaf) {
        $ZxpPath = $managedPackage
    }
    else {
        $ZxpPath = $legacyPackage
    }
}
else {
    $ZxpPath = [System.IO.Path]::GetFullPath($ZxpPath)
}

if (-not (Test-Path -LiteralPath $ZxpPath -PathType Leaf)) {
    throw "ZXP package was not found: $ZxpPath"
}
if ([System.IO.Path]::GetExtension($ZxpPath) -ine '.zxp') {
    throw "Expected a .zxp package: $ZxpPath"
}
if (-not (Test-Path -LiteralPath $verifierPath -PathType Leaf)) {
    throw "ZXP verification script was not found: $verifierPath"
}

$packageManifest = Get-ZxpManifest -Path $ZxpPath
$packageBundleId = $packageManifest.ExtensionManifest.GetAttribute('ExtensionBundleId')
$packageExtensionId = $packageManifest.ExtensionManifest.ExtensionList.Extension.GetAttribute('Id')
$packageVersion = $packageManifest.ExtensionManifest.GetAttribute('ExtensionBundleVersion')
if ([string]::IsNullOrWhiteSpace($packageBundleId) -or
    [string]::IsNullOrWhiteSpace($packageExtensionId) -or
    [string]::IsNullOrWhiteSpace($packageVersion)) {
    throw 'The ZXP manifest is missing its bundle ID, extension ID, or version.'
}
$targetHostApplications = @(Get-ZxpHostApplications -Manifest $packageManifest)
$targetHostNames = @($targetHostApplications | ForEach-Object { $_.ProductName }) -join ', '

& $verifierPath -ZxpPath $ZxpPath -ProjectRoot $projectRoot -SignToolPath $SignToolPath

if ($PSCmdlet.ShouldProcess($ZxpPath, "Install for $targetHostNames with UPIA at '$UPIAPath'")) {
    $runningHostApplications = @(Get-ZxpRunningHostApplications -Manifest $packageManifest)
    if ($runningHostApplications.Count) {
        throw "Close the target Adobe application(s) before installing: $($runningHostApplications -join ', ')."
    }

    & $UPIAPath /install $ZxpPath
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        throw "UPIA failed to install the ZXP package (exit code $installExitCode)."
    }

    $installedManifest = Find-InstalledExtensionManifest -BundleId $packageBundleId -ExtensionId $packageExtensionId
    if (-not $installedManifest) {
        throw "UPIA returned success, but the installed extension '$packageExtensionId' was not found."
    }
    if ($installedManifest.BundleVersion -ne $packageVersion -or
        $installedManifest.ExtensionVersion -ne $packageVersion) {
        throw "UPIA returned success, but installed version '$($installedManifest.BundleVersion)' does not match package version '$packageVersion'. Installed manifest: $($installedManifest.Path)"
    }

    Write-Host "UPIA installed and verified version $packageVersion." -ForegroundColor Green
    Write-Host "Installed manifest: $($installedManifest.Path)" -ForegroundColor Cyan
}
