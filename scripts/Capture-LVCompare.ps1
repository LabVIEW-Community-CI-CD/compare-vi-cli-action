param(
	[Parameter(Mandatory=$true)][string]$Base,
	[Parameter(Mandatory=$true)][string]$Head,
	[Parameter()][object]$LvArgs,
	[Parameter()][string]$LvComparePath,
	[Parameter()][switch]$RenderReport,
	[Parameter()][string]$OutputDir = 'tests/results',
	[Parameter()][switch]$Quiet,
	[Parameter()][int]$TimeoutSeconds = 60,
	[Parameter()][switch]$KillOnTimeout,
	[Parameter()][switch]$CloseOnComplete
)

$ErrorActionPreference = 'Stop'

# Import shared tokenization module
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force
# Reuse CompareVI normalization logic
$script:CompareModule = Import-Module (Join-Path $PSScriptRoot 'CompareVI.psm1') -Force -PassThru

# Optional vendor tool resolvers (for canonical LVCompare path)
try { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force } catch {}

function Resolve-CanonicalCliPath {
	param([string]$Override)
	if ($Override) {
		if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
			throw "LVCompare.exe override not found at: $Override"
		}
		try { return (Resolve-Path -LiteralPath $Override).Path } catch { return $Override }
	}
	$envOverride = @($env:LVCOMPARE_PATH, $env:LV_COMPARE_PATH) | Where-Object { $_ } | Select-Object -First 1
	if ($envOverride) {
		if (-not (Test-Path -LiteralPath $envOverride -PathType Leaf)) {
			throw "LVCompare.exe not found at LVCOMPARE_PATH: $envOverride"
		}
		try { return (Resolve-Path -LiteralPath $envOverride).Path } catch { return $envOverride }
	}
	# Prefer resolver from VendorTools when available
	try {
		$resolved = Resolve-LVComparePath
		if ($resolved) { return $resolved }
	} catch {}
	$cli = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
	if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "LVCompare.exe not found at canonical path: $cli" }
	return $cli
}

function ConvertTo-ArgList([object]$value) {
	if ($null -eq $value) { return @() }
	if ($value -is [System.Array]) {
		$out = @()
		foreach ($v in $value) {
			$t = [string]$v
			if ($null -ne $t) { $t = $t.Trim() }
			if (-not [string]::IsNullOrWhiteSpace($t)) {
				if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) { $t = $t.Substring(1, $t.Length-2) }
				if ($t -ne '') { $out += $t }
			}
		}
		return $out
	}
	$s = [string]$value
	if ($s -match '^\s*$') { return @() }
	# Tokenize by comma and/or whitespace while respecting quotes (single or double)
	$pattern = Get-LVCompareArgTokenPattern
	$mList = [regex]::Matches($s, $pattern)
	$list = @()
	foreach ($m in $mList) {
		$t = $m.Value.Trim()
		if ($t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length-2) }
		elseif ($t.StartsWith("'") -and $t.EndsWith("'")) { $t = $t.Substring(1, $t.Length-2) }
		if ($t -ne '') { $list += $t }
	}
	return $list
}

function Convert-ArgTokensNormalized([string[]]$tokens) {
	if (-not $tokens) { return @() }
	& $script:CompareModule { param($innerTokens) Convert-ArgTokenList -tokens $innerTokens } $tokens
}

function Test-ArgTokensValid([string[]]$tokens) {
	# Validate that any -lvpath is followed by a value token
	for ($i=0; $i -lt $tokens.Count; $i++) {
		if ($tokens[$i] -ieq '-lvpath') {
			if ($i -eq $tokens.Count - 1) { throw "Invalid LVCompare args: -lvpath requires a following path value" }
			$next = $tokens[$i+1]
			if (-not $next -or $next.StartsWith('-')) { throw "Invalid LVCompare args: -lvpath must be followed by a path value" }
		}
	}
	return $true
}

function Format-QuotedToken([string]$t) {
	if ($t -match '"|\s') {
		$escaped = $t -replace '"','\"'
		return '"{0}"' -f $escaped
	}
	return $t
}

