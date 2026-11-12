#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$script:signToolDownloadRequired = $false
$script:signToolDownloadUrl = 'https://github.com/Adobe-CEP/CEP-Resources/raw/refs/heads/master/ZXPSignCMD/4.1.3/x64/ZXPSignCmd.exe'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Start the GUI with zxp_manager_gui.bat so PowerShell runs in STA mode.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$toolDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$scriptsDirectory = $toolDirectory
$commonScriptPath = Join-Path $scriptsDirectory 'zxp_common.ps1'
if (-not (Test-Path -LiteralPath $commonScriptPath -PathType Leaf)) {
    throw "Required ZXP helper file not found: $commonScriptPath"
}
. $commonScriptPath
$defaultProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $toolDirectory))
$settingsDirectory = Join-Path $env:APPDATA 'ZxpManager'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$legacySettingsPath = Join-Path $env:APPDATA 'Calendarium Studio\ZxpManager\settings.json'
$settings = [ordered]@{
    Projects = @()
    ActiveProjectRoot = $defaultProjectRoot
    SignToolPath = Join-Path $toolDirectory 'ZXPSignCmd.exe'
    TimestampUrl = 'http://time.certum.pl/'
    CertificateDescriptions = @{}
    WindowWidth = 1050
    WindowHeight = 820
}

$settingsSourcePath = if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settingsPath
}
elseif (Test-Path -LiteralPath $legacySettingsPath -PathType Leaf) {
    $legacySettingsPath
}
else {
    $null
}
if ($settingsSourcePath) {
    $savedSettings = Get-Content -LiteralPath $settingsSourcePath -Raw | ConvertFrom-Json
    foreach ($key in @('SignToolPath', 'TimestampUrl', 'WindowWidth', 'WindowHeight')) {
        if ($null -ne $savedSettings.$key -and "$($savedSettings.$key)" -ne '') {
            $settings[$key] = $savedSettings.$key
        }
    }
    if ($savedSettings.CertificateDescriptions) {
        foreach ($property in $savedSettings.CertificateDescriptions.PSObject.Properties) {
            $thumbprint = ([string]$property.Name).ToUpperInvariant()
            $description = [string]$property.Value
            if ($thumbprint -match '^[0-9A-F]+$' -and -not [string]::IsNullOrWhiteSpace($description)) {
                $settings.CertificateDescriptions[$thumbprint] = $description
            }
        }
    }
    if ($savedSettings.Projects) {
        $settings.Projects = @($savedSettings.Projects | ForEach-Object {
            [pscustomobject]@{
                ProjectRoot = [string]$_.ProjectRoot
                StagingRoot = [string]$_.StagingRoot
                ZxpRoot = [string]$_.ZxpRoot
                CertificatesRoot = [string]$_.CertificatesRoot
                SelectedCertificate = [string]$_.SelectedCertificate
                SelectedStagingVersion = [string]$_.SelectedStagingVersion
                SelectedZxpPath = [string]$_.SelectedZxpPath
            }
        })
        if ($savedSettings.ActiveProjectRoot) {
            $settings.ActiveProjectRoot = [string]$savedSettings.ActiveProjectRoot
        }
    }
    elseif ($savedSettings.ProjectRoot) {
        $settings.Projects = @([pscustomobject]@{
            ProjectRoot = [string]$savedSettings.ProjectRoot
            StagingRoot = [string]$savedSettings.StagingRoot
            ZxpRoot = [string]$savedSettings.ZxpRoot
            CertificatesRoot = [string]$savedSettings.CertificatesRoot
            SelectedCertificate = [string]$savedSettings.SelectedCertificate
            SelectedStagingVersion = [string]$savedSettings.SelectedStagingVersion
            SelectedZxpPath = [string]$savedSettings.SelectedZxpPath
        })
        $settings.ActiveProjectRoot = [string]$savedSettings.ProjectRoot
    }
}

function Get-NormalizedProjectRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $rootPath.Length) {
        $fullPath = $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $fullPath
}

function New-ProjectProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$AllowMissingManifest
    )

    $normalizedRoot = Get-NormalizedProjectRoot -Path $ProjectRoot
    if (-not $AllowMissingManifest -or
        (Test-Path -LiteralPath (Join-Path $normalizedRoot 'CSXS\manifest.xml') -PathType Leaf)) {
        [void](Get-ZxpProjectMetadata -ProjectRoot $normalizedRoot)
    }
    return [pscustomobject]@{
        ProjectRoot = $normalizedRoot
        StagingRoot = Join-Path $normalizedRoot 'staging'
        ZxpRoot = Join-Path $normalizedRoot 'zxp_packages'
        CertificatesRoot = Join-Path $normalizedRoot 'certificates'
        SelectedCertificate = ''
        SelectedStagingVersion = ''
        SelectedZxpPath = ''
    }
}

if (-not $settings.Projects.Count) {
    $settings.Projects = @((New-ProjectProfile -ProjectRoot $defaultProjectRoot -AllowMissingManifest))
    $settings.ActiveProjectRoot = $defaultProjectRoot
}
else {
    foreach ($profile in $settings.Projects) {
        if ([string]::IsNullOrWhiteSpace($profile.ProjectRoot)) {
            throw 'Saved project profile is missing its project root.'
        }
        $profile.ProjectRoot = Get-NormalizedProjectRoot -Path $profile.ProjectRoot
        foreach ($pathProperty in @('StagingRoot', 'ZxpRoot', 'CertificatesRoot')) {
            if ([string]::IsNullOrWhiteSpace([string]$profile.$pathProperty)) {
                $defaultFolder = switch ($pathProperty) {
                    'StagingRoot' { 'staging' }
                    'ZxpRoot' { 'zxp_packages' }
                    'CertificatesRoot' { 'certificates' }
                }
                $profile.$pathProperty = Join-Path $profile.ProjectRoot $defaultFolder
            }
        }
    }
    $activeProfile = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$settings.ActiveProjectRoot)) {
        $activeRoot = Get-NormalizedProjectRoot -Path ([string]$settings.ActiveProjectRoot)
        $activeProfile = @($settings.Projects | Where-Object {
            $_.ProjectRoot.Equals($activeRoot, [System.StringComparison]::OrdinalIgnoreCase)
        }) | Select-Object -First 1
    }
    if (-not $activeProfile) {
        $activeProfile = $settings.Projects[0]
        $settings.ActiveProjectRoot = $activeProfile.ProjectRoot
    }
}

$activeProjectProfile = @($settings.Projects | Where-Object {
    $_.ProjectRoot.Equals([string]$settings.ActiveProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)
}) | Select-Object -First 1
$settings.ActiveProjectRoot = $activeProjectProfile.ProjectRoot
$projectRoot = [string]$activeProjectProfile.ProjectRoot
$signToolPath = [System.IO.Path]::GetFullPath([string]$settings.SignToolPath)
$manifestPath = Join-Path $projectRoot 'CSXS\manifest.xml'
$script:playerDebugModeRegistryRoot = 'Software\Adobe\CSXS'
$script:pendingPlayerDebugModeVersions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:pendingPlayerDebugModeValues = @{}
$script:updatingPlayerDebugModeGrid = $false
$script:updatingZxpGrid = $false
$script:updatingStagingGrid = $false
$script:updatingCertificateGrid = $false
$scriptPaths = @{
    Common = $commonScriptPath
    Stage = Join-Path $scriptsDirectory 'zxp_prepare_staging.ps1'
    CreateCertificate = Join-Path $scriptsDirectory 'zxp_create_signing_certificate.ps1'
    Sign = Join-Path $scriptsDirectory 'zxp_sign.ps1'
    Verify = Join-Path $scriptsDirectory 'zxp_sign_verify.ps1'
    Install = Join-Path $scriptsDirectory 'zxp_install.ps1'
    WorkflowRunner = Join-Path $scriptsDirectory 'zxp_workflow_runner.ps1'
}
$childPowerShellCommand = Get-Command -Name powershell.exe -ErrorAction SilentlyContinue
if ($childPowerShellCommand) {
    $childPowerShellPath = $childPowerShellCommand.Source
}
else {
    $childPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
if (-not (Test-Path -LiteralPath $childPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell was not found: $childPowerShellPath"
}
foreach ($requiredPath in $scriptPaths.Values) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required ZXP workflow file not found: $requiredPath"
    }
}

function Save-Settings {
    if ($script:suppressSettingsSave) {
        return
    }
    Save-ActiveProjectSettings
    $settings.SignToolPath = $signToolPathBox.Text.Trim()
    $settings.TimestampUrl = $timestampBox.Text.Trim()
    $settings.WindowWidth = $form.Width
    $settings.WindowHeight = $form.Height
    $settings.ActiveProjectRoot = $projectPathBox.Text.Trim()
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $tempPath = $settingsPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            ($settings | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $tempPath -Destination $settingsPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Save-ActiveProjectSettings {
    if (-not $projectPathBox -or [string]::IsNullOrWhiteSpace($projectPathBox.Text)) {
        return
    }
    $activeRoot = Get-NormalizedProjectRoot -Path $projectPathBox.Text.Trim()
    $profile = @($settings.Projects | Where-Object {
        $_.ProjectRoot.Equals($activeRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    if (-not $profile) {
        throw "Active project is not registered: $activeRoot"
    }
    $profile.ProjectRoot = $activeRoot
    $profile.StagingRoot = $stagingPathBox.Text.Trim()
    $profile.ZxpRoot = $zxpPathBox.Text.Trim()
    $profile.CertificatesRoot = $certificatesPathBox.Text.Trim()
    $selectedStaging = Get-SelectedStaging
    $profile.SelectedStagingVersion = if ($selectedStaging) { [string]$selectedStaging.Version } else { '' }
    $selectedZxp = Get-SelectedZxp
    $profile.SelectedZxpPath = if ($selectedZxp) { [string]$selectedZxp.Path } else { '' }
    $profile.SelectedCertificate = if (Get-SelectedCertificateSerial) { Get-SelectedCertificateSerial } else { '' }
}

function Get-PlayerDebugModeKeyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$RegistryRoot = $script:playerDebugModeRegistryRoot
    )

    if ($Version -notmatch '^(?:10|11|12|13|14|15|16)$') {
        throw "Unsupported CEP version: $Version"
    }
    return "$RegistryRoot.$Version"
}

function Get-PlayerDebugModeCurrentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$RegistryRoot = $script:playerDebugModeRegistryRoot
    )

    $keyPath = Get-PlayerDebugModeKeyPath -Version $Version -RegistryRoot $RegistryRoot
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath, $false)
    if (-not $key) {
        return [pscustomobject]@{
            KeyExisted = $false
            ValueExisted = $false
            Data = $null
        }
    }
    try {
        $valueExists = $key.GetValueNames() -contains 'PlayerDebugMode'
        if (-not $valueExists) {
            return [pscustomobject]@{
                KeyExisted = $true
                ValueExisted = $false
                Data = $null
            }
        }
        $value = $key.GetValue(
            'PlayerDebugMode',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        return [pscustomobject]@{
            KeyExisted = $true
            ValueExisted = $true
            Data = $value
        }
    }
    finally {
        $key.Dispose()
    }
}

function Set-PlayerDebugModeValue {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][ValidateSet('0', '1')][string]$Value,
        [string]$RegistryRoot = $script:playerDebugModeRegistryRoot
    )

    $keyPath = Get-PlayerDebugModeKeyPath -Version $Version -RegistryRoot $RegistryRoot
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($keyPath)
    if (-not $key) {
        throw "Could not open or create registry key HKCU:\$keyPath."
    }
    try {
        $key.SetValue('PlayerDebugMode', $Value, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $key.Dispose()
    }
}

function Update-PlayerDebugModeList {
    if (-not $playerDebugModeList) {
        return
    }
    $script:updatingPlayerDebugModeGrid = $true
    try {
        $playerDebugModeList.Rows.Clear()
        foreach ($version in @('10', '11', '12', '13', '14', '15', '16')) {
            $snapshot = Get-PlayerDebugModeCurrentValue -Version $version
            if (-not $snapshot.KeyExisted -or -not $snapshot.ValueExisted) {
                $state = 'Not configured'
                $valueText = '(not set)'
                $enabled = $false
            }
            elseif ([string]$snapshot.Data -eq '1') {
                $state = 'Enabled'
                $valueText = '1'
                $enabled = $true
            }
            else {
                $state = 'Disabled'
                $valueText = [string]$snapshot.Data
                $enabled = $false
            }
            if ($script:pendingPlayerDebugModeVersions.Contains($version)) {
                $enabled = [bool]$script:pendingPlayerDebugModeValues[$version]
                $state += ' (pending)'
            }
            $state += "  |  Registry value: $valueText"
            [void]$playerDebugModeList.Rows.Add($version, $enabled, $state)
        }
    }
    finally {
        $script:updatingPlayerDebugModeGrid = $false
    }
    Update-PlayerDebugModeStatus
}

function Update-PlayerDebugModeStatus {
    if (-not $playerDebugModeList) {
        return
    }
    $hasPendingChanges = $script:pendingPlayerDebugModeVersions.Count -gt 0
    $playerDebugModeApplyButton.Enabled = $hasPendingChanges
    if ($hasPendingChanges) {
        $playerDebugModeStatusLabel.Text = "$($script:pendingPlayerDebugModeVersions.Count) pending change(s). Use Apply Changes to write them to the registry."
    }
    else {
        $playerDebugModeStatusLabel.Text = 'Use Enable All or Disable All, then select Apply Changes to write the setting for every CEP version.'
    }
}

function Set-PlayerDebugModeAll {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    foreach ($row in $playerDebugModeList.Rows) {
        $version = [string]$row.Cells[0].Value
        $script:pendingPlayerDebugModeVersions.Add($version) | Out-Null
        $script:pendingPlayerDebugModeValues[$version] = $Enabled
        $row.Cells[1].Value = $Enabled
        $row.Cells[2].Value = "$(if ($Enabled) { 'Enabled' } else { 'Disabled' }) (pending)"
    }
    Update-PlayerDebugModeStatus
}

function Apply-PlayerDebugModeChanges {
    param(
        [string]$RegistryRoot = $script:playerDebugModeRegistryRoot,
        [switch]$Confirmed
    )

    $versions = @($script:pendingPlayerDebugModeVersions)
    if (-not $versions.Count) {
        return
    }
    if (-not $Confirmed) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Apply the staged PlayerDebugMode changes for CEP $($versions -join ', ')?`r`nRestart Illustrator for the changes to take effect.",
            'Apply PlayerDebugMode Changes',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    }

    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($version in $versions) {
        try {
            $value = if ($script:pendingPlayerDebugModeValues[$version]) { '1' } else { '0' }
            Set-PlayerDebugModeValue -Version $version -Value $value -RegistryRoot $RegistryRoot
            [void]$script:pendingPlayerDebugModeVersions.Remove($version)
            $script:pendingPlayerDebugModeValues.Remove($version)
        }
        catch {
            $failed.Add("CEP $version`: $($_.Exception.Message)")
        }
    }
    Update-PlayerDebugModeList
    if ($failed.Count) {
        $message = "Some registry changes failed:`r`n$($failed -join [Environment]::NewLine)`r`n`r`nFailed changes remain staged and can be retried."
        [void][System.Windows.Forms.MessageBox]::Show(
            $message,
            'PlayerDebugMode Partially Updated',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        Add-Log $message ([System.Drawing.Color]::FromArgb(255, 115, 115))
        return
    }
    Add-Log "PlayerDebugMode changes applied for CEP $($versions -join ', '). Restart Illustrator to apply the changes." ([System.Drawing.Color]::FromArgb(120, 210, 145))
}

