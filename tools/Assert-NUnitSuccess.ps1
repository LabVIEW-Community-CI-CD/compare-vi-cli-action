#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ResultsPath,
  [string]$Context = 'CLI Compare'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf)) {
  throw "[$Context] NUnit results not found at '$ResultsPath'."
}

try {
  [xml]$xml = Get-Content -LiteralPath $ResultsPath -Raw -ErrorAction Stop
} catch {
  throw "[$Context] Failed to parse NUnit XML at '$ResultsPath': $($_.Exception.Message)"
}

$testRun = $xml.'test-run'
if (-not $testRun) {
  throw "[$Context] Invalid NUnit XML: missing test-run root."
}

$total = [int]($testRun.total ?? 0)
$failed = [int]($testRun.failed ?? 0)
$result = $testRun.result

if ($total -le 0) {
  throw "[$Context] NUnit results contain zero test cases."
}

$acceptableResults = @('Passed','Success')
if ($failed -gt 0 -or ($result -and ($acceptableResults -notcontains $result))) {
  $message = "[$Context] NUnit results indicate failure (result='$result', failed=$failed, total=$total)."
  $failedCases = $xml.SelectNodes('//test-case[@result!="Passed" and @result!="Success"]')
  if ($failedCases) {
    $details = $failedCases | ForEach-Object {
      $name = $_.name
      $msg = $_.failure.message
      if ($msg) { ("{0}: {1}" -f $name, $msg) } else { $name }
    }
    $message += " Failed cases: " + ($details -join '; ')
  }
  throw $message
}

Write-Host "[$Context] NUnit results OK (total=$total, failed=$failed)."
