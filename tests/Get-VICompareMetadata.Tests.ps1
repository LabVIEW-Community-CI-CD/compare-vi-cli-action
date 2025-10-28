Describe 'Get-VICompareMetadata.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Get-VICompareMetadata.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    It 'captures diff categories and writes json' {
        $baseVi = Join-Path $TestDrive 'Base.vi'
        $headVi = Join-Path $TestDrive 'Head.vi'
        Set-Content -LiteralPath $baseVi -Value 'base'
        Set-Content -LiteralPath $headVi -Value 'head'

        $outputPath = Join-Path $TestDrive 'metadata.json'
        $compareDir = Join-Path $TestDrive 'compare'

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [string[]]$Flags,
                [switch]$ReplaceFlags
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Base    = $BaseVi
                Head    = $HeadVi
                Output  = $OutputDir
                Flags   = $Flags
                Replace = $ReplaceFlags.IsPresent
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

            $html = @'
<!DOCTYPE html>
<html>
<body>
<div class="included-attributes">
  <ul class="inclusion-list">
    <li class="checked">Block Diagram Cosmetic</li>
    <li class="unchecked">VI Attribute</li>
  </ul>
</div>
<details open>
  <summary class="difference-heading">1. Block Diagram Cosmetic - Objects</summary>
  <ol class="detailed-description-list">
    <li class="diff-detail">Difference Type: Cosmetic wiring</li>
  </ol>
</details>
</body>
</html>
'@
            Set-Content -LiteralPath (Join-Path $OutputDir 'compare-report.html') -Value $html -Encoding utf8
            Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Value '{"capture":true}' -Encoding utf8
            return [pscustomobject]@{ ExitCode = 1 }
        }.GetNewClosure()

        $result = & $script:scriptPath -BaseVi $baseVi -HeadVi $headVi -OutputPath $outputPath -ReplaceFlags -InvokeLVCompare $invoke

        $result | Should -Not -BeNullOrEmpty
        $result.status | Should -Be 'diff'
        $result.diffCategories | Should -Contain 'Block Diagram Cosmetic'
        $result.diffDetails | Should -Contain 'Difference Type: Cosmetic wiring'
        $result.includedAttributes.Count | Should -Be 2
        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].Replace | Should -BeTrue
        $invokeCalls[0].Flags | Should -BeNullOrEmpty

        Test-Path -LiteralPath $outputPath | Should -BeTrue
        $json = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 6
        $json.status | Should -Be 'diff'
        $json.diffCategories | Should -Contain 'Block Diagram Cosmetic'
    }
}
