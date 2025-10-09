Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Workflow log extraction' -Tag 'Unit' {
BeforeAll {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $script:analyzer = Join-Path (Get-Location).Path 'tools' 'Analyze-JobLog.ps1'
}

It 'finds parameter conversion error inside a zipped job log' {
  $sourceDir = Join-Path $TestDrive 'log-src'
  $zipPath = Join-Path $TestDrive 'job-log.zip'

  New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null

  $esc = [char]27
  $logContent = @"
2025-10-07T14:25:46Z ##[group]Run ./Invoke-PesterTests.ps1 -TestsPath tests
2025-10-07T14:25:46Z ##[error]${esc}[31;1mCannot process argument transformation on parameter 'TimeoutMinutes'.${esc}[0m Cannot convert value "-ResultsPath" to type "System.Double". Error: "The input string '-ResultsPath' was not in a correct format."
2025-10-07T14:25:47Z ##[endgroup]
"@

  $logFile = Join-Path $sourceDir '1_Test/1.txt'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFile) | Out-Null
  Set-Content -LiteralPath $logFile -Value $logContent -Encoding utf8

  [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

  $result = & $script:analyzer -LogPath $zipPath -Pattern "TimeoutMinutes"
  $result | Should -Not -BeNullOrEmpty
  $result.Content | Should -Match "Cannot process argument transformation on parameter 'TimeoutMinutes'"
  $result.Content | Should -Match "The input string '-ResultsPath' was not in a correct format"
  $result.Content | Should -Not -Match "\x1b"
  $result.Matches.Count | Should -BeGreaterThan 0
}

It 'handles raw text job logs' {
  $textPath = Join-Path $TestDrive 'job-log.txt'
  $logContent = 'line1`nline2: Cannot process argument transformation on parameter ''TimeoutMinutes''.'
  Set-Content -LiteralPath $textPath -Value $logContent -Encoding utf8

  $result = & $script:analyzer -LogPath $textPath -Pattern "TimeoutMinutes"
  $result | Should -Not -BeNullOrEmpty
  $result.Content | Should -Match 'line1'
  $result.Matches.Count | Should -Be 1
}
}