function Update-ProjectSelector {
    $script:suppressProjectSwitch = $true
    try {
    $projectSelector.Items.Clear()
    foreach ($profile in $settings.Projects) {
        $metadata = $null
        try {
            $metadata = Get-ZxpProjectMetadata -ProjectRoot $profile.ProjectRoot
            $label = "$($metadata.BundleName) ($($metadata.Version)) - $($profile.ProjectRoot)"
        }
        catch {
            $label = if ([string]$profile.ProjectRoot -eq [string]$defaultProjectRoot) {
                "Add an Illustrator project to begin - $($profile.ProjectRoot)"
            }
            else {
                "Unavailable project - $($profile.ProjectRoot)"
            }
        }
        [void]$projectSelector.Items.Add([pscustomobject]@{
            ProjectRoot = $profile.ProjectRoot
            Label = $label
        })
    }
    $projectSelector.DisplayMember = 'Label'
    $selectedProject = @($projectSelector.Items | Where-Object {
        $_.ProjectRoot.Equals([string]$settings.ActiveProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    if ($selectedProject) {
        $projectSelector.SelectedItem = $selectedProject
    }
    $removeProjectButton.Enabled = $settings.Projects.Count -gt 1
    }
    finally {
        $script:suppressProjectSwitch = $false
    }
}

function Set-ActiveProject {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$SkipSave
    )

    $normalizedRoot = Get-NormalizedProjectRoot -Path $ProjectRoot
    $profile = @($settings.Projects | Where-Object {
        $_.ProjectRoot.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    if (-not $profile) {
        throw "Project is not registered: $normalizedRoot"
    }

    if (-not $SkipSave) {
        Save-ActiveProjectSettings
    }
    $settings.ActiveProjectRoot = $normalizedRoot
    $script:activeProjectProfile = $profile
    $script:projectRoot = $normalizedRoot
    $script:suppressSettingsSave = $true
    try {
        $projectPathBox.Text = $profile.ProjectRoot
        $stagingPathBox.Text = $profile.StagingRoot
        $zxpPathBox.Text = $profile.ZxpRoot
        $certificatesPathBox.Text = $profile.CertificatesRoot
        $certificateList.ClearSelection()
        $stagingVersionList.ClearSelection()
        $zxpList.ClearSelection()
        Refresh-Certificates
        Refresh-StagingVersions
        Refresh-ZxpVersions
        Update-BaseProjectVersion
        Update-ProjectSelector
    }
    finally {
        $script:suppressSettingsSave = $false
    }
    Save-Settings
    Add-Log "Active project: $normalizedRoot" ([System.Drawing.Color]::FromArgb(120, 190, 255))
}

function Add-Project {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $normalizedRoot = Get-NormalizedProjectRoot -Path $ProjectRoot
    $existing = @($settings.Projects | Where-Object {
        $_.ProjectRoot.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    if ($existing) {
        Set-ActiveProject -ProjectRoot $existing.ProjectRoot
        return
    }
    $profile = New-ProjectProfile -ProjectRoot $normalizedRoot
    $settings.Projects = @($settings.Projects) + @($profile)
    Update-ProjectSelector
    Set-ActiveProject -ProjectRoot $profile.ProjectRoot
}

function Remove-ActiveProject {
    if ($settings.Projects.Count -le 1) {
        throw 'At least one project must remain registered.'
    }
    $activeRoot = Get-NormalizedProjectRoot -Path $projectPathBox.Text.Trim()
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Remove this project from ZXP Manager? Project files will not be deleted.`r`n$activeRoot",
        'Remove Project',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Save-ActiveProjectSettings
    $settings.Projects = @($settings.Projects | Where-Object {
        -not $_.ProjectRoot.Equals($activeRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    $nextProjectRoot = [string]$settings.Projects[0].ProjectRoot
    $settings.ActiveProjectRoot = $nextProjectRoot
    Update-ProjectSelector
    Set-ActiveProject -ProjectRoot $nextProjectRoot -SkipSave
}

function Add-Log {
    param(
        [AllowNull()][AllowEmptyString()][string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(225, 230, 238)
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $Color
    $logBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    $logBox.SelectionColor = $logBox.ForeColor
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-SelectedCertificateSerial {
    $item = Get-SelectedCertificate
    if ($item) {
        return [string]$item.Serial
    }
    return $null
}

function Get-SelectedCertificate {
    if ($certificateList.SelectedRows.Count -gt 0) {
        return $certificateList.SelectedRows[0].Tag
    }
    if ($certificateList.SelectedCells.Count -gt 0) {
        return $certificateList.Rows[$certificateList.SelectedCells[0].RowIndex].Tag
    }
    return $null
}

function Update-SelectedCertificateDetails {
    $item = Get-SelectedCertificate
    if (-not $item) {
        $certificateDetailsLabel.Text = 'Select a certificate to view its details.'
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.Thumbprint)) {
        $certificateDetailsLabel.Text = "File created: $($item.FileCreatedAt)  |  Password required for signing."
        return
    }
    $description = [string]$settings.CertificateDescriptions[[string]$item.Thumbprint]
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = '(no description)'
    }
    $certificateDetailsLabel.Text = "File created: $($item.FileCreatedAt)  |  Certificate valid from: $($item.ValidFrom)  |  Description: $description"
}

function Edit-SelectedCertificateDescription {
    $item = Get-SelectedCertificate
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Select a certificate before editing its description.',
            'No Certificate Selected',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.Thumbprint)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Enter the certificate password before editing its description.',
            'Certificate Password Required',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Edit Certificate Description'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 160)

    $identityLabel = New-Label "$($item.Name)  |  $($item.Serial)" 12 12 496 24
    $identityLabel.AutoEllipsis = $true
    $identityLabel.Anchor = 'Top, Left, Right'
    $dialog.Controls.Add($identityLabel)

    $descriptionInput = New-Object System.Windows.Forms.TextBox
    $descriptionInput.Location = New-Object System.Drawing.Point(12, 42)
    $descriptionInput.Size = New-Object System.Drawing.Size(496, 24)
    $descriptionInput.Anchor = 'Top, Left, Right'
    $descriptionInput.MaxLength = 200
    $descriptionInput.Text = [string]$settings.CertificateDescriptions[[string]$item.Thumbprint]
    $dialog.Controls.Add($descriptionInput)

    $hint = New-Label 'Leave empty to remove the description. This is stored only in ZXP Manager settings.' 12 72 496 34
    $hint.Anchor = 'Top, Left, Right'
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
    $dialog.Controls.Add($hint)

    $saveButton = New-Button 'Save' 330 116 82
    $saveButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($saveButton)
    $cancelButton = New-Button 'Cancel' 426 116 82
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton

    $result = $dialog.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $description = $descriptionInput.Text.Trim()
        $thumbprint = [string]$item.Thumbprint
        if ([string]::IsNullOrWhiteSpace($description)) {
            [void]$settings.CertificateDescriptions.Remove($thumbprint)
        }
        else {
            $settings.CertificateDescriptions[$thumbprint] = $description
        }
        Save-Settings
        Refresh-Certificates
    }
    $dialog.Dispose()
}

function Get-ProjectVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Get-ZxpProjectMetadata -ProjectRoot $Root).Version
}

function Update-BaseProjectVersion {
    try {
        $version = Get-ProjectVersion -Root $projectPathBox.Text.Trim()
        $baseProjectVersionLabel.Text = "Base project version: $version"
        $baseProjectVersionLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 210, 145)
    }
    catch {
        $baseProjectVersionLabel.Text = "Base project version: unavailable - $($_.Exception.Message)"
        $baseProjectVersionLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 115, 115)
    }
}

function Set-SignToolMissingStatus {
    param([Parameter(Mandatory = $true)][string]$Message)

    $downloadText = 'Download ZXPSignCmd.exe from Adobe CEP Resources'
    $signToolStatusLabel.Links.Clear()
    $signToolStatusLabel.Text = "$Message $downloadText"
    $signToolStatusLabel.Links.Add(
        $Message.Length + 1,
        $downloadText.Length,
        $script:signToolDownloadUrl
    ) | Out-Null
}

function Update-SignToolStatus {
    $script:signToolPath = $signToolPathBox.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($script:signToolPath)) {
        try {
            $script:signToolPath = [System.IO.Path]::GetFullPath($script:signToolPath)
            if ($signToolPathBox.Text -ne $script:signToolPath) {
                $signToolPathBox.Text = $script:signToolPath
            }
        }
        catch {
            Set-SignToolMissingStatus -Message "Invalid ZXPSignCmd.exe path: $($_.Exception.Message)"
            $signToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 115, 115)
            $script:signToolDownloadRequired = $true
            return
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:signToolPath) -and (Test-Path -LiteralPath $script:signToolPath -PathType Leaf)) {
        $signToolStatusLabel.Text = "ZXPSignCmd.exe found: $script:signToolPath"
        $signToolStatusLabel.Links.Clear()
        $signToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 210, 145)
        $script:signToolDownloadRequired = $false
    }
    else {
        Set-SignToolMissingStatus -Message 'ZXPSignCmd.exe not found.'
        $signToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 115, 115)
        $script:signToolDownloadRequired = $true
    }
}

function Test-SignToolAvailable {
    Update-SignToolStatus
    $path = $script:signToolPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $message = if ([string]::IsNullOrWhiteSpace($path)) {
            'ZXPSignCmd.exe path is not set. Specify it on the Projects & Settings tab.'
        }
        else {
            "ZXPSignCmd.exe was not found:`r`n$path`r`n`r`nSpecify the correct path on the Projects & Settings tab."
        }
        Add-Log $message ([System.Drawing.Color]::FromArgb(255, 115, 115))
        [void][System.Windows.Forms.MessageBox]::Show($message, 'ZXPSignCmd.exe Not Found', 'OK', 'Error')
        return $false
    }
    return $true
}

function Set-RestrictedFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules = @("*${sid}:(F)", '*S-1-5-18:(F)', '*S-1-5-32-544:(F)')
    & icacls.exe $Path /inheritance:r /grant:r $rules | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict permissions for '$Path' (icacls exit code $LASTEXITCODE)."
    }
}

function Read-ZxpManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('CSXS/manifest.xml')
        if (-not $entry) {
            throw "ZXP does not contain CSXS/manifest.xml: $Path"
        }
        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                [xml]$manifest = $reader.ReadToEnd()
                return $manifest
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Refresh-Certificates {
    $previous = Get-SelectedCertificateSerial
    $previousCertificate = Get-SelectedCertificate
    $previousThumbprint = if ($previousCertificate) { [string]$previousCertificate.Thumbprint } else { '' }
    $script:updatingCertificateGrid = $true
    try {
        $certificateList.Rows.Clear()
        $root = $certificatesPathBox.Text.Trim()
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $activeProjectProfile.SelectedCertificate = ''
        }
        else {
            foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.p12' -File | Sort-Object LastWriteTime -Descending) {
                $serial = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToUpperInvariant()
                $passwordFile = Join-Path $root "$serial.password.txt"
                if ($serial -notmatch '^[0-9A-F]+$') {
                    continue
                }
                if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) {
                    $item = [pscustomobject]@{
                        Serial = $serial
                        Thumbprint = ''
                        Name = 'Password required'
                        FileCreatedAt = $file.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
                        ValidFrom = ''
                        Path = $file.FullName
                        Description = ''
                    }
                    $rowIndex = $certificateList.Rows.Add(
                        $item.Serial,
                        $item.Name,
                        '(no description)',
                        $item.FileCreatedAt
                    )
                    $certificateList.Rows[$rowIndex].Tag = $item
                    if ($serial -eq $previous -or
                        $serial -eq [string]$activeProjectProfile.SelectedCertificate) {
                        $certificateList.Rows[$rowIndex].Selected = $true
                    }
                    continue
                }
                $certificate = $null
                try {
                    $password = Get-Content -LiteralPath $passwordFile -Raw
                    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                        $file.FullName,
                        $password,
                        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
                    )
                    if (-not $certificate.HasPrivateKey -or $certificate.SerialNumber.ToUpperInvariant() -ne $serial) {
                        continue
                    }
                    $item = [pscustomobject]@{
                        Serial = $serial
                        Thumbprint = $certificate.Thumbprint.ToUpperInvariant()
                        Name = $certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
                        FileCreatedAt = $file.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
                        ValidFrom = $certificate.NotBefore.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                        Path = $file.FullName
                        Description = [string]$settings.CertificateDescriptions[$certificate.Thumbprint.ToUpperInvariant()]
                    }
                    $rowIndex = $certificateList.Rows.Add(
                        $item.Serial,
                        $item.Name,
                        $(if ([string]::IsNullOrWhiteSpace($item.Description)) { '(no description)' } else { $item.Description }),
                        $item.FileCreatedAt
                    )
                    $certificateList.Rows[$rowIndex].Tag = $item
                    if ($certificate.Thumbprint.ToUpperInvariant() -eq $previousThumbprint -or
                        $serial -eq $previous -or
                        $serial -eq [string]$activeProjectProfile.SelectedCertificate) {
                        $certificateList.Rows[$rowIndex].Selected = $true
                    }
                }
                catch {
                    Add-Log "Could not load certificate '$($file.Name)': $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 170, 100))
                }
                finally {
                    if ($certificate) {
                        $certificate.Dispose()
                    }
                    $password = $null
                }
            }
            if ($certificateList.SelectedRows.Count -eq 0 -and $certificateList.Rows.Count -gt 0) {
                $certificateList.Rows[0].Selected = $true
            }
            if ($certificateList.SelectedRows.Count -gt 0) {
                $certificateList.CurrentCell = $certificateList.SelectedRows[0].Cells[0]
            }
        }
    }
    finally {
        $script:updatingCertificateGrid = $false
    }
    Update-SelectedCertificateDetails
    if (-not (Test-Path -LiteralPath $certificatesPathBox.Text.Trim() -PathType Container)) {
        $activeProjectProfile.SelectedCertificate = ''
        Save-Settings
    }
}

function Refresh-StagingVersions {
    $selectedStaging = Get-SelectedStaging
    $previousVersion = if ($selectedStaging) { [string]$selectedStaging.Version } else { [string]$activeProjectProfile.SelectedStagingVersion }
    $script:updatingStagingGrid = $true
    try {
        $stagingVersionList.Rows.Clear()
        $root = $stagingPathBox.Text.Trim()
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $stagingPathLabel.Text = 'Staging path: (folder does not exist yet)'
            $activeProjectProfile.SelectedStagingVersion = ''
        }
        else {
            foreach ($versionDirectory in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending) {
                $manifestFile = Join-Path $versionDirectory.FullName 'staging\CSXS\manifest.xml'
                if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
                    continue
                }
                try {
                    [xml]$manifest = Get-Content -LiteralPath $manifestFile -Raw
                    $version = [string]$manifest.ExtensionManifest.GetAttribute('ExtensionBundleVersion')
                    $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectPathBox.Text.Trim()
                    $bundleId = $manifest.ExtensionManifest.GetAttribute('ExtensionBundleId')
                    if (-not [string]::IsNullOrWhiteSpace($projectMetadata.BundleId) -and
                        $bundleId -ne $projectMetadata.BundleId) {
                        continue
                    }
                    if ($version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
                        continue
                    }
                    $item = [pscustomobject]@{
                        Version = $version
                        Directory = $versionDirectory.FullName
                        Payload = Join-Path $versionDirectory.FullName 'staging'
                    }
                    $rowIndex = $stagingVersionList.Rows.Add($item.Version, $versionDirectory.Name, $item.Payload)
                    $stagingVersionList.Rows[$rowIndex].Tag = $item
                    if ($version -eq $previousVersion) {
                        $stagingVersionList.Rows[$rowIndex].Selected = $true
                    }
                }
                catch {
                    Add-Log "Could not read staging '$($versionDirectory.FullName)': $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 170, 100))
                }
            }
            if ($stagingVersionList.SelectedRows.Count -eq 0 -and $stagingVersionList.Rows.Count -gt 0) {
                $stagingVersionList.Rows[0].Selected = $true
            }
            if ($stagingVersionList.SelectedRows.Count -gt 0) {
                $stagingVersionList.CurrentCell = $stagingVersionList.SelectedRows[0].Cells[0]
            }
        }
    }
    finally {
        $script:updatingStagingGrid = $false
    }
    Update-SelectedStagingPath
    if (-not (Test-Path -LiteralPath $stagingPathBox.Text.Trim() -PathType Container)) {
        $stagingPathLabel.Text = 'Staging path: (folder does not exist yet)'
        $activeProjectProfile.SelectedStagingVersion = ''
        Save-Settings
    }
}

function Get-SelectedStaging {
    if ($stagingVersionList.SelectedRows.Count -gt 0) {
        return $stagingVersionList.SelectedRows[0].Tag
    }
    if ($stagingVersionList.SelectedCells.Count -gt 0) {
        return $stagingVersionList.Rows[$stagingVersionList.SelectedCells[0].RowIndex].Tag
    }
    return $null
}

function Update-SelectedStagingPath {
    $selectedStaging = Get-SelectedStaging
    if ($selectedStaging) {
        $stagingPathLabel.Text = "Selected staging: $($selectedStaging.Payload)"
        $activeProjectProfile.SelectedStagingVersion = [string]$selectedStaging.Version
    }
    else {
        $stagingPathLabel.Text = 'Staging path: no prepared versions found'
        $activeProjectProfile.SelectedStagingVersion = ''
    }
    Save-Settings
}

