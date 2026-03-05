#requires -Version 7.0

Describe 'Render-CompareReport CLI metadata' -Tag 'Unit' {
  It 'emits CLI metadata data attributes' {
    $outRoot = Join-Path $TestDrive 'report'
    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

    $exec = [ordered]@{
      command    = 'LabVIEWCLI.exe -OperationName CreateComparisonReport -LabVIEWPath "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"'
      cliPath    = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
      exitCode   = 0
      duration_s = 4.321
      base       = 'C:\repo\fixtures\VI1.vi'
      head       = 'C:\repo\fixtures\VI2.vi'
      diff       = $false
      environment = @{
        compareMode   = 'labview-cli'
        comparePolicy = 'cli-only'
        cli = @{
          path        = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
          reportType  = 'HTMLSingleFile'
          reportPath  = 'C:\temp\cli-report.html'
          status      = 'Success'
          message     = 'CreateComparisonReport operation succeeded.'
          artifacts   = @{
            reportSizeBytes = 123456
            imageCount      = 2
            exportDir       = 'C:\temp\cli-images'
            images          = @(
              @{
                index      = 0
                mimeType   = 'image/png'
                byteLength = 2048
                savedPath  = 'C:\temp\cli-images\img0.png'
              },
              @{
                index      = 1
                mimeType   = 'image/png'
                byteLength = 1024
              }
            )
          }
        }
      }
    }

    $execJsonPath = Join-Path $outRoot 'compare-exec.json'
    $exec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $execJsonPath -Encoding utf8

    $outPath = Join-Path $outRoot 'compare-report.html'
    & (Join-Path $PSScriptRoot '..' 'scripts' 'Render-CompareReport.ps1') -Command $exec.command -ExitCode $exec.exitCode -Diff 'false' -CliPath $exec.cliPath -Base $exec.base -Head $exec.head -OutputPath $outPath -DurationSeconds $exec.duration_s -ExecJsonPath $execJsonPath

    $html = Get-Content -LiteralPath $outPath -Raw

    $cliPathPattern = [regex]::Escape($exec.environment.cli.path)
    $reportTypePattern = [regex]::Escape($exec.environment.cli.reportType)
    $reportPathPattern = [regex]::Escape($exec.environment.cli.reportPath)
    $statusPattern = [regex]::Escape($exec.environment.cli.status)
    $messagePattern = [regex]::Escape($exec.environment.cli.message)
    $policyRaw = '{0}|{1}' -f $exec.environment.compareMode, $exec.environment.comparePolicy
    $policyPattern = [regex]::Escape($policyRaw)
    $reportSizePattern = [regex]::Escape([string]$exec.environment.cli.artifacts.reportSizeBytes)
    $imageCountPattern = [regex]::Escape([string]$exec.environment.cli.artifacts.imageCount)
    $exportDirPattern = [regex]::Escape($exec.environment.cli.artifacts.exportDir)
    $firstImagePathPattern = [regex]::Escape($exec.environment.cli.artifacts.images[0].savedPath)
    $firstImageBytesPattern = [regex]::Escape([string]$exec.environment.cli.artifacts.images[0].byteLength)
    $secondImageBytesPattern = [regex]::Escape([string]$exec.environment.cli.artifacts.images[1].byteLength)

    $html | Should -Match ("data-cli-path=""{0}""" -f $cliPathPattern)
    $html | Should -Match ("data-cli-report-type=""{0}""" -f $reportTypePattern)
    $html | Should -Match ("data-cli-report-path=""{0}""" -f $reportPathPattern)
    $html | Should -Match ("data-cli-status=""{0}""" -f $statusPattern)
    $html | Should -Match ("data-cli-message=""{0}""" -f $messagePattern)
    $html | Should -Match ("data-cli-policy=""{0}""" -f $policyPattern)
    $html | Should -Match ("data-cli-report-size=""{0}""" -f $reportSizePattern)
    $html | Should -Match ("data-cli-image-count=""{0}""" -f $imageCountPattern)
    $html | Should -Match ("data-cli-image-export=""{0}""" -f $exportDirPattern)
    $html | Should -Match ("data-cli-image-index=""0"".*data-cli-image-path=""{0}""" -f $firstImagePathPattern)
    $html | Should -Match ("data-cli-image-bytes=""{0}""" -f $firstImageBytesPattern)
    $html | Should -Match ("data-cli-image-index=""1"".*data-cli-image-bytes=""{0}""" -f $secondImageBytesPattern)
  }
}
