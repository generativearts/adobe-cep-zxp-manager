Describe 'Adobe CEP host compatibility' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\zxp_tools\zxp_common.ps1')

        function New-TestCepManifest {
            param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$HostIds)

            $hostXml = @(
                $HostIds | ForEach-Object {
                    '<Host Name="{0}" Version="[1.0,99.9]" />' -f $_
                }
            ) -join ''
            [xml]("<ExtensionManifest><ExecutionEnvironment><HostList>$hostXml</HostList></ExecutionEnvironment></ExtensionManifest>")
        }
    }

    It 'maps supported CEP host IDs to their Adobe applications' {
        $manifest = New-TestCepManifest -HostIds @('ILST', 'PHXS', 'PPRO', 'AEFT', 'IDSN')

        $applications = @(Get-ZxpHostApplications -Manifest $manifest)
        $names = @($applications | ForEach-Object { $_.ProductName }) -join ','

        $names | Should -Be 'Illustrator,Photoshop,Premiere Pro,After Effects,InDesign'
        $applications[0].ProcessNamePatterns | Should -Contain 'Illustrator*'
        $applications[1].ProcessNamePatterns | Should -Contain 'Photoshop*'
        $applications[2].ProcessNamePatterns | Should -Contain 'Adobe Premiere Pro*'
        $applications[3].ProcessNamePatterns | Should -Contain 'AfterFX*'
        $applications[4].ProcessNamePatterns | Should -Contain 'InDesign*'
    }

    It 'reads the target hosts from a ZXP manifest' {
        $manifest = New-TestCepManifest -HostIds @('PHXS')
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zxpPath = Join-Path $TestDrive 'host-test-package.zxp'
        $archive = [System.IO.Compression.ZipFile]::Open(
            $zxpPath,
            [System.IO.Compression.ZipArchiveMode]::Create
        )
        try {
            $entry = $archive.CreateEntry('CSXS/manifest.xml')
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try {
                $writer.Write($manifest.OuterXml)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }

        $packageManifest = Get-ZxpManifest -Path $zxpPath
        @(Get-ZxpHostApplications -Manifest $packageManifest).ProductName | Should -BeExactly 'Photoshop'
    }

    It 'deduplicates host IDs declared multiple times' {
        $manifest = New-TestCepManifest -HostIds @('PHXS', 'PHXS')

        @(Get-ZxpHostApplications -Manifest $manifest).Count | Should -Be 1
    }

    It 'blocks installation when the manifest contains an unsupported host ID' {
        $manifest = New-TestCepManifest -HostIds @('ILST', 'KBRG')

        { Get-ZxpHostApplications -Manifest $manifest } |
            Should -Throw -ExpectedMessage '*KBRG*'
    }

    It 'blocks installation when the manifest does not declare any hosts' {
        $manifest = New-TestCepManifest -HostIds @()

        { Get-ZxpHostApplications -Manifest $manifest } |
            Should -Throw -ExpectedMessage '*does not declare any Adobe hosts*'
    }

    It 'detects only the running target Adobe application' {
        $manifest = New-TestCepManifest -HostIds @('PHXS', 'PPRO')
        Mock Get-Process {
            if ($Name -contains 'Photoshop*') {
                [pscustomobject]@{ ProcessName = 'Photoshop' }
            }
        }

        $runningApplications = @(Get-ZxpRunningHostApplications -Manifest $manifest)

        $runningApplications | Should -BeExactly 'Photoshop'
        Should -Invoke -CommandName Get-Process -Times 2 -Exactly
    }
}