function Refresh-ZxpVersions {
    $selectedZxp = Get-SelectedZxp
    $previousPath = if ($selectedZxp) { [string]$selectedZxp.Path } else { [string]$activeProjectProfile.SelectedZxpPath }
    $previousStatuses = @{}
    foreach ($row in $zxpList.Rows) {
        $existingItem = $row.Tag
        if (-not $existingItem) {
            continue
        }
        $previousStatuses[[string]$existingItem.Path] = @{
            SignatureStatus = [string]$existingItem.SignatureStatus
            TimestampStatus = [string]$existingItem.TimestampStatus
            SigningCertificateSerial = [string]$existingItem.SigningCertificateSerial
        }
    }
    $script:updatingZxpGrid = $true
    try {
        $zxpList.Rows.Clear()
        $root = $zxpPathBox.Text.Trim()
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $selectedZxpLabel.Text = 'Selected ZXP: (folder does not exist yet)'
            $activeProjectProfile.SelectedZxpPath = ''
        }
        else {
            foreach ($package in Get-ChildItem -LiteralPath $root -Filter '*.zxp' -File | Sort-Object LastWriteTime -Descending) {
                try {
                    $manifest = Read-ZxpManifest -Path $package.FullName
                    $version = [string]$manifest.ExtensionManifest.GetAttribute('ExtensionBundleVersion')
                    $item = [pscustomobject]@{
                        Version = $version
                        Name = $package.Name
                        Path = $package.FullName
                        SizeBytes = [long]$package.Length
                        LastModified = $package.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                        SignatureStatus = 'Not verified'
                        TimestampStatus = 'Not verified'
                        SigningCertificateSerial = ''
                    }
                    if ($previousStatuses.ContainsKey($package.FullName)) {
                        $item.SignatureStatus = $previousStatuses[$package.FullName].SignatureStatus
                        $item.TimestampStatus = $previousStatuses[$package.FullName].TimestampStatus
                        $item.SigningCertificateSerial = $previousStatuses[$package.FullName].SigningCertificateSerial
                    }
                    $rowIndex = $zxpList.Rows.Add(
                        $item.Version,
                        $item.Name,
                        (Format-ZxpFileSize -Bytes $item.SizeBytes),
                        $item.LastModified,
                        $item.SignatureStatus,
                        $item.TimestampStatus,
                        $(if ($item.SigningCertificateSerial) { $item.SigningCertificateSerial } else { 'Not verified' })
                    )
                    $zxpList.Rows[$rowIndex].Tag = $item
                    Update-ZxpItemRow -Item $item
                }
                catch {
                    Add-Log "Could not read ZXP '$($package.FullName)': $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 170, 100))
                }
            }
            $zxpList.ClearSelection()
            $selectedRow = $null
            foreach ($row in $zxpList.Rows) {
                if ($row.Tag -and [string]$row.Tag.Path -eq $previousPath) {
                    $selectedRow = $row
                    break
                }
            }
            if (-not $selectedRow -and $zxpList.Rows.Count -gt 0) {
                $selectedRow = $zxpList.Rows[0]
            }
            if ($selectedRow) {
                $selectedRow.Selected = $true
                $zxpList.CurrentCell = $selectedRow.Cells[0]
            }
        }
    }
    finally {
        $script:updatingZxpGrid = $false
    }
    Update-SelectedZxp
    if (-not (Test-Path -LiteralPath $zxpPathBox.Text.Trim() -PathType Container)) {
        $selectedZxpLabel.Text = 'Selected ZXP: (folder does not exist yet)'
        $activeProjectProfile.SelectedZxpPath = ''
        Save-Settings
    }
}

function Update-ZxpItemRow {
    param([Parameter(Mandatory = $true)][psobject]$Item)
    foreach ($row in $zxpList.Rows) {
        if (-not $row.Tag -or [string]$row.Tag.Path -ne [string]$Item.Path) {
            continue
        }
        $row.Cells['Version'].Value = $Item.Version
        $row.Cells['Package'].Value = $Item.Name
        $row.Cells['Size'].Value = Format-ZxpFileSize -Bytes ([long]$Item.SizeBytes)
        $row.Cells['LastModified'].Value = $Item.LastModified
        $row.Cells['Signature'].Value = $Item.SignatureStatus
        $row.Cells['Timestamp'].Value = $Item.TimestampStatus
        $row.Cells['CertificateSerial'].Value = if ([string]::IsNullOrWhiteSpace($Item.SigningCertificateSerial)) {
            'Not verified'
        }
        else {
            $Item.SigningCertificateSerial
        }
        $row.Cells['Signature'].Style.ForeColor = switch -Regex ($Item.SignatureStatus) {
            '^Valid$' { [System.Drawing.Color]::FromArgb(120, 210, 145); break }
            'failed' { [System.Drawing.Color]::FromArgb(255, 115, 115); break }
            default { [System.Drawing.Color]::FromArgb(188, 198, 212) }
        }
        $row.Cells['Timestamp'].Style.ForeColor = switch -Regex ($Item.TimestampStatus) {
            '^Valid$' { [System.Drawing.Color]::FromArgb(120, 210, 145); break }
            'Invalid|Not confirmed' { [System.Drawing.Color]::FromArgb(255, 170, 100); break }
            default { [System.Drawing.Color]::FromArgb(188, 198, 212) }
        }
        $row.Cells['CertificateSerial'].Style.ForeColor = if ($Item.SigningCertificateSerial) {
            [System.Drawing.Color]::FromArgb(188, 198, 212)
        }
        else {
            [System.Drawing.Color]::FromArgb(140, 150, 164)
        }
        break
    }
}

function Update-ZxpVerificationStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [string]$Output = ''
    )
    foreach ($row in $zxpList.Rows) {
        $item = $row.Tag
        if (-not $item) {
            continue
        }
        if ([string]$item.Path -ne $Path) { continue }
        if ($Succeeded -and $Output -match '(?im)^Signature verified successfully\s*$') {
            $item.SignatureStatus = 'Valid'
            if ($Output -match '(?im)^Signing certificate serial number:\s*([0-9A-F]+)\s*$') {
                $item.SigningCertificateSerial = $Matches[1].ToUpperInvariant()
            }
            else {
                $item.SigningCertificateSerial = ''
                Add-Log "Signing certificate serial number was not reported for '$Path'." ([System.Drawing.Color]::FromArgb(255, 170, 100))
            }
        }
        else {
            $item.SignatureStatus = 'Verification failed'
            $item.SigningCertificateSerial = ''
        }
        if ($Output -match '(?im)^Timestamp:\s*Valid\b') {
            $item.TimestampStatus = 'Valid'
        }
        elseif ($Output -match '(?im)^Timestamp:\s*(.+)$') {
            $item.TimestampStatus = "Invalid ($($Matches[1].Trim()))"
        }
        else {
            $item.TimestampStatus = 'Not confirmed'
        }
        Update-ZxpItemRow $item
        $selectedItem = Get-SelectedZxp
        if ($selectedItem -and [string]$selectedItem.Path -eq [string]$item.Path) {
            Update-SelectedZxp
        }
        return
    }
}

function Get-SelectedZxp {
    if ($zxpList.SelectedRows.Count -gt 0) {
        return $zxpList.SelectedRows[0].Tag
    }
    if ($zxpList.SelectedCells.Count -gt 0) {
        return $zxpList.Rows[$zxpList.SelectedCells[0].RowIndex].Tag
    }
    return $null
}

function Format-ZxpFileSize {
    param([Parameter(Mandatory = $true)][long]$Bytes)

    if ($Bytes -ge 1GB) {
        return '{0:N2} GB' -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return '{0:N2} MB' -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return '{0:N1} KB' -f ($Bytes / 1KB)
    }
    return "$Bytes B"
}

function Update-SelectedZxp {
    $selectedZxp = Get-SelectedZxp
    if ($selectedZxp) {
        $certificateSerial = if ([string]::IsNullOrWhiteSpace($selectedZxp.SigningCertificateSerial)) {
            'Not verified'
        }
        else {
            [string]$selectedZxp.SigningCertificateSerial
        }
        $size = Format-ZxpFileSize -Bytes ([long]$selectedZxp.SizeBytes)
        $selectedZxpLabel.Text = "Size: $size | Modified: $($selectedZxp.LastModified)`r`nSignature: $($selectedZxp.SignatureStatus) | Timestamp: $($selectedZxp.TimestampStatus) | Signing certificate serial: $certificateSerial`r`n$($selectedZxp.Path)"
        $activeProjectProfile.SelectedZxpPath = [string]$selectedZxp.Path
    }
    else {
        $selectedZxpLabel.Text = 'No ZXP packages found'
        $activeProjectProfile.SelectedZxpPath = ''
    }
    Save-Settings
}

function New-WorkflowStep {
    param([string]$Label, [string]$ScriptPath, [string[]]$Arguments = @())
    [pscustomobject]@{ Label = $Label; ScriptPath = $ScriptPath; Arguments = $Arguments }
}

function New-WorkflowState {
    param([string]$Name, [object[]]$Steps, [string]$VerificationPath = '')
    [pscustomobject]@{
        Name = $Name
        Steps = @($Steps)
        StepIndex = 0
        Process = $null
        CurrentStdoutPath = ''
        CurrentStderrPath = ''
        CurrentExitCodePath = ''
        VerificationPath = $VerificationPath
        OutputFiles = New-Object System.Collections.Generic.List[string]
        StepOutputs = New-Object System.Collections.Generic.List[object]
    }
}

function Start-Workflow {
    param([string]$Name, [object[]]$Steps, [string]$VerificationPath = '')
    if ($script:workflowState) {
        return
    }
    $script:pendingZxpVerificationPath = $VerificationPath
    $script:workflowState = New-WorkflowState -Name $Name -Steps $Steps -VerificationPath $VerificationPath
    $script:activeOutputFiles = @()
    $script:readOffsets = @{}
    Add-Log "Started: $Name" ([System.Drawing.Color]::FromArgb(120, 190, 255))
    Set-WorkflowBusy $true
    try {
        Start-WorkflowStepProcess
        $workflowTimer.Start()
    }
    catch {
        Complete-Workflow -ErrorMessage (Get-WorkflowErrorMessage -Exception $_.Exception)
    }
}

function Get-WorkflowErrorMessage {
    param([System.Exception]$Exception)

    if ($null -eq $Exception) {
        return 'The operation failed, but Windows PowerShell did not provide exception details.'
    }

    $baseException = $Exception.GetBaseException()
    if ($null -ne $baseException -and -not [string]::IsNullOrWhiteSpace($baseException.Message)) {
        return $baseException.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($Exception.Message)) {
        return $Exception.Message
    }
    return 'The operation failed without additional details.'
}

function Start-WorkflowStepProcess {
    if (-not $script:workflowState) {
        return
    }

    $workflow = $script:workflowState
    $step = $workflow.Steps[$workflow.StepIndex]
    $argumentsPath = Join-Path $env:TEMP ('zxp-manager-' + [guid]::NewGuid().ToString('N') + '.json')
    $exitCodePath = Join-Path $env:TEMP ('zxp-manager-' + [guid]::NewGuid().ToString('N') + '.exit')
    $stdoutPath = Join-Path $env:TEMP ('zxp-manager-' + [guid]::NewGuid().ToString('N') + '.out')
    $stderrPath = Join-Path $env:TEMP ('zxp-manager-' + [guid]::NewGuid().ToString('N') + '.err')
    [System.IO.File]::WriteAllText(
        $argumentsPath,
        (ConvertTo-Json -InputObject @($step.Arguments) -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
    foreach ($path in @($argumentsPath, $exitCodePath, $stdoutPath, $stderrPath)) {
        $workflow.OutputFiles.Add($path)
    }
    $script:activeOutputFiles = @($workflow.OutputFiles)
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPaths.WorkflowRunner,
        '-ScriptPath', $step.ScriptPath,
        '-ArgumentsPath', $argumentsPath,
        '-ExitCodePath', $exitCodePath
    )
    $quotedArguments = foreach ($argument in $arguments) {
        $value = [string]$argument
        if ($value.Length -eq 0) { '""'; continue }
        if ($value -notmatch '[\s"]') { $value; continue }
        '"' + $value.Replace('"', '\"') + '"'
    }

    Add-Log "Running: $($step.Label)" ([System.Drawing.Color]::FromArgb(140, 200, 255))
    $process = Start-Process -FilePath $childPowerShellPath `
        -ArgumentList ($quotedArguments -join ' ') `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru
    $workflow.Process = $process
    $workflow.CurrentStdoutPath = $stdoutPath
    $workflow.CurrentStderrPath = $stderrPath
    $workflow.CurrentExitCodePath = $exitCodePath
}

function Read-WorkflowOutput {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $offset = if ($script:readOffsets.ContainsKey($Path)) { [long]$script:readOffsets[$Path] } else { 0L }
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$stream.Seek($offset, 'Begin')
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            $text = $reader.ReadToEnd()
            $script:readOffsets[$Path] = $stream.Position
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    foreach ($line in ($text -split '\r?\n')) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Add-Log $line
        }
    }
    return $text
}

function Complete-Workflow {
    param([string]$ErrorMessage = '')

    $workflow = $script:workflowState
    if (-not $workflow) {
        return
    }
    $workflowTimer.Stop()
    try {
        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
            Add-Log $ErrorMessage ([System.Drawing.Color]::FromArgb(255, 115, 115))
            if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingZxpVerificationPath)) {
                Update-ZxpVerificationStatus -Path $script:pendingZxpVerificationPath -Succeeded $false -Output $ErrorMessage
            }
            $statusLabel.Text = 'Error'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 115, 115)
            [void][System.Windows.Forms.MessageBox]::Show($ErrorMessage, 'ZXP Workflow Error', 'OK', 'Error')
        }
        else {
            Refresh-ZxpVersions
            if (-not [string]::IsNullOrWhiteSpace([string]$workflow.VerificationPath)) {
                $verificationOutput = ($workflow.StepOutputs | ForEach-Object { $_.Text }) -join [Environment]::NewLine
                Update-ZxpVerificationStatus -Path $workflow.VerificationPath -Succeeded $true -Output $verificationOutput
            }
            Add-Log 'Workflow completed successfully.' ([System.Drawing.Color]::FromArgb(120, 210, 145))
            $statusLabel.Text = 'Completed successfully'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 210, 145)
            Refresh-StagingVersions
            Refresh-Certificates
        }
    }
    catch {
        $handlerError = Get-WorkflowErrorMessage -Exception $_.Exception
        Add-Log "Error processing workflow result: $handlerError" ([System.Drawing.Color]::FromArgb(255, 115, 115))
        $statusLabel.Text = 'Result processing error'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 115, 115)
        [void][System.Windows.Forms.MessageBox]::Show($handlerError, 'Result Processing Error', 'OK', 'Error')
    }
    finally {
        if ($workflow.Process) {
            try {
                $workflow.Process.Refresh()
                if (-not $workflow.Process.HasExited) {
                    Stop-Process -Id $workflow.Process.Id -Force -ErrorAction Stop
                    if (-not $workflow.Process.WaitForExit(5000)) {
                        throw "Child process $($workflow.Process.Id) did not exit after termination was requested."
                    }
                }
            }
            catch {
                $stopError = Get-WorkflowErrorMessage -Exception $_.Exception
                Add-Log "Could not stop child process: $stopError" ([System.Drawing.Color]::FromArgb(255, 115, 115))
            }
            $workflow.Process.Dispose()
        }
        foreach ($path in $workflow.OutputFiles) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        $script:activeOutputFiles = @()
        $script:readOffsets = @{}
        $script:pendingZxpVerificationPath = ''
        $script:workflowState = $null
        try {
            Set-WorkflowBusy $false
            Save-Settings
        }
        catch {
            $finalizeError = Get-WorkflowErrorMessage -Exception $_.Exception
            Add-Log "Could not finalize GUI update: $finalizeError" ([System.Drawing.Color]::FromArgb(255, 115, 115))
            [void][System.Windows.Forms.MessageBox]::Show($finalizeError, 'GUI Update Error', 'OK', 'Error')
        }
    }
}

function Set-WorkflowBusy {
    param([bool]$Busy)
    $tabs.Enabled = -not $Busy
    $form.ControlBox = -not $Busy
    $statusLabel.Text = if ($Busy) { 'Running...' } else { 'Ready' }
    $statusLabel.ForeColor = if ($Busy) { [System.Drawing.Color]::FromArgb(255, 190, 90) } else { [System.Drawing.Color]::FromArgb(120, 210, 145) }
}

