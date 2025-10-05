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

function Get-InvokerDir { Split-Path -Parent (Get-InvokerStatePath) }

function Write-Json($obj) { ($obj | ConvertTo-Json -Depth 8) + "`n" }

function Get-PhaseDir {
  param([hashtable]$Args)
  $phase = [string]$Args.phase
  if (-not $phase) { $phase = 'phase' }
  $root = $Args.resultsDir; if (-not $root) { $root = 'tests/results' }
  $base = Resolve-WorkspacePath $root
  $dir = Join-Path $base $phase
  $hand = Join-Path $dir '_handshake'
  if (-not (Test-Path -LiteralPath $hand)) { New-Item -ItemType Directory -Force -Path $hand | Out-Null }
  return $hand
}

function Write-Marker {
  param([string]$Path, [string]$Name, [hashtable]$Obj)
  $Obj.ts = (Get-Date).ToUniversalTime().ToString('o')
  $json = $Obj | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath (Join-Path $Path $Name) -Value $json -Encoding UTF8
}

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

function Handle-PhaseReset {
  param([hashtable]$Args)
  $dir = Get-PhaseDir -Args $Args
  try { Get-ChildItem -LiteralPath $dir -Force | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue } catch {}
  Write-Marker -Path $dir -Name 'reset.json' -Obj @{ phase=$Args.phase }
  return @{ ok=$true; code=0; data=@{ markerDir=$dir } }
}

function Handle-PhaseStart {
  param([hashtable]$Args)
  $dir = Get-PhaseDir -Args $Args
  $phaseId = [guid]::NewGuid().ToString()
  Write-Marker -Path $dir -Name 'req.json' -Obj @{ phase=$Args.phase; context=$Args.context }
  Write-Marker -Path $dir -Name 'ack.json' -Obj @{ phaseId=$phaseId; pid=$PID; pipe='lvci.invoker' }
  return @{ ok=$true; code=0; data=@{ phaseId=$phaseId; markerDir=$dir } }
}

function Handle-PhaseWaitReady {
  param([hashtable]$Args)
  Initialize-Telemetry
  $dir = Get-PhaseDir -Args $Args
  $ok = $true
  $checks = @{}
  $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
  $checks.lvcompare = (Test-Path -LiteralPath $canonical -PathType Leaf)
  $checks.watchers = [bool]$script:telemetryInit
  $checks.paths = (Test-Path -LiteralPath $dir)
  $ok = $checks.lvcompare -and $checks.watchers -and $checks.paths
  Write-Marker -Path $dir -Name 'ready.json' -Obj @{ checks=$checks; ok=$ok }
  if (-not $ok) { return @{ ok=$false; code=300; message='phase not ready'; data=@{ checks=$checks } } }
  return @{ ok=$true; code=0; data=@{ checks=$checks } }
}

function Handle-PhaseDone {
  param([hashtable]$Args)
  $dir = Get-PhaseDir -Args $Args
  $obj = @{ status=($Args.status ?? 'unknown'); exitCode=([int]($Args.exitCode ?? 0)); artifacts=$Args.artifacts; notes=$Args.notes }
  Write-Marker -Path $dir -Name 'done.json' -Obj $obj
  return @{ ok=$true; code=0 }
}

function Initialize-Telemetry {
  if ($script:telemetryInit) { return }
  $dir = Get-InvokerDir
  $script:telemetryFile = Join-Path $dir 'console-spawns.ndjson'
  if (-not (Test-Path -LiteralPath $script:telemetryFile)) {
    try { New-Item -ItemType File -Path $script:telemetryFile -Force | Out-Null } catch {}
  }
  $names = @('pwsh.exe','conhost.exe','LVCompare.exe','LabVIEW.exe')
  $nameFilter = ($names | ForEach-Object { "TargetInstance.Name='$_'" }) -join ' OR '
  $scope = New-Object System.Management.ManagementScope('\\\.\root\CIMV2')
  $scope.Connect()
  $qCreate = New-Object System.Management.WqlEventQuery("SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE TargetInstance ISA 'Win32_Process' AND ($nameFilter)")
  $qDelete = New-Object System.Management.WqlEventQuery("SELECT * FROM __InstanceDeletionEvent WITHIN 0.5 WHERE TargetInstance ISA 'Win32_Process' AND ($nameFilter)")
  $watchCreate = New-Object System.Management.ManagementEventWatcher($scope, $qCreate)
  $watchDelete = New-Object System.Management.ManagementEventWatcher($scope, $qDelete)
  $handler = {
    param($sender,$eventArgs)
    try {
      $ev = $eventArgs.NewEvent
      $inst = $ev.TargetInstance
      $op = if ($ev.__CLASS -like '*Creation*') { 'start' } else { 'stop' }
      $name = [string]$inst.Name
      $pid = [int]$inst.ProcessId
      $ppid = $null; try { $ppid = [int]$inst.ParentProcessId } catch {}
      $cmd = $null; try { $cmd = [string]$inst.CommandLine } catch {}
      $row = @{ ts = (Get-Date).ToUniversalTime().ToString('o'); op=$op; name=$name; pid=$pid; ppid=$ppid; cmd=$cmd }
      $json = ($row | ConvertTo-Json -Compress)
      Add-Content -LiteralPath $script:telemetryFile -Value $json -Encoding utf8
    } catch {}
  }
  $null = Register-ObjectEvent -InputObject $watchCreate -EventName EventArrived -Action $handler -MessageData 'create'
  $null = Register-ObjectEvent -InputObject $watchDelete -EventName EventArrived -Action $handler -MessageData 'delete'
  $watchCreate.Start(); $watchDelete.Start()
  $script:telemetryInit = $true
}

