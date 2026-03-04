#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$ReleaseRoot = 'tests/results/_agent/release-v1.0.1',
  [string]$Image
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$Provided)

  if (-not [string]::IsNullOrWhiteSpace($Provided)) {
    return (Resolve-Path -LiteralPath $Provided).Path
  }

  $current = (Get-Location).Path
  while ($true) {
    if (Test-Path -LiteralPath (Join-Path $current '.git')) {
      return $current
    }

    $parent = Split-Path -Parent $current
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
      throw 'Could not locate repository root (.git). Pass -RepoRoot explicitly.'
    }

    $current = $parent
  }
}

$repoPath = Resolve-RepoRoot -Provided $RepoRoot
Push-Location $repoPath
try {
  $releasePath = Join-Path $repoPath $ReleaseRoot

  $dockerOs = (& docker info --format '{{.OSType}}').Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($dockerOs)) {
    throw 'Could not determine Docker engine OS type via `docker info`.'
  }

  $isWindowsEngine = $dockerOs -eq 'windows'
  if ($isWindowsEngine) {
    $archivePath = Join-Path $releasePath 'comparevi-cli-v0.1.0-win-x64-selfcontained.zip'
    $defaultImage = 'mcr.microsoft.com/powershell:lts-windowsservercore-ltsc2022'
    $containerWorkDir = 'C:\work'
    $binaryRel = (Join-Path $ReleaseRoot 'scenario-matrix/tool/comparevi-cli.exe') -replace '\\', '/'
  } else {
    $archivePath = Join-Path $releasePath 'comparevi-cli-v0.1.0-linux-x64-selfcontained.tar.gz'
    $defaultImage = 'ubuntu:22.04'
    $containerWorkDir = '/work'
    $binaryRel = (Join-Path $ReleaseRoot 'scenario-matrix/tool/comparevi-cli') -replace '\\', '/'
  }

  $effectiveImage = if ([string]::IsNullOrWhiteSpace($Image)) { $defaultImage } else { $Image }

  if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive not found: $archivePath"
  }

  $matrixRoot = Join-Path $releasePath 'scenario-matrix'
  $toolRoot = Join-Path $matrixRoot 'tool'
  $inputsRoot = Join-Path $matrixRoot 'inputs'
  $runsRoot = Join-Path $matrixRoot 'runs'

  if (Test-Path -LiteralPath $matrixRoot -PathType Container) {
    Remove-Item -LiteralPath $matrixRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $toolRoot, $inputsRoot, $runsRoot -Force | Out-Null

  & tar -xf $archivePath -C $toolRoot

  $basePrefix = $repoPath + [IO.Path]::DirectorySeparatorChar
  $pairs = @(
    Get-ChildItem -LiteralPath (Join-Path $repoPath 'fixtures') -Recurse -Filter 'Base.vi' -File | ForEach-Object {
      $headPath = Join-Path $_.DirectoryName 'Head.vi'
      if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) {
        return
      }

      $baseHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      $headHash = (Get-FileHash -LiteralPath $headPath -Algorithm SHA256).Hash
      if ($baseHash -eq $headHash) {
        return
      }

      [pscustomobject]@{
        fixture = Split-Path -Leaf $_.DirectoryName
        baseVi = ($_.FullName.Replace($basePrefix, '') -replace '\\', '/')
        headVi = ($headPath.Replace($basePrefix, '') -replace '\\', '/')
      }
    }
  )

  if ($pairs.Count -lt 1) {
    throw 'No changed Base.vi/Head.vi fixture pairs found.'
  }

  $results = New-Object System.Collections.Generic.List[object]
  $binaryFlags = @(0, 1)
  $scenarioIndex = 0
  $mountArg = '{0}:{1}' -f $repoPath, $containerWorkDir

  foreach ($pair in $pairs) {
    foreach ($diff in $binaryFlags) {
      foreach ($nonInteractive in $binaryFlags) {
        foreach ($headless in $binaryFlags) {
          $scenarioIndex++
          $scenarioId = '{0:D3}-{1}-d{2}-ni{3}-h{4}' -f $scenarioIndex, $pair.fixture, $diff, $nonInteractive, $headless
          $scenarioDir = Join-Path $runsRoot $scenarioId
          New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null

          $inputPath = Join-Path $inputsRoot ($scenarioId + '.json')
          [ordered]@{
            fixture = $pair.fixture
            baseVi = $pair.baseVi
            headVi = $pair.headVi
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            note = 'Scenario matrix input for compare single dry-run'
          } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath -Encoding utf8

          $inputRel = ($inputPath.Replace($basePrefix, '') -replace '\\', '/')
          $outRel = ($scenarioDir.Replace($basePrefix, '') -replace '\\', '/')
          if ($isWindowsEngine) {
            $inputInContainer = ('C:\\work\\{0}' -f ($inputRel -replace '/', '\\'))
            $outInContainer = ('C:\\work\\{0}' -f ($outRel -replace '/', '\\'))
          } else {
            $inputInContainer = '/work/' + $inputRel
            $outInContainer = '/work/' + $outRel
          }

          $argsText = @('compare', 'single', '--input', ('"{0}"' -f $inputInContainer), '--dry-run', '--out-dir', ('"{0}"' -f $outInContainer))
          if ($diff -eq 1) { $argsText += '--diff' }
          if ($nonInteractive -eq 1) { $argsText += '--non-interactive' }
          if ($headless -eq 1) { $argsText += '--headless' }

          if ($isWindowsEngine) {
            $binaryInContainer = ('C:\\work\\{0}' -f ($binaryRel -replace '/', '\\'))
            $dockerScript = "& '{0}' {1}" -f $binaryInContainer, ($argsText -join ' ')
          } else {
            $dockerScript = 'chmod +x /work/{0}; /work/{0} {1}' -f $binaryRel, ($argsText -join ' ')
          }

          $stdoutPath = Join-Path $scenarioDir 'stdout.json'
          $stderrPath = Join-Path $scenarioDir 'stderr.txt'

          $stdoutLines = @()
          $exitCode = 0
          try {
            if ($isWindowsEngine) {
              $stdoutLines = & docker run --rm -v $mountArg -w $containerWorkDir $effectiveImage pwsh -NoLogo -NoProfile -Command $dockerScript 2> $stderrPath
            } else {
              $stdoutLines = & docker run --rm -v $mountArg -w $containerWorkDir $effectiveImage bash -lc $dockerScript 2> $stderrPath
            }
            $exitCode = $LASTEXITCODE
          } catch {
            $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }
          }

          $stdout = if ($stdoutLines -is [array]) { $stdoutLines -join [Environment]::NewLine } else { [string]$stdoutLines }
          Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding utf8

          $parsed = $null
          try {
            $parsed = $stdout | ConvertFrom-Json -Depth 20
          } catch {
            $parsed = $null
          }

          $results.Add([pscustomobject]@{
            scenarioId = $scenarioId
            fixture = $pair.fixture
            baseVi = $pair.baseVi
            headVi = $pair.headVi
            diff = [bool]$diff
            nonInteractive = [bool]$nonInteractive
            headless = [bool]$headless
            exitCode = [int]$exitCode
            parsed = ($parsed -ne $null)
            gateOutcome = if ($parsed) { [string]$parsed.gateOutcome } else { '' }
            resultClass = if ($parsed) { [string]$parsed.resultClass } else { '' }
            failureClass = if ($parsed) { [string]$parsed.failureClass } else { '' }
            stdoutPath = ($stdoutPath.Replace($basePrefix, '') -replace '\\', '/')
            stderrPath = ($stderrPath.Replace($basePrefix, '') -replace '\\', '/')
          }) | Out-Null
        }
      }
    }
  }

  $jsonPath = Join-Path $matrixRoot 'scenario-results.json'
  $csvPath = Join-Path $matrixRoot 'scenario-results.csv'
  $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8
  $results | Select-Object scenarioId, fixture, diff, nonInteractive, headless, exitCode, parsed, gateOutcome, resultClass, failureClass, stdoutPath, stderrPath | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

  $summary = [ordered]@{
    total = $results.Count
    exitZero = @($results | Where-Object { $_.exitCode -eq 0 }).Count
    exitNonZero = @($results | Where-Object { $_.exitCode -ne 0 }).Count
    dockerEngineOs = $dockerOs
    image = $effectiveImage
    fixtures = @($pairs | Select-Object -ExpandProperty fixture)
    resultJson = ($jsonPath.Replace($basePrefix, '') -replace '\\', '/')
    resultCsv = ($csvPath.Replace($basePrefix, '') -replace '\\', '/')
  }

  $summary | ConvertTo-Json -Depth 5
}
finally {
  Pop-Location
}