function Get-InstallStep {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
    if (Get-Process -Name Illustrator -ErrorAction SilentlyContinue) {
        throw 'Close Illustrator before installing.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ZXP package not found: $Path"
    }
    $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Install the verified package?`r`n`r`n$Path`r`n`r`nIllustrator must be closed.",
        'Confirm Installation',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return $null
    }
    return ,@((New-WorkflowStep 'Verify Signature and Install via UPIA' $scriptPaths.Install @('-ZxpPath', $Path, '-ProjectRoot', $resolvedProjectRoot, '-SignToolPath', $signToolPathBox.Text.Trim())))
}

function Test-DirectChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [System.IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetDirectoryName($childFull).TrimEnd('\').Equals($parentFull.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PasswordFromDialog {
    param([string]$Title, [string]$Prompt)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(440, 130)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size = New-Object System.Drawing.Size(410, 38)
    $dialog.Controls.Add($label)
    $passwordInput = New-Object System.Windows.Forms.TextBox
    $passwordInput.Location = New-Object System.Drawing.Point(15, 55)
    $passwordInput.Size = New-Object System.Drawing.Size(405, 24)
    $passwordInput.UseSystemPasswordChar = $true
    $dialog.Controls.Add($passwordInput)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Location = New-Object System.Drawing.Point(250, 90)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(335, 90)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Add_Shown({ $passwordInput.Focus() }.GetNewClosure())
    $result = $dialog.ShowDialog($form)
    $value = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $passwordInput.Text } else { $null }
    $passwordInput.Clear()
    $dialog.Dispose()
    return $value
}

function Ensure-CertificatePasswordFile {
    param([Parameter(Mandatory = $true)][string]$Serial)

    $serial = $Serial.ToUpperInvariant()
    if ($serial -notmatch '^[0-9A-F]+$') {
        throw "Invalid certificate serial number: $Serial"
    }
    $root = [System.IO.Path]::GetFullPath($certificatesPathBox.Text.Trim())
    $certificatePath = Join-Path $root "$serial.p12"
    $passwordPath = Join-Path $root "$serial.password.txt"
    if (Test-Path -LiteralPath $passwordPath -PathType Leaf) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
        throw "Certificate file was not found: $certificatePath"
    }

    $password = Get-PasswordFromDialog 'Certificate Password Required' "Enter the password for certificate $serial. It will be saved in the certificate folder with restricted access:"
    if ($null -eq $password) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'The certificate password cannot be empty.'
    }

    $certificate = $null
    $createdPasswordFile = $false
    try {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certificatePath,
            $password,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        )
        if (-not $certificate.HasPrivateKey -or $certificate.SerialNumber.ToUpperInvariant() -ne $serial) {
            throw "The password did not unlock the expected signing certificate $serial."
        }
        [System.IO.File]::WriteAllText($passwordPath, $password, [System.Text.UTF8Encoding]::new($false))
        $createdPasswordFile = $true
        Set-RestrictedFileAcl -Path $passwordPath
        Add-Log "Saved a restricted password file for certificate $serial." ([System.Drawing.Color]::FromArgb(120, 210, 145))
        Refresh-Certificates
        return $true
    }
    catch {
        if ($createdPasswordFile -and (Test-Path -LiteralPath $passwordPath -PathType Leaf)) {
            Remove-Item -LiteralPath $passwordPath -Force
        }
        throw
    }
    finally {
        if ($certificate) {
            $certificate.Dispose()
        }
        $password = $null
    }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 180, [int]$Height = 24)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 150)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 32)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(77, 94, 117)
    $button.BackColor = [System.Drawing.Color]::FromArgb(49, 58, 72)
    $button.ForeColor = [System.Drawing.Color]::White
    return $button
}

function Set-ResponsiveTabLayout {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [System.Windows.Forms.Control[]]$HeaderControls,
        [System.Windows.Forms.Control]$ListControl,
        [System.Windows.Forms.Control]$SelectedControl,
        [System.Windows.Forms.Control[]]$ActionButtons
    )

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object System.Windows.Forms.Padding(12)
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $header = New-Object System.Windows.Forms.TableLayoutPanel
    $header.Dock = 'Fill'
    $header.AutoSize = $true
    $header.ColumnCount = 1
    $header.RowCount = $HeaderControls.Count
    $header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($control in $HeaderControls) {
        $control.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
        $control.Dock = 'Fill'
        [void]$header.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $header.Controls.Add($control, 0, $header.Controls.Count)
    }
    $layout.Controls.Add($header, 0, 0)

    $ListControl.Dock = 'Fill'
    $ListControl.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $layout.Controls.Add($ListControl, 0, 1)

    if ($SelectedControl) {
        $SelectedControl.Dock = 'Fill'
        $SelectedControl.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
        $layout.Controls.Add($SelectedControl, 0, 2)
    }

    $actions = New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Fill'
    $actions.AutoSize = $true
    $actions.WrapContents = $true
    $actions.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $actions.Margin = New-Object System.Windows.Forms.Padding(0)
    foreach ($button in $ActionButtons) {
        $button.Anchor = 'Top, Left'
        $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 4)
        $actions.Controls.Add($button)
    }
    $layout.Controls.Add($actions, 0, 3)

    $Tab.Controls.Clear()
    $Tab.Controls.Add($layout)
    return $layout
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ZXP Manager for Adobe Illustrator'
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 720)
$form.Size = New-Object System.Drawing.Size([Math]::Max(1050, [int]$settings.WindowWidth), [Math]::Max(860, [int]$settings.WindowHeight))
$form.BackColor = [System.Drawing.Color]::FromArgb(31, 35, 43)
$form.ForeColor = [System.Drawing.Color]::FromArgb(232, 236, 242)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Label 'ZXP Manager for Adobe Illustrator' 20 16 720 34
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 92)
$tabs.Size = New-Object System.Drawing.Size(990, 430)
$tabs.Anchor = 'Top, Left, Right'
$tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.ItemSize = New-Object System.Drawing.Size(135, 34)
$tabs.Add_DrawItem({
    param($sender, $eventArgs)
    if ($eventArgs.Index -lt 0 -or $eventArgs.Index -ge $sender.TabPages.Count) {
        return
    }

    $selected = $eventArgs.Index -eq $sender.SelectedIndex
    $bounds = $eventArgs.Bounds
    $background = if ($selected) {
        [System.Drawing.Color]::FromArgb(58, 76, 101)
    }
    else {
        [System.Drawing.Color]::FromArgb(42, 48, 59)
    }
    $backgroundBrush = New-Object System.Drawing.SolidBrush($background)
    try {
        $eventArgs.Graphics.FillRectangle($backgroundBrush, $bounds)
    }
    finally {
        $backgroundBrush.Dispose()
    }
    if ($selected) {
        $accentBounds = New-Object System.Drawing.Rectangle($bounds.X, ($bounds.Bottom - 3), $bounds.Width, 3)
        $accentBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(92, 161, 230))
        try {
            $eventArgs.Graphics.FillRectangle($accentBrush, $accentBounds)
        }
        finally {
            $accentBrush.Dispose()
        }
    }

    $fontStyle = if ($selected) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $fontSize = if ($selected) { 9.5 } else { 9 }
    $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, $fontStyle)
    try {
        $textBounds = New-Object System.Drawing.Rectangle($bounds.X, $bounds.Y, $bounds.Width, ($bounds.Height - 3))
        $textColor = if ($selected) {
            [System.Drawing.Color]::White
        }
        else {
            [System.Drawing.Color]::FromArgb(188, 198, 212)
        }
        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
            [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
            [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
            [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText(
            $eventArgs.Graphics,
            $sender.TabPages[$eventArgs.Index].Text,
            $font,
            $textBounds,
            $textColor,
            $textFlags
        )
    }
    finally {
        $font.Dispose()
    }
})
$form.Controls.Add($tabs)
$pathsTab = New-Object System.Windows.Forms.TabPage('Projects & Settings')
$certificatesTab = New-Object System.Windows.Forms.TabPage('Certificates')
$stagingTab = New-Object System.Windows.Forms.TabPage('Staging')
$zxpTab = New-Object System.Windows.Forms.TabPage('ZXP')
$cepDebugTab = New-Object System.Windows.Forms.TabPage('CEP Debug')
$aboutTab = New-Object System.Windows.Forms.TabPage('About')
[void]$tabs.TabPages.AddRange(@($pathsTab, $certificatesTab, $stagingTab, $zxpTab, $cepDebugTab, $aboutTab))
foreach ($tab in @($pathsTab, $certificatesTab, $stagingTab, $zxpTab, $cepDebugTab, $aboutTab)) {
    $tab.BackColor = [System.Drawing.Color]::FromArgb(36, 41, 50)
    $tab.ForeColor = [System.Drawing.Color]::FromArgb(232, 236, 242)
}

$pathsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$pathsLayout.Dock = 'Fill'
$pathsLayout.ColumnCount = 3
$pathsLayout.RowCount = 6
$pathsLayout.Padding = New-Object System.Windows.Forms.Padding(12, 16, 12, 16)
$pathsLayout.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$pathsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 22)))
[void]$pathsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 67)))
[void]$pathsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 11)))
for ($row = 0; $row -lt 6; $row++) {
    [void]$pathsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
}
$pathsTab.Controls.Add($pathsLayout)

$projectPathBox = New-Object System.Windows.Forms.TextBox
$projectPathBox.Text = [string]$activeProjectProfile.ProjectRoot
$projectPathBox.ReadOnly = $true
$stagingPathBox = New-Object System.Windows.Forms.TextBox
$stagingPathBox.Text = [string]$activeProjectProfile.StagingRoot
$zxpPathBox = New-Object System.Windows.Forms.TextBox
$zxpPathBox.Text = [string]$activeProjectProfile.ZxpRoot
$certificatesPathBox = New-Object System.Windows.Forms.TextBox
$certificatesPathBox.Text = [string]$activeProjectProfile.CertificatesRoot
$signToolPathBox = New-Object System.Windows.Forms.TextBox
$signToolPathBox.Text = [string]$settings.SignToolPath
$timestampBox = New-Object System.Windows.Forms.TextBox
$timestampBox.Text = [string]$settings.TimestampUrl

$projectSelector = New-Object System.Windows.Forms.ComboBox
$projectSelector.Dock = 'Fill'
$projectSelector.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$projectSelector.Margin = New-Object System.Windows.Forms.Padding(3, 5, 6, 5)
$addProjectButton = New-Button 'Add Project...' 0 0 120
$addProjectButton.Dock = 'Fill'
$addProjectButton.Margin = New-Object System.Windows.Forms.Padding(3)
$removeProjectButton = New-Button 'Remove Project' 0 0 120
$removeProjectButton.Dock = 'Fill'
$removeProjectButton.Margin = New-Object System.Windows.Forms.Padding(3)
$projectSelectorPanel = New-Object System.Windows.Forms.TableLayoutPanel
$projectSelectorPanel.Dock = 'Fill'
$projectSelectorPanel.ColumnCount = 3
$projectSelectorPanel.RowCount = 1
$projectSelectorPanel.Padding = New-Object System.Windows.Forms.Padding(12, 5, 12, 3)
[void]$projectSelectorPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 66)))
[void]$projectSelectorPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 17)))
[void]$projectSelectorPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 17)))
$projectSelectorPanel.Controls.Add($projectSelector, 0, 0)
$projectSelectorPanel.Controls.Add($addProjectButton, 1, 0)
$projectSelectorPanel.Controls.Add($removeProjectButton, 2, 0)

$pathRows = @(
    @{ Label = 'Project Root:'; Box = $projectPathBox; Kind = 'None'; Path = '' },
    @{ Label = 'Staging Root:'; Box = $stagingPathBox; Kind = 'Folder'; Path = [string]$activeProjectProfile.StagingRoot },
    @{ Label = 'ZXP Packages Root:'; Box = $zxpPathBox; Kind = 'Folder'; Path = [string]$activeProjectProfile.ZxpRoot },
    @{ Label = 'Certificates Folder:'; Box = $certificatesPathBox; Kind = 'Folder'; Path = [string]$activeProjectProfile.CertificatesRoot },
    @{ Label = 'ZXPSignCmd.exe:'; Box = $signToolPathBox; Kind = 'File'; Path = [string]$settings.SignToolPath },
    @{ Label = 'Timestamp URL:'; Box = $timestampBox; Kind = 'None'; Path = '' }
)

$browseButtons = @{}
for ($index = 0; $index -lt $pathRows.Count; $index++) {
    $row = $pathRows[$index]
    $label = New-Label $row.Label 0 0 170 26
    $label.Dock = 'Fill'
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $row.Box.Dock = 'Fill'
    $row.Box.Margin = New-Object System.Windows.Forms.Padding(3, 5, 5, 5)
    if ($row.Kind -eq 'None') {
        $pathsLayout.Controls.Add($label, 0, $index)
        $pathsLayout.Controls.Add($row.Box, 1, $index)
        if ($row.Label -eq 'Project Root:') {
            $pathsLayout.SetColumnSpan($row.Box, 2)
        }
        continue
    }
    $button = New-Button 'Browse...' 0 0 90
    $button.Dock = 'Fill'
    $button.Margin = New-Object System.Windows.Forms.Padding(3, 3, 0, 3)
    $pathsLayout.Controls.Add($label, 0, $index)
    $pathsLayout.Controls.Add($row.Box, 1, $index)
    $pathsLayout.Controls.Add($button, 2, $index)
    $browseButtons[$row.Label] = $button
    if ($row.Kind -eq 'Folder') {
        $button.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.SelectedPath = $row.Path
            $dialog.ShowNewFolderButton = $row.Label -ne 'Project Root:'
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $row.Box.Text = $dialog.SelectedPath
            }
            $dialog.Dispose()
        }.GetNewClosure())
    }
    else {
        $button.Text = 'File...'
    }
}
$stagingBrowse = $browseButtons['Staging Root:']
$zxpBrowse = $browseButtons['ZXP Packages Root:']
$certificatesBrowse = $browseButtons['Certificates Folder:']
$signToolBrowse = $browseButtons['ZXPSignCmd.exe:']

