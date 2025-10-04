<#
.SYNOPSIS
	Orchestrates fixture validation outcomes into deterministic artifacts and exit semantics.
.DESCRIPTION
	Consumes JSON from tools/Validate-Fixtures.ps1 and, on drift (exit 6), optionally runs LVCompare
	and renders an HTML report. Always emits a drift-summary.json with ordered keys for CI consumption.

	Windows/PowerShell-only; respects canonical LVCompare.exe path policy.

.PARAMETER StrictJson
	Path to validator JSON output (strict mode).
.PARAMETER OverrideJson
	Optional path to validator JSON output with -TestAllowFixtureUpdate (size-only snapshot).
.PARAMETER ManifestPath
	Path to fixtures.manifest.json (defaults to repo root file).
.PARAMETER BasePath
	Path to base VI (defaults to ./VI1.vi).
.PARAMETER HeadPath
	Path to head VI (defaults to ./VI2.vi).
.PARAMETER OutputDir
	Output directory for artifacts (created if missing). Defaults to results/fixture-drift/<yyyyMMddTHHmmssZ>.
.PARAMETER LvCompareArgs
	Additional args for LVCompare (default: -nobdcosm -nofppos -noattr).
.PARAMETER RenderReport
	If set and LVCompare is available, generate compare-report.html via scripts/Render-CompareReport.ps1.

.OUTPUTS
	Writes drift-summary.json to OutputDir. Exits 0 only when strict ok=true; non-zero otherwise.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$StrictJson,
	[string]$OverrideJson,
	[string]$ManifestPath = (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'fixtures.manifest.json'),
	[string]$BasePath = (Join-Path (Get-Location) 'VI1.vi'),
	[string]$HeadPath = (Join-Path (Get-Location) 'VI2.vi'),
	[string]$OutputDir,
	[string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
	[switch]$RenderReport,
	[switch]$SimulateCompare  # TEST-ONLY: simulate compare outputs and exit code 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-Directory([string]$dir) {
	if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Get-NowStampUtc { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }

function Read-JsonFile([string]$path) {
	$raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
	return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Copy-FileIf([string]$src,[string]$dst) { if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force } }

function Get-FileStamp([string]$path) {
	try {
		if (-not (Test-Path -LiteralPath $path)) { return $null }
		$fi = Get-Item -LiteralPath $path -ErrorAction Stop
		$ts = $fi.LastWriteTimeUtc.ToString('o')
		# Prefer leaf name for stable display; avoid leaking absolute paths
		$name = $fi.Name
		return [pscustomobject]@{ path=$name; lastWriteTimeUtc=$ts; length=$fi.Length }
	} catch { return $null }
}

# Resolve default OutputDir
if (-not $OutputDir) {
	$root = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
	$outRoot = Join-Path $root 'results' | Join-Path -ChildPath 'fixture-drift'
	Initialize-Directory $outRoot
	$OutputDir = Join-Path $outRoot (Get-NowStampUtc)
}
Initialize-Directory $OutputDir

# Read strict/override JSONs
$strict = Read-JsonFile $StrictJson

# Copy inputs for artifact stability
Copy-FileIf $StrictJson (Join-Path $OutputDir 'validator-strict.json')
if ($OverrideJson) { Copy-FileIf $OverrideJson (Join-Path $OutputDir 'validator-override.json') }
Copy-FileIf $ManifestPath (Join-Path $OutputDir 'fixtures.manifest.json')

# Build file timestamp list (deterministic order)
$fileInfos = New-Object System.Collections.Generic.List[object]
foreach ($p in @($BasePath, $HeadPath, $ManifestPath, $StrictJson, $OverrideJson)) {
	if ($p) { $fs = Get-FileStamp $p; if ($fs) { $fileInfos.Add($fs) | Out-Null } }
}

# Determine outcome from strict JSON
$strictExit = $strict.exitCode
$categories = @()
if ($strict.summaryCounts) {
	foreach ($k in 'missing','untracked','tooSmall','hashMismatch','manifestError','duplicate','schema') {
		$v = 0; if ($strict.summaryCounts.PSObject.Properties[$k]) { $v = [int]$strict.summaryCounts.$k }
		if ($v -gt 0) { $categories += "$k=$v" }
	}
}

$summary = [ordered]@{ schema='fixture-drift-summary-v1'; generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); status=''; exitCode=$strictExit; categories=$categories; artifactPaths=@(); notes=@(); files=@() }
foreach ($fi in $fileInfos) { $summary.files += $fi }

function Add-Artifact([string]$rel) { $summary.artifactPaths += $rel }
function Add-Note([string]$n) { $summary.notes += $n }