function New-DirectoryIfMissing([string]$path) {
	$dir = $path
	if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# Resolve inputs
# capture working directory if needed in future (not used currently)
$baseItem = Get-Item -LiteralPath $Base -ErrorAction Stop
$headItem = Get-Item -LiteralPath $Head -ErrorAction Stop
if ($baseItem.PSIsContainer) { throw "Base path refers to a directory, expected a VI file: $($baseItem.FullName)" }
if ($headItem.PSIsContainer) { throw "Head path refers to a directory, expected a VI file: $($headItem.FullName)" }
$basePath = (Resolve-Path -LiteralPath $baseItem.FullName).Path
$headPath = (Resolve-Path -LiteralPath $headItem.FullName).Path
# Preflight: disallow identical filenames in different directories (prevents LVCompare UI dialog)
$baseLeaf = Split-Path -Leaf $basePath
$headLeaf = Split-Path -Leaf $headPath
if ($baseLeaf -ieq $headLeaf -and $basePath -ne $headPath) { throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$basePath Head=$headPath" }
$argsList = ConvertTo-ArgList -value $LvArgs
$argsList = Convert-ArgTokensNormalized -tokens $argsList
Test-ArgTokensValid -tokens $argsList | Out-Null
$cliPath = Resolve-CanonicalCliPath -Override $LvComparePath

# Prepare output paths
New-DirectoryIfMissing -path $OutputDir
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$jsonPath   = Join-Path $OutputDir 'lvcompare-capture.json'
$reportPath = Join-Path $OutputDir 'compare-report.html'

# Build process start info
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $cliPath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$psi.RedirectStandardError = $true
try { $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden } catch {}
try { $psi.ErrorDialog = $false } catch {}

# Argument order: base, head, flags
$psi.ArgumentList.Clear()
$psi.ArgumentList.Add($basePath) | Out-Null
$psi.ArgumentList.Add($headPath) | Out-Null
foreach ($a in $argsList) { if ($a) { $psi.ArgumentList.Add([string]$a) | Out-Null } }

# Human-readable command string
$cmdTokens = @($cliPath, $basePath, $headPath) + @($argsList)
$commandDisplay = ($cmdTokens | ForEach-Object { Format-QuotedToken $_ }) -join ' '

# Invoke and capture
$lvBefore = @()
try { $lvBefore = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch { $lvBefore = @() }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$timedOut = $false
$completed = $p.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
if (-not $completed) {
	$timedOut = $true
	if ($KillOnTimeout.IsPresent) {
		try { $p.Kill($true) } catch {}
		# Best-effort wait after kill
		try { [void]$p.WaitForExit(5000) } catch {}
	}
}

# Only read streams once the process has exited (either naturally or after kill)
if ($p.HasExited) {
	$stdout = $p.StandardOutput.ReadToEnd()
	$stderr = $p.StandardError.ReadToEnd()
} else {
	# Avoid blocking on streams if the process is still alive
	$stdout = ''
	$stderr = ''
}

$sw.Stop()
$exitCode = if ($p.HasExited) { [int]$p.ExitCode } else { if ($timedOut) { 124 } else { -1 } }

# Write artifacts
Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding utf8
Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding utf8
Set-Content -LiteralPath $exitPath   -Value ($exitCode.ToString()) -Encoding utf8

$flagsOnly = @()
$lvPathValue = $null
for ($i = 0; $i -lt $argsList.Count; $i++) {
  $token = $argsList[$i]
  if ($token -ieq '-lvpath' -and ($i + 1) -lt $argsList.Count) {
    $lvPathValue = $argsList[$i + 1]
    $i++
    continue
  }
  $flagsOnly += $token
}

$diffDetected = switch ($exitCode) {
  1 { $true }
  0 { $false }
  default { $null }
}

$capture = [pscustomobject]@{
	schema    = 'lvcompare-capture-v1'
	timestamp = ([DateTime]::UtcNow.ToString('o'))
	base      = $basePath
	head      = $headPath
	cliPath   = $cliPath
	args      = @($argsList)
	lvPath    = $lvPathValue
	flags     = @($flagsOnly)
	exitCode  = $exitCode
	seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 6)
	stdoutLen = $stdout.Length
	stderrLen = $stderr.Length
	command   = $commandDisplay
	diffDetected = $diffDetected
	stdout    = $null
	stderr    = $null
}
# annotate timeout condition when it occurs
if ($timedOut) { $capture | Add-Member -NotePropertyName 'timedOut' -NotePropertyValue $true -Force }
$capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8

if ($RenderReport.IsPresent) {
	try {
		$diff = if ($exitCode -eq 1) { 'true' } elseif ($exitCode -eq 0) { 'false' } else { 'unknown' }
		$sec  = [Math]::Round($sw.Elapsed.TotalSeconds, 6)
		$reportScript = Join-Path $PSScriptRoot 'Render-CompareReport.ps1'
        & $reportScript `
            -Command $commandDisplay `
            -ExitCode $exitCode `
            -Diff $diff `
            -CliPath $cliPath `
            -DurationSeconds $sec `
			-Base $basePath `
			-Head $headPath `
			-OutputPath $reportPath | Out-Null
	} catch {
		if (-not $Quiet) { Write-Warning ("Failed to render compare report: {0}" -f $_.Exception.Message) }
	}
}

if (-not $Quiet) {
	Write-Host ("LVCompare exit code: {0}" -f $exitCode)
	Write-Host ("Capture JSON: {0}" -f $jsonPath)
	if ($RenderReport.IsPresent) { Write-Host ("Report: {0} (exists={1})" -f $reportPath, (Test-Path $reportPath)) }
}

# Cleanup policy: close LabVIEW spawned during run when requested
$shouldClose = $CloseOnComplete.IsPresent
if (-not $shouldClose) {
  if ($env:ENABLE_LABVIEW_CLEANUP -match '^(?i:1|true|yes|on)$') { $shouldClose = $true }
  elseif (($env:GITHUB_ACTIONS -eq 'true' -or $env:CI -eq 'true') -and -not ($env:ENABLE_LABVIEW_CLEANUP -match '^(?i:0|false|no|off)$')) {
    $shouldClose = $true
  }
}

if ($shouldClose) {
  try {
    $lvAfter = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
    if ($lvAfter) {
      $beforeSet = @{}
      foreach ($id in $lvBefore) { $beforeSet[[string]$id] = $true }
      $newOnes = @()
      foreach ($proc in $lvAfter) { if (-not $beforeSet.ContainsKey([string]$proc.Id)) { $newOnes += $proc } }
      foreach ($proc in $newOnes) {
        try {
          $null = $proc.CloseMainWindow()
          Start-Sleep -Milliseconds 500
          if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
      }
      if ($newOnes.Count -gt 0 -and -not $Quiet) {
        Write-Host ("Closed LabVIEW spawned by LVCompare: {0}" -f ($newOnes | Select-Object -ExpandProperty Id -join ',')) -ForegroundColor DarkGray
      }
    }
  } catch {}
}