$settingsHint = New-Label 'Settings are saved between runs in your user profile.' 20 300 920 28
$settingsHint.Anchor = 'Top, Left, Right'
$settingsHint.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$pathsTab.Controls.Add($settingsHint)
$signToolStatusLabel = New-Object System.Windows.Forms.LinkLabel
$signToolStatusLabel.Location = New-Object System.Drawing.Point(20, 332)
$signToolStatusLabel.Size = New-Object System.Drawing.Size(920, 42)
$signToolStatusLabel.Anchor = 'Top, Left, Right'
$signToolStatusLabel.LinkColor = [System.Drawing.Color]::FromArgb(115, 180, 245)
$signToolStatusLabel.ActiveLinkColor = [System.Drawing.Color]::FromArgb(155, 205, 255)
$signToolStatusLabel.VisitedLinkColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$signToolStatusLabel.Add_LinkClicked({
    param($sender, $eventArgs)
    try {
        Start-Process -FilePath ([string]$eventArgs.Link.LinkData) -ErrorAction Stop
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not open the Adobe CEP Resources download:`r`n$($_.Exception.Message)",
            'Download Link Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})
$pathsFooter = New-Object System.Windows.Forms.TableLayoutPanel
$pathsFooter.Dock = 'Fill'
$pathsFooter.AutoSize = $true
$pathsFooter.ColumnCount = 1
$pathsFooter.RowCount = 2
[void]$pathsFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pathsFooter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$pathsFooter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$settingsHint.Dock = 'Fill'
$signToolStatusLabel.Dock = 'Fill'
$pathsFooter.Controls.Add($settingsHint, 0, 0)
$pathsFooter.Controls.Add($signToolStatusLabel, 0, 1)
$pathsLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$pathsLayout.Padding = New-Object System.Windows.Forms.Padding(12, 16, 12, 8)
$pathsLayout.Dock = 'Fill'
$pathsTab.Controls.Clear()
$pathsRoot = New-Object System.Windows.Forms.TableLayoutPanel
$pathsRoot.Dock = 'Fill'
$pathsRoot.ColumnCount = 1
$pathsRoot.RowCount = 3
[void]$pathsRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pathsRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
[void]$pathsRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pathsRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$pathsRoot.Controls.Add($projectSelectorPanel, 0, 0)
$pathsRoot.Controls.Add($pathsLayout, 0, 1)
$pathsRoot.Controls.Add($pathsFooter, 0, 2)
$pathsTab.Controls.Add($pathsRoot)
Update-ProjectSelector

$certificateHelp = New-Label 'Signing requires a .p12/.pfx file with a private key. If its password file is missing, the manager prompts for the password and saves it with restricted access.' 18 16 920 48
$certificateList = New-Object System.Windows.Forms.DataGridView
$certificateList.AllowUserToAddRows = $false
$certificateList.AllowUserToDeleteRows = $false
$certificateList.AllowUserToResizeRows = $false
$certificateList.AutoGenerateColumns = $false
$certificateList.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$certificateList.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$certificateList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$certificateList.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$certificateList.RowHeadersVisible = $false
$certificateList.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$certificateList.MultiSelect = $false
$certificateList.ReadOnly = $true
$certificateList.Dock = 'Fill'
$certificateList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$certificateList.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$certificateList.ForeColor = [System.Drawing.Color]::White
$certificateList.EnableHeadersVisualStyles = $false
$certificateList.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(49, 58, 72)
$certificateList.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$certificateList.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$certificateList.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$certificateList.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(55, 75, 100)
$certificateList.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$certificateList.RowTemplate.Height = 30
foreach ($columnDefinition in @(
        @{ Name = 'Serial'; Header = 'Serial'; Weight = 24 }
        @{ Name = 'Name'; Header = 'Certificate name'; Weight = 23 }
        @{ Name = 'Description'; Header = 'Description'; Weight = 27 }
        @{ Name = 'FileCreated'; Header = 'File created'; Weight = 26 }
    )) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $columnDefinition.Name
    $column.HeaderText = $columnDefinition.Header
    $column.ReadOnly = $true
    $column.FillWeight = $columnDefinition.Weight
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    [void]$certificateList.Columns.Add($column)
}
$certificateDetailsLabel = New-Label 'Select a certificate to view its details.' 18 0 920 40
$certificateDetailsLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$certificateDetailsLabel.AutoEllipsis = $true
$certRefreshButton = New-Button 'Refresh Certificates' 18 310 140
$certNewButton = New-Button 'Create Test Certificate' 168 310 180
$certImportButton = New-Button 'Import .p12/.pfx...' 358 310 165
$certDescriptionButton = New-Button 'Edit Description...' 533 310 155
$certOpenFolderButton = New-Button 'Open Folder' 698 310 115
Set-ResponsiveTabLayout $certificatesTab @($certificateHelp) $certificateList $certificateDetailsLabel @($certRefreshButton, $certNewButton, $certImportButton, $certDescriptionButton, $certOpenFolderButton) | Out-Null

$stagingHelp = New-Label 'Preparation copies runtime files from the selected project into the staging root.' 18 16 920 30
$baseProjectVersionLabel = New-Label 'Base project version: not detected' 18 42 920 24
$baseProjectVersionLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 210, 145)
$stagingVersionList = New-Object System.Windows.Forms.DataGridView
$stagingVersionList.AllowUserToAddRows = $false
$stagingVersionList.AllowUserToDeleteRows = $false
$stagingVersionList.AllowUserToResizeRows = $false
$stagingVersionList.AutoGenerateColumns = $false
$stagingVersionList.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$stagingVersionList.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$stagingVersionList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$stagingVersionList.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$stagingVersionList.RowHeadersVisible = $false
$stagingVersionList.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$stagingVersionList.MultiSelect = $false
$stagingVersionList.ReadOnly = $true
$stagingVersionList.Dock = 'Fill'
$stagingVersionList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$stagingVersionList.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$stagingVersionList.ForeColor = [System.Drawing.Color]::White
$stagingVersionList.EnableHeadersVisualStyles = $false
$stagingVersionList.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(49, 58, 72)
$stagingVersionList.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$stagingVersionList.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$stagingVersionList.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$stagingVersionList.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(55, 75, 100)
$stagingVersionList.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$stagingVersionList.RowTemplate.Height = 30
foreach ($columnDefinition in @(
        @{ Name = 'Version'; Header = 'Version'; Weight = 18 }
        @{ Name = 'StagingFolder'; Header = 'Staging folder'; Weight = 27 }
        @{ Name = 'PayloadPath'; Header = 'Payload path'; Weight = 55 }
    )) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $columnDefinition.Name
    $column.HeaderText = $columnDefinition.Header
    $column.ReadOnly = $true
    $column.FillWeight = $columnDefinition.Weight
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    [void]$stagingVersionList.Columns.Add($column)
}
$stagingPathLabel = New-Label 'Staging path: no prepared versions found' 18 288 920 40
$stagingPathLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$stageBuildButton = New-Button 'Build Staging from Project' 18 340 220
$stageRefreshButton = New-Button 'Refresh List' 280 340 130
$stageDeleteButton = New-Button 'Delete Selected Version...' 427 340 185
$signButton = New-Button 'Create ZXP Package from Staging' 642 340 225
$signButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$signButton.BackColor = [System.Drawing.Color]::FromArgb(43, 112, 181)
$signButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(89, 160, 225)
$signButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(56, 132, 205)
$fullProcessButton = New-Button 'Stage > Sign > Install' 938 340 270
$stagingLayout = Set-ResponsiveTabLayout $stagingTab @($stagingHelp, $baseProjectVersionLabel) $stagingVersionList $stagingPathLabel @($signButton, $fullProcessButton, $stageBuildButton, $stageRefreshButton, $stageDeleteButton)

$zxpHelp = New-Label 'Packages are read from the selected root; signatures are verified again before installation.' 18 16 920 30
$zxpList = New-Object System.Windows.Forms.DataGridView
$zxpList.AllowUserToAddRows = $false
$zxpList.AllowUserToDeleteRows = $false
$zxpList.AllowUserToResizeRows = $false
$zxpList.AutoGenerateColumns = $false
$zxpList.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$zxpList.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$zxpList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$zxpList.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$zxpList.RowHeadersVisible = $false
$zxpList.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$zxpList.MultiSelect = $false
$zxpList.ReadOnly = $true
$zxpList.Dock = 'Fill'
$zxpList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$zxpList.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$zxpList.ForeColor = [System.Drawing.Color]::White
$zxpList.EnableHeadersVisualStyles = $false
$zxpList.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(49, 58, 72)
$zxpList.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$zxpList.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$zxpList.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$zxpList.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(55, 75, 100)
$zxpList.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$zxpList.RowTemplate.Height = 30
$zxpColumns = @(
    @{ Name = 'Version'; Header = 'Version'; Weight = 16 }
    @{ Name = 'Package'; Header = 'Package'; Weight = 32 }
    @{ Name = 'Size'; Header = 'Size'; Weight = 10 }
    @{ Name = 'LastModified'; Header = 'Last modified'; Weight = 19 }
    @{ Name = 'Signature'; Header = 'Signature'; Weight = 16 }
    @{ Name = 'Timestamp'; Header = 'Timestamp'; Weight = 16 }
    @{ Name = 'CertificateSerial'; Header = 'Certificate serial'; Weight = 20 }
)
foreach ($columnDefinition in $zxpColumns) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $columnDefinition.Name
    $column.HeaderText = $columnDefinition.Header
    $column.ReadOnly = $true
    $column.FillWeight = $columnDefinition.Weight
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    [void]$zxpList.Columns.Add($column)
}
$selectedZxpLabel = New-Label 'Selected ZXP: no packages found' 18 288 920 58
$selectedZxpLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$zxpRefreshButton = New-Button 'Refresh List' 18 340 150
$zxpVerifyButton = New-Button 'Verify Signature' 180 340 180
$zxpInstallButton = New-Button 'Install...' 372 340 150
$zxpDeleteButton = New-Button 'Delete Selected ZXP...' 534 340 220
$zxpImportButton = New-Button 'Import ZXP...' 770 340 160
$zxpOpenFolderButton = New-Button 'Show Selected in Folder' 938 340 185
Set-ResponsiveTabLayout $zxpTab @($zxpHelp) $zxpList $selectedZxpLabel @($zxpRefreshButton, $zxpVerifyButton, $zxpInstallButton, $zxpDeleteButton, $zxpImportButton, $zxpOpenFolderButton) | Out-Null

$cepDebugLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cepDebugLayout.Dock = 'Fill'
$cepDebugLayout.ColumnCount = 1
$cepDebugLayout.RowCount = 4
$cepDebugLayout.Padding = New-Object System.Windows.Forms.Padding(12)
[void]$cepDebugLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$cepDebugLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$cepDebugLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$cepDebugLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$cepDebugLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$cepDebugHelp = New-Label 'Switch PlayerDebugMode for all supported CEP versions with Enable All or Disable All, then apply the changes. Restart Illustrator after applying.' 0 0 900 42
$cepDebugHelp.Dock = 'Fill'
$cepDebugHelp.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$cepDebugHelp.ForeColor = [System.Drawing.Color]::FromArgb(200, 210, 222)
$cepDebugLayout.Controls.Add($cepDebugHelp, 0, 0)
$playerDebugModeList = New-Object System.Windows.Forms.DataGridView
$playerDebugModeList.AllowUserToAddRows = $false
$playerDebugModeList.AllowUserToDeleteRows = $false
$playerDebugModeList.AllowUserToResizeRows = $false
$playerDebugModeList.AutoGenerateColumns = $false
$playerDebugModeList.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$playerDebugModeList.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$playerDebugModeList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$playerDebugModeList.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$playerDebugModeList.RowHeadersVisible = $false
$playerDebugModeList.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
$playerDebugModeList.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
$playerDebugModeList.Dock = 'Fill'
$playerDebugModeList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$playerDebugModeList.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$playerDebugModeList.ForeColor = [System.Drawing.Color]::White
$playerDebugModeList.EnableHeadersVisualStyles = $false
$playerDebugModeList.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(49, 58, 72)
$playerDebugModeList.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$playerDebugModeList.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 35)
$playerDebugModeList.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$playerDebugModeList.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(55, 75, 100)
$playerDebugModeList.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$versionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$versionColumn.Name = 'Version'
$versionColumn.HeaderText = 'CEP version'
$versionColumn.ReadOnly = $true
$versionColumn.FillWeight = 22
$enabledColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$enabledColumn.Name = 'Enabled'
$enabledColumn.HeaderText = 'Enabled'
$enabledColumn.FillWeight = 20
$enabledColumn.ThreeState = $false
$stateColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$stateColumn.Name = 'CurrentState'
$stateColumn.HeaderText = 'Current registry state'
$stateColumn.ReadOnly = $true
$stateColumn.FillWeight = 58
[void]$playerDebugModeList.Columns.Add($versionColumn)
[void]$playerDebugModeList.Columns.Add($enabledColumn)
[void]$playerDebugModeList.Columns.Add($stateColumn)
$cepDebugLayout.Controls.Add($playerDebugModeList, 0, 1)
$playerDebugModeStatusLabel = New-Label 'Select Enabled checkboxes to stage changes.' 0 0 900 36
$playerDebugModeStatusLabel.Dock = 'Fill'
$playerDebugModeStatusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 8)
$playerDebugModeStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
$cepDebugLayout.Controls.Add($playerDebugModeStatusLabel, 0, 2)
$playerDebugModeActions = New-Object System.Windows.Forms.FlowLayoutPanel
$playerDebugModeActions.Dock = 'Fill'
$playerDebugModeActions.AutoSize = $true
$playerDebugModeActions.WrapContents = $true
$playerDebugModeActions.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$playerDebugModeActions.Margin = New-Object System.Windows.Forms.Padding(0)
$playerDebugModeRefreshButton = New-Button 'Refresh' 0 0 85
$playerDebugModeEnableButton = New-Button 'Enable All' 0 0 110
$playerDebugModeDisableButton = New-Button 'Disable All' 0 0 110
$playerDebugModeApplyButton = New-Button 'Apply Changes' 0 0 125
$playerDebugModeApplyButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$playerDebugModeApplyButton.BackColor = [System.Drawing.Color]::FromArgb(43, 112, 181)
$playerDebugModeApplyButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(89, 160, 225)
$playerDebugModeApplyButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(56, 132, 205)
$playerDebugModeApplyButton.Enabled = $false
foreach ($button in @(
        $playerDebugModeRefreshButton,
        $playerDebugModeEnableButton,
        $playerDebugModeDisableButton,
        $playerDebugModeApplyButton
    )) {
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 4)
    $playerDebugModeActions.Controls.Add($button)
}
$cepDebugLayout.Controls.Add($playerDebugModeActions, 0, 3)
$cepDebugTab.Controls.Add($cepDebugLayout)
Update-PlayerDebugModeList

$aboutLayout = New-Object System.Windows.Forms.TableLayoutPanel
$aboutLayout.Dock = 'Fill'
$aboutLayout.ColumnCount = 1
$aboutLayout.RowCount = 4
$aboutLayout.Padding = New-Object System.Windows.Forms.Padding(24, 22, 24, 18)
[void]$aboutLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$aboutLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
[void]$aboutLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 76)))
[void]$aboutLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$aboutLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 88)))
$aboutTitle = New-Label 'About ZXP Manager for Adobe Illustrator' 0 0 900 32
$aboutTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$aboutTitle.ForeColor = [System.Drawing.Color]::White
$aboutTitle.Dock = 'Fill'
$aboutDescription = New-Label 'Prepare Adobe Illustrator CEP extension staging folders, create and verify signed ZXP packages, and install them locally through Adobe UPIA.' 0 0 900 68
$aboutDescription.Dock = 'Fill'
$aboutDescription.ForeColor = [System.Drawing.Color]::FromArgb(200, 210, 222)
$aboutDescription.AutoEllipsis = $true
$aboutLinks = New-Object System.Windows.Forms.FlowLayoutPanel
$aboutLinks.Dock = 'Fill'
$aboutLinks.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$aboutLinks.WrapContents = $false
$aboutLinks.AutoSize = $false
$aboutLinks.Margin = New-Object System.Windows.Forms.Padding(0)
$aboutLinkDefinitions = @(
    @{ Text = 'Source code'; Url = 'https://github.com/generativearts/zxp-manager-for-illustrator' }
    @{ Text = 'MIT License'; Url = 'https://github.com/generativearts/zxp-manager-for-illustrator/blob/main/LICENSE' }
)
foreach ($linkDefinition in $aboutLinkDefinitions) {
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $linkDefinition.Text
    $link.Tag = $linkDefinition.Url
    $link.AutoSize = $true
    $link.Margin = New-Object System.Windows.Forms.Padding(0, 7, 18, 0)
    $link.LinkColor = [System.Drawing.Color]::FromArgb(115, 180, 245)
    $link.ActiveLinkColor = [System.Drawing.Color]::FromArgb(155, 205, 255)
    $link.VisitedLinkColor = [System.Drawing.Color]::FromArgb(160, 178, 200)
    $link.Links.Add(0, $link.Text.Length, $linkDefinition.Url) | Out-Null
    $link.Add_LinkClicked({
        param($sender, $eventArgs)
        try {
            Start-Process -FilePath ([string]$eventArgs.Link.LinkData) -ErrorAction Stop
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Could not open the link:`r`n$($_.Exception.Message)",
                'Link Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
    $aboutLinks.Controls.Add($link)
}
$aboutNotice = New-Label 'ZXP Manager is MIT licensed; third-party components, including Adobe ZXPSignCmd, retain their own terms. Self-signed certificates are for local testing, not production publishing.' 0 0 900 80
$aboutNotice.Dock = 'Fill'
$aboutNotice.ForeColor = [System.Drawing.Color]::FromArgb(255, 195, 110)
$aboutNotice.AutoEllipsis = $true
$aboutLayout.Controls.Add($aboutTitle, 0, 0)
$aboutLayout.Controls.Add($aboutDescription, 0, 1)
$aboutLayout.Controls.Add($aboutLinks, 0, 2)
$aboutLayout.Controls.Add($aboutNotice, 0, 3)
$aboutTab.Controls.Add($aboutLayout)

$statusLabel = New-Label 'Ready' 22 635 400 22
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 210, 145)
$form.Controls.Add($statusLabel)
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(20, 660)
$logBox.Size = New-Object System.Drawing.Size(990, 100)
$logBox.Anchor = 'Top, Bottom, Left, Right'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(20, 23, 29)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225, 230, 238)
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$copyLogSelectionItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy selected text')
$copyLogSelectionItem.Enabled = $false
$copyLogSelectionItem.Add_Click({
    if ($logBox.SelectionLength -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($logBox.SelectedText)
    }
})
$logContextMenu.Items.Add($copyLogSelectionItem) | Out-Null
$logContextMenu.Add_Opening({
    $copyLogSelectionItem.Enabled = $logBox.SelectionLength -gt 0
})
$logBox.ContextMenuStrip = $logContextMenu
$form.Controls.Add($logBox)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = 'Fill'
$mainLayout.Padding = New-Object System.Windows.Forms.Padding(20)
$mainLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 4
[void]$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 430)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 25)))