function Handle-TelemetrySummary {
  param([hashtable]$Args)
  Initialize-Telemetry
  $outDir = $Args.resultsDir; if (-not $outDir) { $outDir = 'tests/results' }
  $outAbs = Resolve-WorkspacePath $outDir
  if (-not (Test-Path -LiteralPath $outAbs)) { New-Item -ItemType Directory -Force -Path $outAbs | Out-Null }
  $src = $script:telemetryFile
  $dst = Join-Path $outAbs 'console-spawns.ndjson'
  try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue } catch {}
  $counts = @{ pwsh=0; conhost=0; LVCompare=0; LabVIEW=0 }
  try {
    if (Test-Path -LiteralPath $src) {
      Get-Content -LiteralPath $src -Raw | ConvertFrom-Json -AsArray | ForEach-Object {
        if ($_.op -eq 'start') {
          switch -Exact ($_.name) { 'pwsh.exe' { $counts.pwsh++ } 'conhost.exe' { $counts.conhost++ } 'LVCompare.exe' { $counts.LVCompare++ } 'LabVIEW.exe' { $counts.LabVIEW++ } }
        }
      }
    }
  } catch {}
  $lines = @('### Invoker Telemetry','')
  $lines += ('- pwsh: {0}' -f $counts.pwsh)
  $lines += ('- conhost: {0}' -f $counts.conhost)
  $lines += ('- LVCompare: {0}' -f $counts.LVCompare)
  $lines += ('- LabVIEW: {0}' -f $counts.LabVIEW)
  $writer = Resolve-WorkspacePath 'tools/Write-StepSummary.ps1'
  if (Test-Path -LiteralPath $writer) { & $writer -Lines $lines -Append | Out-Null }
  return @{ ok=$true; code=0; data=@{ counts=$counts; telemetryPath=$dst } }
}

function Validate-Request {
  param([hashtable]$req)
  if (-not $req) { throw [System.Exception]::new('invalid schema: null request') }
  if ($req.schema -ne 'invoker-cmd/v1') { throw [System.Exception]::new('invalid schema') }
  if (-not $req.id) { throw [System.Exception]::new('missing id') }
  if (-not $req.verb) { throw [System.Exception]::new('missing verb') }
  if ($req.args -and -not ($req.args -is [hashtable])) { throw [System.Exception]::new('invalid args') }
}

function Invoke-Request {
  param([hashtable]$req)
  Validate-Request -req $req
  $verb = [string]$req.verb
  $args = @{}
  if ($req.args) { $args = $req.args }
  switch -Regex ($verb) {
    '^Ping$'          { return @{ ok = $true; code = 0; message = 'pong' } }
    '^StepSummary$'   { return (Handle-StepSummary -Args $args) }
    '^FailureInventory$' { return (Handle-FailureInventory -Args $args) }
    '^CompareVI$'     { return (Handle-CompareVI -Args $args) }
    '^RenderReport$'  { return (Handle-RenderReport -Args $args) }
    '^TelemetrySummary$' { return (Handle-TelemetrySummary -Args $args) }
    '^PhaseReset$'    { return (Handle-PhaseReset -Args $args) }
    '^PhaseStart$'    { return (Handle-PhaseStart -Args $args) }
    '^PhaseWaitReady$'{ return (Handle-PhaseWaitReady -Args $args) }
    '^PhaseDone$'     { return (Handle-PhaseDone -Args $args) }
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
  Initialize-Telemetry
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
          $code = 200
          $msg = $_.Exception.Message
          if ($msg -match 'invalid schema') { $code = 100 }
          elseif ($msg -match 'missing id') { $code = 101 }
          elseif ($msg -match 'missing verb') { $code = 102 }
          elseif ($msg -match 'invalid args') { $code = 103 }
          elseif ($msg -match 'Unknown verb') { $code = 104 }
          $resp = @{ ok = $false; code = $code; message = $msg }
        }
      }
      $sw.Write((Write-Json $resp))
    } finally {
      $server.Disconnect(); $server.Dispose()
    }
  }
}

Export-ModuleMember -Function Start-RunnerInvokerServer
