Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Clean-RogueLV helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:toolPath = Join-Path $repoRoot 'tools' 'Clean-RogueLV.ps1'
    Set-Item -Path function:New-TestDetectScript -Value {
      param(
        [string]$FileName,
        [object]$Payload,
        [int]$ExitCode = 0
      )
      $path = Join-Path $TestDrive $FileName
      $json = ($Payload | ConvertTo-Json -Depth 6 -Compress).Replace("'", "''")
      $content = @"
param()
Write-Output '$json'
exit $ExitCode
"@
      Set-Content -LiteralPath $path -Value $content -Encoding utf8
      return $path
    }
  }

  It 'succeeds when no rogue processes are reported' {
    $payload = [ordered]@{
      schema = 'rogue-lv-detection/v1'
      generatedAt = (Get-Date).ToString('o')
      lookbackSeconds = 900
      noticeDir = '.'
      live = [ordered]@{ lvcompare = @(); labview = @() }
      noticed = [ordered]@{ lvcompare = @(); labview = @() }
      rogue = [ordered]@{ lvcompare = @(); labview = @() }
    }
    $detect = New-TestDetectScript -FileName 'detect.ps1' -Payload $payload

    & $script:toolPath -DetectScriptPath $detect -Kill:$false -FailOnRogue:$true
    $LASTEXITCODE | Should -Be 0
  }

  It 'throws when rogue processes are detected' {
    $payload = [ordered]@{
      schema = 'rogue-lv-detection/v1'
      generatedAt = (Get-Date).ToString('o')
      lookbackSeconds = 900
      noticeDir = '.'
      live = [ordered]@{ lvcompare = @(4321); labview = @(1234) }
      noticed = [ordered]@{ lvcompare = @(); labview = @() }
      rogue = [ordered]@{ lvcompare = @(4321); labview = @(1234) }
    }
    $detect = New-TestDetectScript -FileName 'detect-rogue.ps1' -Payload $payload

    { & $script:toolPath -DetectScriptPath $detect -Kill:$false -FailOnRogue } | Should -Throw
  }

  It 'reports but continues when FailOnRogue is disabled' {
    $payload = [ordered]@{
      schema = 'rogue-lv-detection/v1'
      generatedAt = (Get-Date).ToString('o')
      lookbackSeconds = 900
      noticeDir = '.'
      live = [ordered]@{ lvcompare = @(1111); labview = @() }
      noticed = [ordered]@{ lvcompare = @(); labview = @() }
      rogue = [ordered]@{ lvcompare = @(1111); labview = @() }
    }
    $detect = New-TestDetectScript -FileName 'detect-rogue-ok.ps1' -Payload $payload

    & $script:toolPath -DetectScriptPath $detect -Kill:$false -FailOnRogue:$false
    $LASTEXITCODE | Should -Be 0
  }
}