foreach ($control in @($title, $tabs, $logBox, $statusLabel)) {
    [void]$form.Controls.Remove($control)
    $control.Dock = 'Fill'
    $control.Margin = New-Object System.Windows.Forms.Padding(0)
    $mainLayout.Controls.Add($control, 0, $mainLayout.Controls.Count)
}
$title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tabs.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
$form.Controls.Add($mainLayout)

$script:workflowState = $null
$script:activeOutputFiles = @()
$script:readOffsets = @{}
$script:pendingZxpVerificationPath = ''
$workflowTimer = New-Object System.Windows.Forms.Timer
$workflowTimer.Interval = 250
$workflowTimer.Add_Tick({
    if (-not $script:workflowState -or -not $script:workflowState.Process) { return }
    $workflow = $script:workflowState
    try {
        $process = $workflow.Process
        $process.Refresh()
        if (-not $process.HasExited) { return }

        $process.WaitForExit()
        if (-not (Test-Path -LiteralPath $workflow.CurrentExitCodePath -PathType Leaf)) {
            $stderr = Read-WorkflowOutput -Path $workflow.CurrentStderrPath
            $message = 'The workflow runner exited without writing its exit code file.'
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $message += [Environment]::NewLine + $stderr.Trim()
            }
            Complete-Workflow -ErrorMessage $message
            return
        }
        $exitCodeText = [System.IO.File]::ReadAllText($workflow.CurrentExitCodePath).Trim()
        if ($exitCodeText -notmatch '^-?\d+$') {
            throw "Workflow runner wrote an invalid exit code: '$exitCodeText'."
        }
        $exitCode = [int]$exitCodeText
        $stdout = if (Test-Path -LiteralPath $workflow.CurrentStdoutPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($workflow.CurrentStdoutPath)
        }
        else {
            ''
        }
        $stderr = if (Test-Path -LiteralPath $workflow.CurrentStderrPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($workflow.CurrentStderrPath)
        }
        else {
            ''
        }
        [void](Read-WorkflowOutput -Path $workflow.CurrentStdoutPath)
        [void](Read-WorkflowOutput -Path $workflow.CurrentStderrPath)
        $step = $workflow.Steps[$workflow.StepIndex]
        $workflow.StepOutputs.Add([pscustomobject]@{
            ScriptPath = $step.ScriptPath
            Text = $stdout + [Environment]::NewLine + $stderr
        })
        $process.Dispose()
        $workflow.Process = $null

        if ($exitCode -ne 0) {
            $detailLines = @()
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { $detailLines += $stderr.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($stdout)) { $detailLines += $stdout.Trim() }
            $details = $detailLines -join [Environment]::NewLine
            $message = "Step '$($step.Label)' failed with exit code $exitCode."
            if (-not [string]::IsNullOrWhiteSpace($details)) {
                $message += [Environment]::NewLine + $details
            }
            Complete-Workflow -ErrorMessage $message
            return
        }

        Add-Log "Completed: $($step.Label)" ([System.Drawing.Color]::FromArgb(120, 210, 145))
        $workflow.StepIndex++
        if ($workflow.StepIndex -lt $workflow.Steps.Count) {
            Start-WorkflowStepProcess
        }
        else {
            Complete-Workflow
        }
    }
    catch {
        Complete-Workflow -ErrorMessage (Get-WorkflowErrorMessage -Exception $_.Exception)
    }
})
$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 250
$logTimer.Add_Tick({
    if (-not $script:workflowState) { return }
    foreach ($path in $script:activeOutputFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $offset = if ($script:readOffsets.ContainsKey($path)) { [long]$script:readOffsets[$path] } else { 0L }
        $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$stream.Seek($offset, 'Begin')
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { Add-Log $line }
                }
                $script:readOffsets[$path] = $stream.Position
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
})

$settingsTimer = New-Object System.Windows.Forms.Timer
$settingsTimer.Interval = 700
$settingsTimer.Add_Tick({ $settingsTimer.Stop(); Save-Settings })
foreach ($textBox in @($projectPathBox, $stagingPathBox, $zxpPathBox, $certificatesPathBox, $signToolPathBox, $timestampBox)) {
    $textBox.Add_TextChanged({
        $settingsTimer.Stop()
        $settingsTimer.Start()
    })
}
    $signToolPathBox.Add_TextChanged({ Update-SignToolStatus })
    $projectPathBox.Add_TextChanged({ Update-BaseProjectVersion })
$projectSelector.Add_SelectedIndexChanged({
    if ($script:suppressProjectSwitch -or -not $projectSelector.SelectedItem) {
        return
    }
    $selectedRoot = [string]$projectSelector.SelectedItem.ProjectRoot
    if (-not $selectedRoot.Equals([string]$settings.ActiveProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            Set-ActiveProject -ProjectRoot $selectedRoot
        }
        catch {
            $message = Get-WorkflowErrorMessage -Exception $_.Exception
            [void][System.Windows.Forms.MessageBox]::Show($message, 'Could Not Switch Project', 'OK', 'Error')
            Update-ProjectSelector
        }
    }
})
$addProjectButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select a CEP project folder containing CSXS\manifest.xml.'
    $dialog.SelectedPath = $projectPathBox.Text
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            Add-Project -ProjectRoot $dialog.SelectedPath
        }
        catch {
            $message = Get-WorkflowErrorMessage -Exception $_.Exception
            [void][System.Windows.Forms.MessageBox]::Show($message, 'Could Not Add Project', 'OK', 'Error')
        }
    }
    $dialog.Dispose()
})
$removeProjectButton.Add_Click({
    try {
        Remove-ActiveProject
    }
    catch {
        $message = Get-WorkflowErrorMessage -Exception $_.Exception
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Could Not Remove Project', 'OK', 'Error')
    }
})
$stagingPathBox.Add_LostFocus({ Refresh-StagingVersions })
$zxpPathBox.Add_LostFocus({ Refresh-ZxpVersions })
$certificatesPathBox.Add_LostFocus({ Refresh-Certificates })
$certificateList.Add_SelectionChanged({
    if (-not $script:updatingCertificateGrid) {
        Save-Settings
        Update-SelectedCertificateDetails
    }
})
$certDescriptionButton.Add_Click({ Edit-SelectedCertificateDescription })
$stagingVersionList.Add_SelectionChanged({
    if (-not $script:updatingStagingGrid) {
        Update-SelectedStagingPath
    }
})
$zxpList.Add_SelectionChanged({
    if (-not $script:updatingZxpGrid) {
        Update-SelectedZxp
    }
})
$playerDebugModeList.Add_CurrentCellDirtyStateChanged({
    if ($playerDebugModeList.IsCurrentCellDirty) {
        $playerDebugModeList.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$playerDebugModeList.Add_CellValueChanged({
    param($sender, $eventArgs)
    if ($script:updatingPlayerDebugModeGrid -or
        $eventArgs.ColumnIndex -ne 1) {
        return
    }
    $rowIndex = $eventArgs.RowIndex
    if ($rowIndex -lt 0 -or $rowIndex -ge $playerDebugModeList.Rows.Count) {
        return
    }
    $version = [string]$playerDebugModeList.Rows[$rowIndex].Cells[0].Value
    $script:pendingPlayerDebugModeVersions.Add($version) | Out-Null
    $script:pendingPlayerDebugModeValues[$version] = [bool]$playerDebugModeList.Rows[$rowIndex].Cells[1].Value
    $pendingState = if ($script:pendingPlayerDebugModeValues[$version]) { 'Enabled' } else { 'Disabled' }
    $playerDebugModeList.Rows[$rowIndex].Cells[2].Value = "$pendingState (pending)"
    Update-PlayerDebugModeStatus
})
$playerDebugModeRefreshButton.Add_Click({
    if ($script:pendingPlayerDebugModeVersions.Count -gt 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Discard all pending checkbox changes and reload the registry values?',
            'Discard Pending Changes',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
        $script:pendingPlayerDebugModeVersions.Clear()
        $script:pendingPlayerDebugModeValues.Clear()
    }
    Update-PlayerDebugModeList
})
$playerDebugModeEnableButton.Add_Click({ Set-PlayerDebugModeAll -Enabled $true })
$playerDebugModeDisableButton.Add_Click({ Set-PlayerDebugModeAll -Enabled $false })
$playerDebugModeApplyButton.Add_Click({
    try { Apply-PlayerDebugModeChanges }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Could Not Apply PlayerDebugMode Changes',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $cepDebugTab) {
        Update-PlayerDebugModeList
    }
})

$certRefreshButton.Add_Click({ Refresh-Certificates; Add-Log "Certificate scan complete: $($certificateList.Rows.Count) certificate(s)." })
$certOpenFolderButton.Add_Click({
    $certificateRoot = $certificatesPathBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($certificateRoot) -or
        -not (Test-Path -LiteralPath $certificateRoot -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'The certificate folder does not exist. Update the path on the Projects & Settings tab or create the folder first.',
            'Certificate Folder Not Found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    try {
        $certificateRoot = [System.IO.Path]::GetFullPath($certificateRoot)
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $certificateRoot) -ErrorAction Stop | Out-Null
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not open the certificate folder:`r`n$($_.Exception.Message)",
            'Could Not Open Certificate Folder',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})
$certNewButton.Add_Click({
    if (-not (Test-SignToolAvailable)) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Create a self-signed test certificate? It is not suitable for production publishing.',
        'Create Test Certificate', 'YesNo', 'Warning'
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Workflow 'Create Test Certificate' @(
            (New-WorkflowStep 'Create Test Certificate' $scriptPaths.CreateCertificate @('-CertificatesDirectory', $certificatesPathBox.Text.Trim(), '-ProjectRoot', $projectPathBox.Text.Trim(), '-SignToolPath', $signToolPathBox.Text.Trim()))
        )
    }
})
$certImportButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Import Certificate with Private Key'
    $dialog.Filter = 'PKCS#12 certificate (*.p12;*.pfx)|*.p12;*.pfx'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        $dialog.Dispose()
        return
    }
    $sourcePath = $dialog.FileName
    $dialog.Dispose()
    if ((Get-Item -LiteralPath $sourcePath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [void][System.Windows.Forms.MessageBox]::Show('The selected certificate is a reparse point. Operation denied.', 'Unsafe Path', 'OK', 'Error')
        return
    }
    $password = Get-PasswordFromDialog 'Certificate Password' 'Enter the password for the selected .p12/.pfx file:'
    if ($null -eq $password) { return }
    $certificate = $null
    $destinationCertificate = $null
    $destinationPassword = $null
    $createdCertificateFile = $false
    $createdPasswordFile = $false
    try {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $sourcePath,
            $password,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        )
        if (-not $certificate.HasPrivateKey) {
            throw 'The selected file does not contain the private key required for signing.'
        }
        $serial = $certificate.SerialNumber.ToUpperInvariant()
        $root = [System.IO.Path]::GetFullPath($certificatesPathBox.Text.Trim())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $destinationCertificate = Join-Path $root "$serial.p12"
        $destinationPassword = Join-Path $root "$serial.password.txt"
        if ((Test-Path -LiteralPath $destinationCertificate) -or (Test-Path -LiteralPath $destinationPassword)) {
            throw "A certificate with serial number $serial already exists in the selected folder; existing files were not overwritten."
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationCertificate
        $createdCertificateFile = $true
        [System.IO.File]::WriteAllText($destinationPassword, $password, [System.Text.UTF8Encoding]::new($false))
        $createdPasswordFile = $true
        Set-RestrictedFileAcl $destinationCertificate
        Set-RestrictedFileAcl $destinationPassword
        Add-Log "Imported certificate $serial into '$root'." ([System.Drawing.Color]::FromArgb(120, 210, 145))
        Refresh-Certificates
    }
    catch {
        if ($createdCertificateFile -and $destinationCertificate -and (Test-Path -LiteralPath $destinationCertificate)) {
            Remove-Item -LiteralPath $destinationCertificate -Force
        }
        if ($createdPasswordFile -and $destinationPassword -and (Test-Path -LiteralPath $destinationPassword)) {
            Remove-Item -LiteralPath $destinationPassword -Force
        }
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Certificate Import Failed', 'OK', 'Error')
    }
    finally {
        if ($certificate) { $certificate.Dispose() }
        $password = $null
    }
})

$stageBuildButton.Add_Click({
    try {
        $source = [System.IO.Path]::GetFullPath($projectPathBox.Text.Trim())
        $root = [System.IO.Path]::GetFullPath($stagingPathBox.Text.Trim())
        $version = Get-ProjectVersion $source
        $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $source
        $versionDirectory = Join-Path $root (Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $version)
        if (Test-Path -LiteralPath (Join-Path $versionDirectory 'staging')) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Staging version $version already exists. Preparation will replace only its payload:`r`n$versionDirectory",
                'Replace Staging Version?', 'YesNo', 'Warning'
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Start-Workflow "Prepare Staging $version" @(
            (New-WorkflowStep "Prepare Staging $version" $scriptPaths.Stage @('-ProjectRoot', $source, '-StagingRoot', $root))
        )
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Staging Error', 'OK', 'Error')
    }
})
$stageRefreshButton.Add_Click({ Refresh-StagingVersions; Add-Log "Staging versions found: $($stagingVersionList.Rows.Count)." })
$stageDeleteButton.Add_Click({
    $item = Get-SelectedStaging
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a staging version.', 'No Selection', 'OK', 'Warning')
        return
    }
    $directory = [System.IO.Path]::GetFullPath($item.Directory)
    $root = [System.IO.Path]::GetFullPath($stagingPathBox.Text.Trim())
    if (-not (Test-DirectChildPath $root $directory)) {
        [void][System.Windows.Forms.MessageBox]::Show('The selected version is not a direct child folder of the staging root. Operation denied.', 'Unsafe Path', 'OK', 'Error')
        return
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('The selected staging folder no longer exists. Refresh the version list.', 'Staging Not Found', 'OK', 'Warning')
        Refresh-StagingVersions
        return
    }
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [void][System.Windows.Forms.MessageBox]::Show('The staging folder is a reparse point. Operation denied.', 'Unsafe Path', 'OK', 'Error')
        return
    }
    if (Get-ChildItem -LiteralPath $directory -Force -Recurse | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }) {
        [void][System.Windows.Forms.MessageBox]::Show('Staging contains a reparse point; automatic deletion is unsafe. Operation denied.', 'Unsafe Contents', 'OK', 'Error')
        return
    }
    if (Get-ChildItem -LiteralPath $directory -Filter '*.zxp' -File) {
        [void][System.Windows.Forms.MessageBox]::Show('A ZXP package is still in the staging folder. Import it into the separate package folder from the ZXP tab, then confirm moving/deleting the source file.', 'Package Not Moved', 'OK', 'Warning')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete staging version $($item.Version)?`r`n$directory", 'Confirm Deletion', 'YesNo', 'Warning')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item -LiteralPath $directory -Recurse -Force
        Add-Log "Deleted staging version $($item.Version)." ([System.Drawing.Color]::FromArgb(255, 170, 100))
        Refresh-StagingVersions
    }
})

