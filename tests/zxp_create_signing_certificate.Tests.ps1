BeforeAll {
    $script:projectRoot = Join-Path $TestDrive 'project'
    $script:certificateScript = Join-Path $PSScriptRoot '..\zxp_tools\zxp_create_signing_certificate.ps1'
    $script:signerPath = Join-Path $TestDrive 'test-sign-tool.ps1'
    $script:sourceCertificatePath = Join-Path $TestDrive 'source-certificate.pfx'
    $script:sourceCertificatePassword = 'pester-fixture-password'

    New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'CSXS') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $script:projectRoot 'CSXS\manifest.xml'),
        '<ExtensionManifest ExtensionBundleName="Pester Test" ExtensionBundleId="com.example.pester" ExtensionBundleVersion="1.0.0" />'
    )

    $script:sourceCertificate = New-SelfSignedCertificate `
        -Subject 'CN=ZXP Manager Pester Fixture' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddDays(30)

    $securePassword = ConvertTo-SecureString $script:sourceCertificatePassword -AsPlainText -Force
    Export-PfxCertificate `
        -Cert $script:sourceCertificate `
        -FilePath $script:sourceCertificatePath `
        -Password $securePassword `
        -Force | Out-Null

    $testSigner = @'
param(
    [switch]$selfSignedCert,
    [string]$Country,
    [string]$State,
    [string]$Organization,
    [string]$CommonName,
    [string]$Password,
    [string]$OutputPath,
    [int]$validityDays
)

$ErrorActionPreference = 'Stop'

switch ($env:ZXP_TEST_SIGNER_MODE) {
    'ExitFailure' {
        $global:LASTEXITCODE = 19
        return
    }
    'NoOutput' {
        $global:LASTEXITCODE = 0
        return
    }
    'InvalidPfx' {
        [System.IO.File]::WriteAllBytes($OutputPath, [byte[]]@(1, 2, 3))
        $global:LASTEXITCODE = 0
        return
    }
}

$sourceCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $env:ZXP_TEST_SOURCE_CERTIFICATE,
    $env:ZXP_TEST_SOURCE_PASSWORD,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
)
try {
    $pfxBytes = $sourceCertificate.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
        $Password
    )
    [System.IO.File]::WriteAllBytes($OutputPath, $pfxBytes)
    [Array]::Clear($pfxBytes, 0, $pfxBytes.Length)
}
finally {
    $sourceCertificate.Dispose()
}

$global:LASTEXITCODE = 0
'@
    [System.IO.File]::WriteAllText($script:signerPath, $testSigner)
}

AfterAll {
    if ($script:sourceCertificate) {
        $sourceCertificateStorePath = 'Cert:\CurrentUser\My\' + $script:sourceCertificate.Thumbprint
        Remove-Item -LiteralPath $sourceCertificateStorePath -Force -ErrorAction SilentlyContinue
        $script:sourceCertificate.Dispose()
    }
}

Describe 'zxp_create_signing_certificate.ps1' {
    BeforeAll {
        function Get-TestCertificatesDirectory {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            Join-Path $RootPath ('certificates-' + [guid]::NewGuid().ToString('N'))
        }

        function Invoke-TestCertificateCreation {
            param(
                [Parameter(Mandatory = $true)][string]$CertificatesDirectory,
                [ValidateSet('Success', 'ExitFailure', 'NoOutput', 'InvalidPfx')]
                [string]$SignerMode = 'Success',
                [string]$SignToolPath = $script:signerPath
            )

            $previousSignerMode = $env:ZXP_TEST_SIGNER_MODE
            $previousSourceCertificate = $env:ZXP_TEST_SOURCE_CERTIFICATE
            $previousSourcePassword = $env:ZXP_TEST_SOURCE_PASSWORD

            try {
                $env:ZXP_TEST_SIGNER_MODE = $SignerMode
                $env:ZXP_TEST_SOURCE_CERTIFICATE = $script:sourceCertificatePath
                $env:ZXP_TEST_SOURCE_PASSWORD = $script:sourceCertificatePassword

                & $script:certificateScript `
                    -ProjectRoot $script:projectRoot `
                    -CertificatesDirectory $CertificatesDirectory `
                    -SignToolPath $SignToolPath *>&1
            }
            finally {
                $env:ZXP_TEST_SIGNER_MODE = $previousSignerMode
                $env:ZXP_TEST_SOURCE_CERTIFICATE = $previousSourceCertificate
                $env:ZXP_TEST_SOURCE_PASSWORD = $previousSourcePassword
            }
        }
    }

    It 'creates a private-key certificate and protects both output files' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        $output = @(Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory)
        $files = @(Get-ChildItem -LiteralPath $certificatesDirectory -File)
        $certificateFile = $files | Where-Object { $_.Extension -eq '.p12' } | Select-Object -First 1
        $passwordFile = $files | Where-Object { $_.Name -like '*.password.txt' } | Select-Object -First 1

        $certificateFile | Should -Not -BeNullOrEmpty
        $passwordFile | Should -Not -BeNullOrEmpty
        $files.Count | Should -Be 2
        $files.Name | Should -Contain "$($script:sourceCertificate.SerialNumber.ToUpperInvariant()).p12"

        $password = [System.IO.File]::ReadAllText($passwordFile.FullName)
        $password | Should -Match '^[0-9A-F]{64}$'
        ($output | Out-String) | Should -Not -Match $password

        $generatedCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certificateFile.FullName,
            $password,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        )
        try {
            $generatedCertificate.HasPrivateKey | Should -BeTrue
            $generatedCertificate.SerialNumber.ToUpperInvariant() |
                Should -Be $script:sourceCertificate.SerialNumber.ToUpperInvariant()
        }
        finally {
            $generatedCertificate.Dispose()
        }

        $expectedSids = @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            'S-1-5-18'
            'S-1-5-32-544'
        )
        foreach ($file in $files) {
            $acl = Get-Acl -LiteralPath $file.FullName
            $acl.AreAccessRulesProtected | Should -BeTrue
            $actualSids = @(
                $acl.GetAccessRules(
                    $true,
                    $true,
                    [System.Security.Principal.SecurityIdentifier]
                ) | ForEach-Object { $_.IdentityReference.Value }
            )
            foreach ($sid in $expectedSids) {
                $actualSids | Should -Contain $sid
            }
        }
    }

    It 'removes temporary files when ZXPSignCmd returns a failure code' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        { Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory -SignerMode ExitFailure } |
            Should -Throw -ExpectedMessage '*exit code 19*'

        @(Get-ChildItem -LiteralPath $certificatesDirectory -Force).Count | Should -Be 0
    }

    It 'removes temporary files when ZXPSignCmd reports success without creating a certificate' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        { Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory -SignerMode NoOutput } |
            Should -Throw -ExpectedMessage '*did not create the certificate file*'

        @(Get-ChildItem -LiteralPath $certificatesDirectory -Force).Count | Should -Be 0
    }

    It 'removes invalid certificate output instead of leaving artifacts behind' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        { Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory -SignerMode InvalidPfx } |
            Should -Throw

        @(Get-ChildItem -LiteralPath $certificatesDirectory -Force).Count | Should -Be 0
    }

    It 'refuses to overwrite existing files with the same certificate serial' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory | Out-Null
        $serial = $script:sourceCertificate.SerialNumber.ToUpperInvariant()
        $certificatePath = Join-Path $certificatesDirectory "$serial.p12"
        $passwordPath = Join-Path $certificatesDirectory "$serial.password.txt"
        $originalCertificateHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash
        $originalPassword = [System.IO.File]::ReadAllText($passwordPath)

        { Invoke-TestCertificateCreation -CertificatesDirectory $certificatesDirectory } |
            Should -Throw -ExpectedMessage '*Refusing to overwrite existing files*'

        (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash |
            Should -Be $originalCertificateHash
        [System.IO.File]::ReadAllText($passwordPath) | Should -Be $originalPassword
        @(Get-ChildItem -LiteralPath $certificatesDirectory -Force).Count | Should -Be 2
    }

    It 'rejects a certificates path that is a file' {
        $filePath = Join-Path $TestDrive 'not-a-directory'
        [System.IO.File]::WriteAllText($filePath, 'not a directory')

        {
            Invoke-TestCertificateCreation `
                -CertificatesDirectory $filePath
        } | Should -Throw -ExpectedMessage '*Refusing to use a non-directory or reparse-point certificates path*'
    }

    It 'does not create the certificates directory when the signing tool is missing' {
        $certificatesDirectory = Get-TestCertificatesDirectory -RootPath $TestDrive
        $missingTool = Join-Path $TestDrive 'missing-sign-tool.exe'

        {
            Invoke-TestCertificateCreation `
                -CertificatesDirectory $certificatesDirectory `
                -SignToolPath $missingTool
        } | Should -Throw -ExpectedMessage '*ZXPSignCmd.exe was not found*'

        Test-Path -LiteralPath $certificatesDirectory | Should -BeFalse
    }
}