if ($strictExit -eq 0 -and $strict.ok) {
	$summary.status = 'ok'
	Add-Artifact 'validator-strict.json'
	if ($OverrideJson) { Add-Artifact 'validator-override.json' }
	$outPath = Join-Path $OutputDir 'drift-summary.json'
	($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8
	exit 0
}

# Non-zero: produce diagnostics and optionally run LVCompare
Add-Artifact 'validator-strict.json'
if ($OverrideJson) { Add-Artifact 'validator-override.json' }
Add-Artifact 'fixtures.manifest.json'

if ($strictExit -eq 6) {
	$summary.status = 'drift'
	$cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
	$cliExists = if ($SimulateCompare) { $true } else { Test-Path -LiteralPath $cli }
	if (-not $RenderReport) { Add-Note 'RenderReport disabled; skipping LVCompare' }
	if (-not $cliExists) { Add-Note 'LVCompare.exe missing at canonical path' }

	$exitCode = $null
	$duration = $null
		if ($RenderReport -and $cliExists) {
		try {
			if ($SimulateCompare) {
				# Test-only simulated outputs
				$stdout = 'simulated lvcompare output'
				$stderr = ''
				$exitCode = 1
				$duration = 0.01
			} else {
				$sw = [System.Diagnostics.Stopwatch]::StartNew()
				$psi = New-Object System.Diagnostics.ProcessStartInfo
				$psi.FileName = $cli
				$psi.Arguments = ('"{0}" "{1}" {2}' -f (Resolve-Path $BasePath).Path, (Resolve-Path $HeadPath).Path, $LvCompareArgs)
				$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
				$p = [System.Diagnostics.Process]::Start($psi)
				$stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit(); $sw.Stop()
				$duration = [math]::Round($sw.Elapsed.TotalSeconds,3)
				$exitCode = $p.ExitCode
			}
					$stdout | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-stdout.txt') -Encoding utf8
			$stderr | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-stderr.txt') -Encoding utf8
			"$exitCode" | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-exitcode.txt')
			Add-Artifact 'lvcompare-stdout.txt'
			Add-Artifact 'lvcompare-stderr.txt'
			Add-Artifact 'lvcompare-exitcode.txt'

			# Generate HTML report via reporter script (invoke directly to avoid host quoting issues)
			$reporter = Join-Path (Join-Path $PSScriptRoot '') 'Render-CompareReport.ps1'
			if (Test-Path -LiteralPath $reporter) {
						$diff = if ($exitCode -eq 1) { 'true' } elseif ($exitCode -eq 0) { 'false' } else { 'false' }
						# Resolve Base/Head robustly: prefer given path, else try repo root relative to scripts/, else leave as-is for simulate
						$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
						$baseResolved = $null; $headResolved = $null
						try { if ($BasePath -and (Test-Path -LiteralPath $BasePath)) { $baseResolved = (Resolve-Path -LiteralPath $BasePath).Path } } catch {}
						try { if ($HeadPath -and (Test-Path -LiteralPath $HeadPath)) { $headResolved = (Resolve-Path -LiteralPath $HeadPath).Path } } catch {}
						if (-not $baseResolved) {
							$cand = Join-Path $repoRoot (Split-Path -Leaf $BasePath)
							if (Test-Path -LiteralPath $cand) { $baseResolved = (Resolve-Path -LiteralPath $cand).Path } else { $baseResolved = $BasePath }
						}
						if (-not $headResolved) {
							$cand = Join-Path $repoRoot (Split-Path -Leaf $HeadPath)
							if (Test-Path -LiteralPath $cand) { $headResolved = (Resolve-Path -LiteralPath $cand).Path } else { $headResolved = $HeadPath }
						}
						$cmd = '"{0}" "{1}" {2}' -f $cli,$baseResolved,$headResolved
				try {
							& $reporter -Command $cmd -ExitCode $exitCode -Diff $diff -CliPath $cli -Base $baseResolved -Head $headResolved -DurationSeconds $duration -OutputPath (Join-Path $OutputDir 'compare-report.html') | Out-Null
					Add-Artifact 'compare-report.html'
				} catch {
					Add-Note ("Reporter failed: {0}" -f $_.Exception.Message)
				}
			} else { Add-Note 'Reporter script not found; skipped HTML report' }
		} catch {
			Add-Note ("LVCompare or report generation failed: {0}" -f $_.Exception.Message)
		}
	}

	$outPath = Join-Path $OutputDir 'drift-summary.json'
	($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8
	exit 1
}
else {
	$summary.status = 'fail-structural'
	$hint = @()
	if ($strict.summaryCounts) {
		$sc = $strict.summaryCounts
		if ($sc.missing -gt 0) { $hint += 'missing fixtures' }
		if ($sc.untracked -gt 0) { $hint += 'untracked fixtures' }
		if ($sc.tooSmall -gt 0) { $hint += 'too small' }
		if ($sc.duplicate -gt 0) { $hint += 'duplicate entries' }
		if ($sc.schema -gt 0) { $hint += 'schema issues' }
		if ($sc.manifestError -gt 0) { $hint += 'manifest errors' }
	}
	if ($hint) { ('Hints: ' + ($hint -join ', ')) | Set-Content -LiteralPath (Join-Path $OutputDir 'hints.txt') -Encoding utf8; Add-Artifact 'hints.txt' }
	$outPath = Join-Path $OutputDir 'drift-summary.json'
	($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8
	exit 1
}