$signButton.Add_Click({
    if (-not (Test-SignToolAvailable)) { return }
    $certificateSerial = Get-SelectedCertificateSerial
    $staging = Get-SelectedStaging
    if (-not $certificateSerial -or -not $staging) {
        [void][System.Windows.Forms.MessageBox]::Show('Select an available certificate and staging version.', 'Missing Information', 'OK', 'Warning')
        return
    }
    $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $projectPathBox.Text.Trim()
    $output = Join-Path $zxpPathBox.Text.Trim() (Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $staging.Version)
    if (Test-Path -LiteralPath $output) {
        [void][System.Windows.Forms.MessageBox]::Show("The ZXP already exists and will not be overwritten:`r`n$output", 'Package Already Exists', 'OK', 'Information')
        return
    }
    try {
        if (-not (Ensure-CertificatePasswordFile -Serial $certificateSerial)) { return }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Certificate Password Error', 'OK', 'Error')
        return
    }
    $arguments = @(
        '-CertificateSerial', $certificateSerial,
        '-TimestampUrl', $timestampBox.Text.Trim(),
        '-ProjectRoot', $projectPathBox.Text.Trim(),
        '-StagingDirectory', $staging.Payload,
        '-OutputPath', $output,
        '-CertificatesDirectory', $certificatesPathBox.Text.Trim(),
        '-SignToolPath', $signToolPathBox.Text.Trim()
    )
    Start-Workflow "Create ZXP Package $($staging.Version)" @(
        (New-WorkflowStep 'Create and Verify ZXP Package' $scriptPaths.Sign $arguments)
    ) -VerificationPath $output
})
$fullProcessButton.Add_Click({
    if (-not (Test-SignToolAvailable)) { return }
    $certificateSerial = Get-SelectedCertificateSerial
    if (-not $certificateSerial) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a certificate first.', 'No Certificate Selected', 'OK', 'Warning')
        return
    }
    try {
        $source = [System.IO.Path]::GetFullPath($projectPathBox.Text.Trim())
        $version = Get-ProjectVersion $source
        $projectMetadata = Get-ZxpProjectMetadata -ProjectRoot $source
        $stageDirectory = Join-Path ([System.IO.Path]::GetFullPath($stagingPathBox.Text.Trim())) (Get-ZxpReleaseDirectoryName -PackageName $projectMetadata.PackageName -Version $version)
        $certRoot = [System.IO.Path]::GetFullPath($certificatesPathBox.Text.Trim())
        $output = Join-Path $zxpPathBox.Text.Trim() (Get-ZxpPackageFileName -PackageName $projectMetadata.PackageName -Version $version)
        if (Test-Path -LiteralPath $output) {
            [void][System.Windows.Forms.MessageBox]::Show("The ZXP already exists and will not be overwritten:`r`n$output", 'Package Already Exists', 'OK', 'Information')
            return
        }
        if (Test-Path -LiteralPath $stageDirectory) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Staging version $version already exists. Replace only its contents and create a new ZXP? The existing package will not be overwritten.",
                'Replace Staging?', 'YesNo', 'Warning'
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if (Get-Process -Name Illustrator -ErrorAction SilentlyContinue) {
            throw 'Close Illustrator before running the full workflow.'
        }
        $installAnswer = [System.Windows.Forms.MessageBox]::Show(
            "The package will be installed via UPIA after it is created and verified:`r`n$output`r`n`r`nIllustrator must remain closed. Continue?",
            'Confirm Full Workflow',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($installAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            if (-not (Ensure-CertificatePasswordFile -Serial $certificateSerial)) { return }
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Certificate Password Error', 'OK', 'Error')
            return
        }
        $arguments = @(
            '-CertificateSerial', $certificateSerial,
            '-TimestampUrl', $timestampBox.Text.Trim(),
            '-ProjectRoot', $source,
            '-StagingDirectory', (Join-Path $stageDirectory 'staging'),
            '-OutputPath', $output,
            '-CertificatesDirectory', $certRoot,
            '-SignToolPath', $signToolPathBox.Text.Trim()
        )
        $steps = @(
            (New-WorkflowStep "Prepare Staging $version" $scriptPaths.Stage @('-ProjectRoot', $source, '-StagingRoot', $stagingPathBox.Text.Trim())),
            (New-WorkflowStep 'Sign and Automatically Verify ZXP' $scriptPaths.Sign $arguments),
            (New-WorkflowStep 'Verify Signature and Install via UPIA' $scriptPaths.Install @('-ZxpPath', $output, '-ProjectRoot', $source, '-SignToolPath', $signToolPathBox.Text.Trim()))
        )
        Start-Workflow "Build and Install ZXP $version" $steps -VerificationPath $output
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ZXP Creation Error', 'OK', 'Error')
    }
})

$zxpRefreshButton.Add_Click({ Refresh-ZxpVersions; Add-Log "ZXP packages found: $($zxpList.Rows.Count)." })
$zxpOpenFolderButton.Add_Click({
    $item = Get-SelectedZxp
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Select a ZXP package to show it in File Explorer.',
            'No Package Selected',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'The selected ZXP package no longer exists. Refresh the package list and try again.',
            'Package Not Found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    try {
        $packagePath = [System.IO.Path]::GetFullPath([string]$item.Path)
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $packagePath) -ErrorAction Stop | Out-Null
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not show the selected ZXP package in File Explorer:`r`n$($_.Exception.Message)",
            'Could Not Show Package',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})
$zxpImportButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Import Existing ZXP into Package Folder'
    $dialog.Filter = 'ZXP package (*.zxp)|*.zxp'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        $dialog.Dispose()
        return
    }
    $source = $dialog.FileName
    $dialog.Dispose()
    try {
        $manifest = Read-ZxpManifest $source
        $version = [string]$manifest.ExtensionManifest.GetAttribute('ExtensionBundleVersion')
        if ($version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
            throw 'The selected ZXP has an invalid version in its manifest.'
        }
        $destinationRoot = [System.IO.Path]::GetFullPath($zxpPathBox.Text.Trim())
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
        $bundleName = $manifest.ExtensionManifest.GetAttribute('ExtensionBundleName')
        $bundleId = $manifest.ExtensionManifest.GetAttribute('ExtensionBundleId')
        $packageName = Get-ZxpPackageNameFromBundle -BundleName $bundleName -BundleId $bundleId
        $destination = Join-Path $destinationRoot (Get-ZxpPackageFileName -PackageName $packageName -Version $version)
        if (Test-Path -LiteralPath $destination) {
            throw "A ZXP for version $version already exists in the package folder; the file was not overwritten: $destination"
        }
        Copy-Item -LiteralPath $source -Destination $destination
        Add-Log "Imported ZXP $version into '$destinationRoot'." ([System.Drawing.Color]::FromArgb(120, 210, 145))
        $stagingRoot = [System.IO.Path]::GetFullPath($stagingPathBox.Text.Trim()).TrimEnd('\') + '\'
        $sourceFullPath = [System.IO.Path]::GetFullPath($source)
        if ($sourceFullPath.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $removeSource = [System.Windows.Forms.MessageBox]::Show(
                "The package was copied. Delete its old copy from staging to keep the folders separate?`r`n$sourceFullPath",
                'Delete Old Copy?', 'YesNo', 'Question'
            )
            if ($removeSource -eq [System.Windows.Forms.DialogResult]::Yes) {
                Remove-Item -LiteralPath $sourceFullPath -Force
                Add-Log 'Deleted the old ZXP copy from staging.' ([System.Drawing.Color]::FromArgb(120, 210, 145))
                Refresh-StagingVersions
            }
        }
        Refresh-ZxpVersions
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ZXP Import Failed', 'OK', 'Error')
    }
})
$zxpVerifyButton.Add_Click({
    if (-not (Test-SignToolAvailable)) { return }
    $item = Get-SelectedZxp
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a ZXP package.', 'No Selection', 'OK', 'Warning')
        return
    }
    $verificationPath = [string]$item.Path
    Start-Workflow 'Verify ZXP' @(
        (New-WorkflowStep 'Verify Signature and Timestamp' $scriptPaths.Verify @('-ZxpPath', $item.Path, '-ProjectRoot', $projectPathBox.Text.Trim(), '-SignToolPath', $signToolPathBox.Text.Trim()))
    ) -VerificationPath $verificationPath
})
$zxpInstallButton.Add_Click({
    if (-not (Test-SignToolAvailable)) { return }
    $item = Get-SelectedZxp
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a ZXP package.', 'No Selection', 'OK', 'Warning')
        return
    }
    try {
        $steps = Get-InstallStep -Path $item.Path -ProjectRoot $projectPathBox.Text.Trim()
        if ($null -ne $steps) { Start-Workflow "Install ZXP $($item.Version)" $steps }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Installation Error', 'OK', 'Error')
    }
})
$zxpDeleteButton.Add_Click({
    $item = Get-SelectedZxp
    if (-not $item) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a ZXP package.', 'No Selection', 'OK', 'Warning')
        return
    }
    $root = [System.IO.Path]::GetFullPath($zxpPathBox.Text.Trim())
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('The ZXP packages root was not found. Update the path on the Projects & Settings tab.', 'Folder Not Found', 'OK', 'Warning')
        return
    }
    $filePath = [System.IO.Path]::GetFullPath($item.Path)
    $rootPrefix = $root.TrimEnd('\') + '\'
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [void][System.Windows.Forms.MessageBox]::Show('The ZXP root is a reparse point. Operation denied.', 'Unsafe Path', 'OK', 'Error')
        return
    }
    if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetExtension($filePath) -ine '.zxp' -or
        ((Get-Item -LiteralPath $filePath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        [void][System.Windows.Forms.MessageBox]::Show('The package is not a regular .zxp file in the selected root. Operation denied.', 'Unsafe Path', 'OK', 'Error')
        return
    }
    $parentDirectory = [System.IO.Path]::GetDirectoryName($filePath)
    while ($parentDirectory.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ((Get-Item -LiteralPath $parentDirectory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            [void][System.Windows.Forms.MessageBox]::Show('The path to the ZXP passes through a reparse point. Operation denied.', 'Unsafe Path', 'OK', 'Error')
            return
        }
        $parentDirectory = [System.IO.Path]::GetDirectoryName($parentDirectory)
    }
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete package version $($item.Version)?`r`n$filePath", 'Confirm Deletion', 'YesNo', 'Warning')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item -LiteralPath $filePath -Force
        Add-Log "Deleted ZXP version $($item.Version)." ([System.Drawing.Color]::FromArgb(255, 170, 100))
        Refresh-ZxpVersions
    }
})

$signToolBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select ZXPSignCmd.exe'
    $dialog.Filter = 'ZXPSignCmd executable (ZXPSignCmd.exe)|ZXPSignCmd.exe|Executable (*.exe)|*.exe'
    $dialog.CheckFileExists = $true
    $dialog.FileName = 'ZXPSignCmd.exe'
    $dialog.InitialDirectory = if (Test-Path -LiteralPath $signToolPathBox.Text -PathType Leaf) { Split-Path -Parent $signToolPathBox.Text } else { $toolDirectory }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $signToolPathBox.Text = $dialog.FileName
    }
    $dialog.Dispose()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:workflowState) {
        $eventArgs.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show('Wait for the current workflow to finish before closing the window.', 'Workflow in Progress', 'OK', 'Information')
        return
    }
    Save-Settings
})

