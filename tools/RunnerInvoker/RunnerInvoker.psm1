Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspacePath {
  param([string]$Relative)
  $ws = $env:GITHUB_WORKSPACE
  if (-not $ws) { $ws = (Get-Location).Path }
  if ([string]::IsNullOrWhiteSpace($Relative)) { return $ws }
  return (Join-Path $ws $Relative)
}

function Get-InvokerStatePath {
  $base = $env:RUNNER_TEMP
  if (-not $base) { $base = (Resolve-WorkspacePath 'invoker') }
  $dir = Join-Path $base 'invoker'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return (Join-Path $dir 'state.json')
}

function Write-Json($obj) { ($obj | ConvertTo-Json -Depth 8) + "`n" }

function Handle-StepSummary {
  param([hashtable]$Args)
  $text = $Args.text
  $lines = $Args.lines
  $append = $Args.append
  $fallback = $Args.fallbackFile
  $writer = Resolve-WorkspacePath 'tools/Write-StepSummary.ps1'
  if (-not (Test-Path -LiteralPath $writer)) { throw "Write-StepSummary.ps1 not found: $writer" }
  if ($lines) {
    & $writer -Lines $lines -Append:([bool]$append) -FallbackFile ($fallback ?? 'step-summary.md') | Out-Null
  } else {
    & $writer -Text ($text ?? '') -Append:([bool]$append) -FallbackFile ($fallback ?? 'step-summary.md') | Out-Null
  }
  return @{ ok = $true; code = 0 }
}

function Handle-FailureInventory {
  param([hashtable]$Args)
  $results = $Args.resultsDir
  if (-not $results) { $results = 'tests/results' }
  $script = Resolve-WorkspacePath 'tools/Write-FailureInventory.ps1'
  if (-not (Test-Path -LiteralPath $script)) { throw "Write-FailureInventory.ps1 not found: $script" }
  & $script -ResultsDir $results -AppendToStepSummary | Out-Null
  return @{ ok = $true; code = 0 }
}

function Handle-CompareVI {
  param([hashtable]$Args)
  $base = $Args.base; $head = $Args.head
  if (-not $base -or -not $head) { throw "CompareVI requires 'base' and 'head'" }
  $mod = Resolve-WorkspacePath 'scripts/CompareVI.psm1'
  if (-not (Test-Path -LiteralPath $mod)) { throw "CompareVI module not found: $mod" }
  Import-Module $mod -Force
  $cj = $Args.compareExecJsonPath
  if (-not $cj) {
    $resDir = $Args.resultsDir; if (-not $resDir) { $resDir = 'tests/results/comparevi' }
    $cj = Join-Path (Resolve-WorkspacePath $resDir) 'compare-exec.json'
  }
  $p = @{
    Base = (Resolve-WorkspacePath $base)
    Head = (Resolve-WorkspacePath $head)
    FailOnDiff = ([bool]($Args.failOnDiff ?? $true))
    LvComparePath = [string]($Args.lvComparePath)
    LvCompareArgs = [string]($Args.lvCompareArgs)
    WorkingDirectory = [string]($Args.workingDirectory)
    CompareExecJsonPath = $cj
  }
  $res = Invoke-CompareVI @p
  return @{ ok = $true; code = 0; data = @{ exitCode = $res.ExitCode; diff = $res.Diff; execJsonPath = $cj; command = $res.Command; cliPath = $res.CliPath; duration = $res.CompareDurationSeconds } }
}

function Handle-RenderReport {
  param([hashtable]$Args)
  $script = Resolve-WorkspacePath 'scripts/Render-CompareReport.ps1'
  if (-not (Test-Path -LiteralPath $script)) { throw "Render-CompareReport.ps1 not found: $script" }
  $cmd = [string]$Args.command
  $exit = [int]($Args.exitCode ?? 0)
  $diff = [string]($Args.diff ?? 'false')
  $cli  = [string]$Args.cliPath
  $out  = $Args.outputPath
  if ($out) { $out = (Resolve-WorkspacePath $out) }
  $base = $Args.base; if ($base) { $base = (Resolve-WorkspacePath $base) }
  $head = $Args.head; if ($head) { $head = (Resolve-WorkspacePath $head) }
  $dur  = [double]($Args.durationSeconds ?? 0)
  $exec = $Args.execJsonPath; if ($exec) { $exec = (Resolve-WorkspacePath $exec) }
  & $script -Command $cmd -ExitCode $exit -Diff $diff -CliPath $cli -Base $base -Head $head -OutputPath $out -DurationSeconds $dur -ExecJsonPath $exec | Out-Null
  return @{ ok = $true; code = 0; data = @{ outputPath = $out } }
}

function Invoke-Request {
  param([hashtable]$req)
  $verb = $req.verb
  $args = @{}
  if ($req.args) { $args = $req.args }
  switch -Regex ($verb) {
    '^Ping$'          { return @{ ok = $true; code = 0; message = 'pong' } }
    '^StepSummary$'   { return (Handle-StepSummary -Args $args) }
    '^FailureInventory$' { return (Handle-FailureInventory -Args $args) }
    '^CompareVI$'     { return (Handle-CompareVI -Args $args) }
    '^RenderReport$'  { return (Handle-RenderReport -Args $args) }
    default { throw "Unknown verb: $verb" }
  }
}

function Start-RunnerInvokerServer {
  param([string]$PipeName = 'lvci.invoker')
  $statePath = Get-InvokerStatePath
  try {
    $me = @{ pid = $PID; started = (Get-Date).ToUniversalTime().ToString('o'); pipe = $PipeName }
    $me | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
  } catch {}
  while ($true) {
    $server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
    $server.WaitForConnection()
    try {
      $sr = New-Object System.IO.StreamReader($server, [Text.Encoding]::UTF8, $true, 1024, $true)
      $sw = New-Object System.IO.StreamWriter($server, [Text.Encoding]::UTF8, 1024, $true)
      $sw.AutoFlush = $true
      $line = $sr.ReadLine()
      $resp = @{ ok = $false; code = 1; message = 'no request' }
      if ($line) {
        try {
          $req = $line | ConvertFrom-Json -ErrorAction Stop
          $t0 = Get-Date
          $out = Invoke-Request -req $req
          $t1 = Get-Date
          $resp = @{ id=$req.id; ok = $out.ok; code = $out.code; message = $out.message; data = $out.data; timings = @{ started=$t0.ToUniversalTime().ToString('o'); ended=$t1.ToUniversalTime().ToString('o') } }
        } catch {
          $resp = @{ ok = $false; code = 2; message = $_.Exception.Message }
        }
      }
      $sw.Write((Write-Json $resp))
    } finally {
      $server.Disconnect(); $server.Dispose()
    }
  }
}

Export-ModuleMember -Function Start-RunnerInvokerServer