Update-BaseProjectVersion
Update-SignToolStatus
Refresh-Certificates
Refresh-StagingVersions
Refresh-ZxpVersions
if ($ValidateOnly) {
    if ($tabs.DrawMode -ne [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed -or
        $tabs.ItemSize.Height -lt 30 -or
        $playerDebugModeApplyButton.BackColor.ToArgb() -eq ([System.Drawing.Color]::FromArgb(49, 58, 72).ToArgb()) -or
        ($playerDebugModeApplyButton.Font.Name -notlike '*Semibold*' -and
            $playerDebugModeApplyButton.Font.Style -ne [System.Drawing.FontStyle]::Bold)) {
        throw 'Apply Changes or active tab emphasis is not configured.'
    }
    if ($pathsFooter.Controls.IndexOf($signToolStatusLabel) -lt 0) {
        throw 'The ZXPSignCmd download link is not configured in Project Settings.'
    }
    $aboutSourceLink = @($aboutLinks.Controls | Where-Object { $_.Text -eq 'Source code' }) | Select-Object -First 1
    $aboutLicenseLink = @($aboutLinks.Controls | Where-Object { $_.Text -eq 'MIT License' }) | Select-Object -First 1
    if (-not $aboutSourceLink -or
        $aboutSourceLink.Links.Count -ne 1 -or
        $aboutSourceLink.Links[0].LinkData -ne 'https://github.com/generativearts/zxp-manager-for-illustrator' -or
        -not $aboutLicenseLink -or
        $aboutLicenseLink.Links.Count -ne 1 -or
        $aboutLicenseLink.Links[0].LinkData -ne 'https://github.com/generativearts/zxp-manager-for-illustrator/blob/main/LICENSE' -or
        $aboutNotice.Text -notmatch 'MIT licensed' -or
        $aboutNotice.Text -notmatch 'ZXPSignCmd') {
        throw 'About tab source, license links, or third-party licensing notice are missing.'
    }
    $originalSignToolPath = $signToolPathBox.Text
    try {
        $signToolPathBox.Text = Join-Path $env:TEMP ('ZXPSignCmd-missing-' + [guid]::NewGuid().ToString('N') + '.exe')
        Update-SignToolStatus
        if (-not $script:signToolDownloadRequired -or
            $signToolStatusLabel.Text -notmatch 'not found' -or
            $signToolStatusLabel.Links.Count -ne 1 -or
            $signToolStatusLabel.Links[0].LinkData -ne $script:signToolDownloadUrl) {
            throw 'The ZXPSignCmd download link is not shown when the executable is missing.'
        }
        $signToolPathBox.Text = Join-Path $toolDirectory 'zxp_manager_gui.ps1'
        Update-SignToolStatus
        if ($script:signToolDownloadRequired -or
            $signToolStatusLabel.Text -notmatch 'found' -or
            $signToolStatusLabel.Links.Count -ne 0) {
            throw 'The ZXPSignCmd download link remains visible when an executable path exists.'
        }
    }
    finally {
        $signToolPathBox.Text = $originalSignToolPath
        Update-SignToolStatus
        $settingsTimer.Stop()
    }
    $stateTest = New-WorkflowState -Name 'Validation' -Steps @(
        (New-WorkflowStep 'Validation step' $scriptPaths.Stage)
    )
    $stateTest.CurrentStdoutPath = 'stdout.log'
    $stateTest.CurrentStderrPath = 'stderr.log'
    if ($stateTest.CurrentStdoutPath -ne 'stdout.log' -or
        $stateTest.CurrentStderrPath -ne 'stderr.log' -or
        $stateTest.StepIndex -ne 0) {
        throw 'Workflow state initialization validation failed.'
    }
    if ([string]::IsNullOrWhiteSpace((Get-WorkflowErrorMessage -Exception $null))) {
        throw 'Null workflow exceptions must produce a readable error message.'
    }
    if ((Get-WorkflowErrorMessage -Exception ([System.Exception]::new('Validation error'))) -ne 'Validation error') {
        throw 'Workflow exception details are not preserved.'
    }
    foreach ($certificateRow in $certificateList.Rows) {
        $certificateItem = $certificateRow.Tag
        if ([string]::IsNullOrWhiteSpace([string]$certificateItem.Thumbprint)) {
            if ($certificateItem.Name -ne 'Password required' -or
                [string]$certificateItem.FileCreatedAt -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' -or
                -not [string]::IsNullOrWhiteSpace([string]$certificateItem.ValidFrom)) {
                throw "Certificate without a password file is not marked correctly for serial $($certificateItem.Serial)."
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$certificateItem.Thumbprint) -or
            [string]::IsNullOrWhiteSpace([string]$certificateItem.Name) -or
            [string]$certificateItem.FileCreatedAt -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' -or
            [string]$certificateItem.ValidFrom -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' -or
            [string]$certificateRow.Cells['Serial'].Value -ne [string]$certificateItem.Serial -or
            [string]$certificateRow.Cells['Name'].Value -ne [string]$certificateItem.Name -or
            [string]$certificateRow.Cells['FileCreated'].Value -ne [string]$certificateItem.FileCreatedAt) {
            throw "Certificate list details are incomplete for serial $($certificateItem.Serial)."
        }
    }
    $expectedZxpColumnWeights = @{
        Version = 16
        Signature = 16
        Timestamp = 16
        CertificateSerial = 20
    }
    foreach ($columnName in $expectedZxpColumnWeights.Keys) {
        if (-not $zxpList.Columns.Contains($columnName) -or
            $zxpList.Columns[$columnName].FillWeight -ne $expectedZxpColumnWeights[$columnName]) {
            throw "ZXP column '$columnName' is missing or has an unexpected width."
        }
    }
    if (-not $zxpList.Columns.Contains('Size') -or -not $zxpList.Columns.Contains('LastModified')) {
        throw 'ZXP size and last-modified columns are missing.'
    }
    if ($zxpList.Rows.Count -gt 0) {
        $validationPackage = $zxpList.Rows[0].Tag
        Update-ZxpVerificationStatus -Path $validationPackage.Path -Succeeded $true -Output "Timestamp: Valid and within certificate validity dates at time of signing`r`nSignature verified successfully`r`nSigning certificate serial number: 00B9F8355EEE4DDD7D"
        if ($validationPackage.SignatureStatus -ne 'Valid' -or
            $validationPackage.TimestampStatus -ne 'Valid' -or
            $validationPackage.SigningCertificateSerial -ne '00B9F8355EEE4DDD7D' -or
            [string]$zxpList.Rows[0].Cells['Size'].Value -ne (Format-ZxpFileSize -Bytes $validationPackage.SizeBytes) -or
            [string]$zxpList.Rows[0].Cells['LastModified'].Value -ne $validationPackage.LastModified -or
            $zxpList.Rows[0].Cells['Signature'].Value -ne 'Valid' -or
            $zxpList.Rows[0].Cells['Timestamp'].Value -ne 'Valid' -or
            $zxpList.Rows[0].Cells['CertificateSerial'].Value -ne '00B9F8355EEE4DDD7D') {
            throw 'ZXP signature and timestamp status display validation failed.'
        }
        Refresh-ZxpVersions
        $reloadedPackage = @($zxpList.Rows | ForEach-Object { $_.Tag } | Where-Object { $_.Path -eq $validationPackage.Path })[0]
        if ($reloadedPackage.SignatureStatus -ne 'Valid' -or
            $reloadedPackage.TimestampStatus -ne 'Valid' -or
            $reloadedPackage.SigningCertificateSerial -ne '00B9F8355EEE4DDD7D') {
            throw 'ZXP signature, timestamp, and signing certificate statuses did not survive a list refresh.'
        }
    }
    $originalZxpRoot = $zxpPathBox.Text
    $validationZxpRoot = Join-Path $env:TEMP ('ZxpManagerVerificationValidation-' + [guid]::NewGuid().ToString('N'))
    $validationZxpPath = Join-Path $validationZxpRoot 'validation-package.zxp'
    $validationArchive = $null
    New-Item -ItemType Directory -Path $validationZxpRoot -Force | Out-Null
    try {
        $validationArchive = [System.IO.Compression.ZipFile]::Open(
            $validationZxpPath,
            [System.IO.Compression.ZipArchiveMode]::Create
        )
        $manifestEntry = $validationArchive.CreateEntry('CSXS/manifest.xml')
        $manifestStream = $manifestEntry.Open()
        try {
            $manifestWriter = [System.IO.StreamWriter]::new($manifestStream)
            try {
                $manifestWriter.Write('<ExtensionManifest ExtensionBundleVersion="1.0.0" />')
            }
            finally {
                $manifestWriter.Dispose()
            }
        }
        finally {
            $manifestStream.Dispose()
        }
        $validationArchive.Dispose()
        $validationArchive = $null

        $zxpPathBox.Text = $validationZxpRoot
        Refresh-ZxpVersions
        $newPackage = Get-SelectedZxp
        if (-not $newPackage -or
            $newPackage.SignatureStatus -ne 'Not verified' -or
            $newPackage.TimestampStatus -ne 'Not verified' -or
            [string]$zxpList.Rows[0].Cells['Size'].Value -ne (Format-ZxpFileSize -Bytes $newPackage.SizeBytes) -or
            [string]$zxpList.Rows[0].Cells['LastModified'].Value -ne $newPackage.LastModified) {
            throw 'A newly scanned ZXP package must start as not verified.'
        }
        Update-SelectedZxp
        if ($selectedZxpLabel.Text -notmatch 'Size: .+ \| Modified: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' -or
            $selectedZxpLabel.Text -notmatch [regex]::Escape($newPackage.Path)) {
            throw 'Selected ZXP summary does not show file size, modification time, and path.'
        }

        Refresh-ZxpVersions
        Update-ZxpVerificationStatus -Path $validationZxpPath -Succeeded $true -Output "Timestamp: Valid and within certificate validity dates at time of signing`r`nSignature verified successfully`r`nSigning certificate serial number: 00B9F8355EEE4DDD7D"
        $newPackageRow = $null
        foreach ($row in $zxpList.Rows) {
            if ($row.Tag -and [string]$row.Tag.Path -eq $validationZxpPath) {
                $newPackageRow = $row
                break
            }
        }
        $newPackage = if ($newPackageRow) { $newPackageRow.Tag } else { $null }
        if (-not $newPackage -or
            $newPackage.SignatureStatus -ne 'Valid' -or
            $newPackage.TimestampStatus -ne 'Valid' -or
            $newPackage.SigningCertificateSerial -ne '00B9F8355EEE4DDD7D' -or
            $newPackageRow.Cells['Signature'].Value -ne 'Valid' -or
            $newPackageRow.Cells['Timestamp'].Value -ne 'Valid') {
            throw 'Verification status was not applied to a newly discovered ZXP package.'
        }
    }
    finally {
        if ($validationArchive) {
            $validationArchive.Dispose()
        }
        $zxpPathBox.Text = $originalZxpRoot
        Refresh-ZxpVersions
        Remove-Item -LiteralPath $validationZxpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $form.CreateControl()
    $tabs.CreateControl()
    foreach ($tab in @($pathsTab, $certificatesTab, $stagingTab, $zxpTab, $cepDebugTab, $aboutTab)) {
        $tab.CreateControl()
    }
    $form.PerformLayout()
    foreach ($width in @(900, 950, 1050, 1200, 1450)) {
        $form.Width = $width
        $tabs.Width = $width - 60
        $form.PerformLayout()
        $tabs.PerformLayout()
        $mainLayout.PerformLayout()
        $expectedRightEdge = $mainLayout.ClientSize.Width - $mainLayout.Padding.Right
        foreach ($control in @($title, $tabs, $statusLabel, $logBox)) {
            if ($control.Right -lt ($expectedRightEdge - 10)) {
                throw "Control '$($control.Name)' does not fill the available window width at form width $width`: right=$($control.Right), expected at least $($expectedRightEdge - 10)."
            }
        }
        foreach ($tab in @($pathsTab, $certificatesTab, $stagingTab, $zxpTab, $cepDebugTab, $aboutTab)) {
            $tab.Size = New-Object System.Drawing.Size(($tabs.ClientSize.Width - 8), ($tabs.ClientSize.Height - 28))
            $tab.PerformLayout()
            if ($tab -eq $cepDebugTab) {
                $cepDebugLayout.PerformLayout()
                $playerDebugModeList.PerformLayout()
                if ($playerDebugModeList.Width -lt ($cepDebugTab.ClientSize.Width - 60) -or
                    $playerDebugModeList.Height -lt 100 -or
                    $playerDebugModeList.Rows.Count -ne 7 -or
                    $playerDebugModeList.Columns.Count -ne 3 -or
                    $playerDebugModeList.Columns[1].Name -ne 'Enabled' -or
                    -not $playerDebugModeList.Columns[1].Visible) {
                    throw "PlayerDebugMode table does not fill the available space at form width $width`: bounds=$($playerDebugModeList.Bounds), tab=$($cepDebugTab.ClientSize)."
                }
                if ($playerDebugModeList.Columns[1].ReadOnly -or
                    $playerDebugModeList.Columns[0].Width -le 0 -or
                    $playerDebugModeList.Columns[1].Width -le 0 -or
                    $playerDebugModeList.Columns[2].Width -le 0) {
                    throw "PlayerDebugMode table columns are not visible/editable at form width $width."
                }
            }
            if ($tab -eq $zxpTab) {
                $zxpList.PerformLayout()
                if ($zxpList.Width -lt ($zxpTab.ClientSize.Width - 60) -or
                    $zxpList.Height -lt 100 -or
                    $zxpList.Columns.Count -ne 7 -or
                    -not $zxpList.ReadOnly -or
                    $zxpList.SelectionMode -ne [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect) {
                    throw "ZXP package table does not fill the available space at form width $width`: bounds=$($zxpList.Bounds), tab=$($zxpTab.ClientSize)."
                }
                foreach ($column in $zxpList.Columns) {
                    if (-not $column.Visible -or $column.Width -le 0) {
                        throw "ZXP package table column '$($column.Name)' is not visible at form width $width."
                    }
                }
                if ($tab -eq $stagingTab) {
                    $stagingVersionList.PerformLayout()
                    if ($stagingVersionList.Width -lt ($stagingTab.ClientSize.Width - 60) -or
                        $stagingVersionList.Height -lt 100 -or
                        $stagingVersionList.Columns.Count -ne 3 -or
                        -not $stagingVersionList.ReadOnly -or
                        $stagingVersionList.SelectionMode -ne [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect) {
                        throw "Staging table does not fill the available space at form width $width`: bounds=$($stagingVersionList.Bounds), tab=$($stagingTab.ClientSize)."
                    }
                    foreach ($column in $stagingVersionList.Columns) {
                        if (-not $column.Visible -or $column.Width -le 0) {
                            throw "Staging table column '$($column.Name)' is not visible at form width $width."
                        }
                    }
                    if ($tab -eq $certificatesTab) {
                        $certificateList.PerformLayout()
                        if ($certificateList.Width -lt ($certificatesTab.ClientSize.Width - 60) -or
                            $certificateList.Height -lt 100 -or
                            $certificateList.Columns.Count -ne 4 -or
                            -not $certificateList.ReadOnly -or
                            $certificateList.SelectionMode -ne [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect) {
                            throw "Certificate table does not fill the available space at form width $width`: bounds=$($certificateList.Bounds), tab=$($certificatesTab.ClientSize)."
                        }
                        foreach ($column in $certificateList.Columns) {
                            if (-not $column.Visible -or $column.Width -le 0) {
                                throw "Certificate table column '$($column.Name)' is not visible at form width $width."
                            }
                        }
                    }
                }
            }
            $controlsToCheck = New-Object System.Collections.Generic.Stack[System.Windows.Forms.Control]
            foreach ($child in $tab.Controls) {
                $controlsToCheck.Push($child)
            }
            while ($controlsToCheck.Count -gt 0) {
                $control = $controlsToCheck.Pop()
                $control.PerformLayout()
                if ($control.Right -gt $control.Parent.ClientSize.Width -or
                    $control.Bottom -gt $control.Parent.ClientSize.Height -or
                    $control.Left -lt 0 -or $control.Top -lt 0) {
                    throw "Control '$($control.Name)' exceeds its parent in tab '$($tab.Text)' at form width $width`: bounds=$($control.Bounds), parent=$($control.Parent.ClientSize)."
                }
                foreach ($child in $control.Controls) {
                    $controlsToCheck.Push($child)
                }
            }
        }
        $stagingActionPanel = $stagingTab.Controls[0].Controls[3]
        $stagingActionRows = @($stagingActionPanel.Controls | ForEach-Object { $_.Top } | Select-Object -Unique)
        if ($stagingActionRows.Count -lt 1 -or $stagingActionRows.Count -gt 2 -or
            $signButton.Top -ne $fullProcessButton.Top) {
            throw "Staging action buttons wrap at form width $width`: $($stagingActionRows.Count) rows."
        }
        if ($signButton.BackColor.ToArgb() -eq ([System.Drawing.Color]::FromArgb(49, 58, 72).ToArgb()) -or
            ($signButton.Font.Name -notlike '*Semibold*' -and
                $signButton.Font.Style -ne [System.Drawing.FontStyle]::Bold)) {
            throw 'Create ZXP Package from Staging does not have the primary-action emphasis.'
        }
        $debugActionRows = @($playerDebugModeActions.Controls | ForEach-Object { $_.Top } | Select-Object -Unique)
        if ($debugActionRows.Count -ne 1) {
            throw "CEP Debug action buttons wrap at form width $width`: $($debugActionRows.Count) rows."
        }
        foreach ($button in $browseButtons.Values) {
            if ($button.Width -lt 60) {
                throw "A settings browse button is too narrow at form width $width`: $($button.Width)px."
            }
        }
    }
    $form.Width = [Math]::Max(1050, [int]$settings.WindowWidth)
    $form.PerformLayout()
    if ($projectSelector.Items.Count -ne $settings.Projects.Count -or
        -not $projectPathBox.Text.Equals([string]$settings.ActiveProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Project selector and active project profile are out of sync.'
    }
    Set-PlayerDebugModeAll -Enabled $true
    if ($script:pendingPlayerDebugModeVersions.Count -ne 7 -or
        -not $playerDebugModeApplyButton.Enabled -or
        @($playerDebugModeList.Rows | Where-Object { -not [bool]$_.Cells[1].Value }).Count -ne 0) {
        throw 'Enable All did not stage enabled state for every CEP version.'
    }
    Set-PlayerDebugModeAll -Enabled $false
    if ($script:pendingPlayerDebugModeVersions.Count -ne 7 -or
        @($playerDebugModeList.Rows | Where-Object { [bool]$_.Cells[1].Value }).Count -ne 0) {
        throw 'Disable All did not stage disabled state for every CEP version.'
    }
    $script:pendingPlayerDebugModeVersions.Clear()
    $script:pendingPlayerDebugModeValues.Clear()
    Update-PlayerDebugModeList
    $validationVersions = @('10', '11', '12', '13', '14', '15', '16')
    $validationRegistryRoot = "Software\ZxpManagerValidation-$([guid]::NewGuid().ToString('N'))"
    try {
        Set-PlayerDebugModeAll -Enabled $true
        if ($script:pendingPlayerDebugModeVersions.Count -ne $validationVersions.Count) {
            throw 'Enable All did not stage every CEP version for application.'
        }
        Apply-PlayerDebugModeChanges -RegistryRoot $validationRegistryRoot -Confirmed
        if ($script:pendingPlayerDebugModeVersions.Count -ne 0) {
            throw 'Applying PlayerDebugMode changes did not clear the pending state.'
        }
        foreach ($version in $validationVersions) {
            $currentValue = Get-PlayerDebugModeCurrentValue -Version $version -RegistryRoot $validationRegistryRoot
            if (-not $currentValue.ValueExisted -or [string]$currentValue.Data -ne '1') {
                throw "Applying Enable All did not enable PlayerDebugMode for CEP $version."
            }
        }
    }
    finally {
        $script:pendingPlayerDebugModeVersions.Clear()
        $script:pendingPlayerDebugModeValues.Clear()
        foreach ($version in $validationVersions) {
            $testRegistryKeyPath = Get-PlayerDebugModeKeyPath -Version $version -RegistryRoot $validationRegistryRoot
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testRegistryKeyPath, $false)
        }
        Update-PlayerDebugModeList
    }
    for ($left = 0; $left -lt $settings.Projects.Count; $left++) {
        for ($right = $left + 1; $right -lt $settings.Projects.Count; $right++) {
            if ($settings.Projects[$left].ProjectRoot.Equals(
                    [string]$settings.Projects[$right].ProjectRoot,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Duplicate project profile found: $($settings.Projects[$left].ProjectRoot)"
            }
        }
    }
    $originalRoot = [string]$settings.ActiveProjectRoot
    $originalProfileCount = $settings.Projects.Count
    $validationRoot = Get-NormalizedProjectRoot -Path (Join-Path $env:TEMP ('ZxpManagerProfileValidation-' + [guid]::NewGuid().ToString('N')))
    $validationProfile = [pscustomobject]@{
        ProjectRoot = $validationRoot
        StagingRoot = Join-Path $validationRoot 'staging'
        ZxpRoot = Join-Path $validationRoot 'zxp_packages'
        CertificatesRoot = Join-Path $validationRoot 'certificates'
        SelectedCertificate = ''
        SelectedStagingVersion = ''
        SelectedZxpPath = ''
    }
    $settings.Projects = @($settings.Projects) + @($validationProfile)
    Update-ProjectSelector
    Set-ActiveProject -ProjectRoot $validationRoot
    $validationStagingRoot = Join-Path $validationRoot 'custom-staging'
    $stagingPathBox.Text = $validationStagingRoot
    Save-ActiveProjectSettings
    Set-ActiveProject -ProjectRoot $originalRoot
    if (-not $validationProfile.StagingRoot.Equals($validationStagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Project-specific settings were not retained when switching projects.'
    }
    $settings.Projects = @($settings.Projects | Where-Object {
        -not $_.ProjectRoot.Equals($validationRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    Update-ProjectSelector
    Add-Project -ProjectRoot $originalRoot
    if ($settings.Projects.Count -ne $originalProfileCount) {
        throw 'Adding an already registered project created a duplicate profile.'
    }
    Write-Host "ZXP Manager GUI validation passed; certificates: $($certificateList.Rows.Count), staging versions: $($stagingVersionList.Rows.Count), ZXP packages: $($zxpList.Rows.Count)."
    Write-Host $baseProjectVersionLabel.Text
    Write-Host "Settings path: $settingsPath"
    $workflowTimer.Dispose()
    $logTimer.Dispose()
    $settingsTimer.Dispose()
    $logContextMenu.Dispose()
    $form.Dispose()
    return
}
Add-Log "Ready. Settings path: $settingsPath"
$logTimer.Start()
[void]$form.ShowDialog()
$settingsTimer.Stop()
$logTimer.Stop()
