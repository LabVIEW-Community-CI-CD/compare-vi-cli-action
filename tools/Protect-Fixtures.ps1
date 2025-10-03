<#
.SYNOPSIS
	Fixture integrity protection: snapshot and assert canonical VI files.

.DESCRIPTION
	Provides two primary operations:
		1. Start-FixtureSnapshot (or -Command Start): captures size + SHA256 hash of target fixtures
			 and (optionally) sets them read-only.
		2. Assert-FixtureIntegrity (or -Command Assert): validates the current files match the snapshot
			 and emits a structured integrity report.

	Intended to detect silent mutation or truncation of `VI1.vi` / `VI2.vi` during test or CI runs.

	Exit Codes (non-zero are violations / errors):
		0  OK / No violations
		11 Missing fixture at snapshot time (snapshot aborted)
		12 Manifest mismatch during snapshot (hash or minBytes)
		13 Hash mismatch detected at assert
		14 Size shrink detected at assert
		15 Previously existing file now missing at assert
		16 Snapshot file unreadable / invalid
		17 Manifest drift (snapshot vs current manifest) unless ignored

	Severity precedence when multiple violate: Missing > Shrink > HashMismatch.

	Snapshot JSON schema: fixture-snapshot-v1
	Report JSON schema:   fixture-integrity-report-v1

.PARAMETER Command
	Optional convenience mode: Start | Assert (alternative to invoking functions directly).

.PARAMETER SnapshotPath
	Path for snapshot output (Start) or input (Assert). Default: .fixture-snapshot.json

.PARAMETER Targets
	Target file names (default: VI1.vi,VI2.vi). Resolved relative to repo root (current directory).

.PARAMETER SkipManifestCrossCheck
	Do not validate snapshot results against fixtures.manifest.json (not recommended in CI).

.PARAMETER SetReadOnly
	After snapshot, set read-only attribute on target files (best-effort). Stored in snapshot for reference.

.PARAMETER ClearReadOnly
	After assertion, clear read-only attribute (best-effort) if set.

.PARAMETER IgnoreManifestDrift
	Do not treat manifest changes after snapshot as violation.

.PARAMETER Quiet
	Suppress human-readable banner; still emits JSON to stdout.

.PARAMETER CorrelateWatcher / WatcherLogPath
	(Future/reserved) If provided, attempts to attach recent watcher log entries to the report; currently ignored unless file present.

.EXAMPLES
	pwsh -File tools/Protect-Fixtures.ps1 -Command Start
	pwsh -File tools/Protect-Fixtures.ps1 -Command Assert
	# Direct function usage
	. ./tools/Protect-Fixtures.ps1; Start-FixtureSnapshot -SetReadOnly; Assert-FixtureIntegrity -ClearReadOnly

.NOTES
	Deterministic JSON emission: property ordering stabilized via ordered hashtables.
	Requires PowerShell 7+ (uses ordered hashtable insertion semantics).
#>

#Requires -Version 7.0
[CmdletBinding()]param(
	[ValidateSet('Start','Assert')][string]$Command,
	[string]$SnapshotPath = '.fixture-snapshot.json',
	[string[]]$Targets = @('VI1.vi','VI2.vi'),
	[switch]$SkipManifestCrossCheck,
	[switch]$SetReadOnly,
	[switch]$ClearReadOnly,
	[switch]$IgnoreManifestDrift,
	[switch]$Quiet,
	[switch]$CorrelateWatcher,
	[string]$WatcherLogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FixtureManifest {
	$manifestPath = Join-Path (Get-Location) 'fixtures.manifest.json'
	if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
	try {
		return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
	} catch {
		Write-Warning "Failed to parse fixtures.manifest.json: $_"; return $null
	}
}

function Get-FileSha256Hex {
	param([Parameter(Mandatory)][string]$Path)
	$bytes = [System.IO.File]::ReadAllBytes($Path)
	([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-FixtureMetadata {
	param([string]$Name,[object]$ManifestEntry)
	$full = Join-Path (Get-Location) $Name
	$exists = Test-Path -LiteralPath $full
	$length = 0
	$sha = $null
	if ($exists) {
		$fi = Get-Item -LiteralPath $full
		$length = [int64]$fi.Length
		try { $sha = Get-FileSha256Hex -Path $full } catch { $sha = $null }
	}
	[pscustomobject]@{
		name = $Name
		fullPath = $full
		exists = $exists
		length = $length
		sha256 = $sha
		manifestHash = if ($ManifestEntry) { $ManifestEntry.hash } else { $null }
		manifestMinBytes = if ($ManifestEntry) { $ManifestEntry.minBytes } else { $null }
		readOnly = if ($exists) { ([System.IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReadOnly) -ne 0 } else { $false }
	}
}

function Write-DeterministicJson {
	param([Parameter(Mandatory)][object]$Object)
	# Convert ordered hashtables / PSCustomObjects; ensure arrays of objects are stabilized by name where relevant.
	$json = $Object | ConvertTo-Json -Depth 8 -Compress
	Write-Output $json
}

function Start-FixtureSnapshot {
	[CmdletBinding()]param(
		[string]$Path = $SnapshotPath,
		[string[]]$Targets = $Targets,
		[switch]$SkipManifestCrossCheck,
		[switch]$SetReadOnly,
		[switch]$Quiet
	)
	if (-not $Quiet) { Write-Host "[FixtureProtect] Snapshot -> $Path" -ForegroundColor Cyan }
	$manifest = if (-not $SkipManifestCrossCheck) { Get-FixtureManifest } else { $null }
	$manifestMap = @{}
	if ($manifest -and $manifest.files) {
		foreach ($f in $manifest.files) { $manifestMap[$f.name] = $f }
	}
	$missing = @()
	$manifestViolations = @()
	$fileObjs = foreach ($t in $Targets) {
		$mEntry = if ($manifestMap.ContainsKey($t)) { $manifestMap[$t] } else { $null }
		$meta = Get-FixtureMetadata -Name $t -ManifestEntry $mEntry
		if (-not $meta.exists) { $missing += $t }
		if ($mEntry -and $meta.exists) {
			if ($mEntry.hash -and $meta.sha256 -and ($mEntry.hash -ne $meta.sha256)) { $manifestViolations += "$t: hash mismatch (manifest=$($mEntry.hash) snapshot=$($meta.sha256))" }
			if ($mEntry.minBytes -and ($meta.length -lt [int64]$mEntry.minBytes)) { $manifestViolations += "$t: size $($meta.length) < minBytes $($mEntry.minBytes)" }
		}
		$meta
	}
	if ($missing.Count -gt 0) {
		if (-not $Quiet) { Write-Error "Missing fixture(s): $($missing -join ', ')" }
		$exit = 11
		$filesOrdered = $fileObjs | Sort-Object name
		$snapshotObj = [ordered]@{
			schema = 'fixture-snapshot-v1'
			version = 1
			root = (Get-Location).ProviderPath
			takenAtUtc = (Get-Date).ToUniversalTime().ToString('o')
			files = $filesOrdered
		}
		Write-DeterministicJson -Object $snapshotObj | Out-Null
		exit $exit
	}
	if ($manifestViolations.Count -gt 0 -and -not $SkipManifestCrossCheck) {
		if (-not $Quiet) { Write-Error "Manifest violations: $($manifestViolations -join '; ')" }
		$exit = 12
		$filesOrdered = $fileObjs | Sort-Object name
		$snapshotObj = [ordered]@{
			schema = 'fixture-snapshot-v1'
			version = 1
			root = (Get-Location).ProviderPath
			takenAtUtc = (Get-Date).ToUniversalTime().ToString('o')
			files = $filesOrdered
			manifestViolations = $manifestViolations
		}
		Write-DeterministicJson -Object $snapshotObj | Out-Null
		Set-Content -LiteralPath $Path -Value ($snapshotObj | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
		exit $exit
	}
	if ($SetReadOnly) {
		foreach ($fo in $fileObjs) {
			if ($fo.exists -and -not $fo.readOnly) {
				try { (Get-Item -LiteralPath $fo.fullPath).Attributes += [IO.FileAttributes]::ReadOnly } catch { Write-Warning "Failed to set read-only: $($fo.fullPath) $_" }
			}
		}
		# Refresh metadata to record readOnly state
		$fileObjs = foreach ($t in $Targets) { Get-FixtureMetadata -Name $t -ManifestEntry ($manifestMap[$t]) }
	}
	$filesOrderedFinal = $fileObjs | Sort-Object name
	$snapshot = [ordered]@{
		schema = 'fixture-snapshot-v1'
		version = 1
		root = (Get-Location).ProviderPath
		takenAtUtc = (Get-Date).ToUniversalTime().ToString('o')
		files = $filesOrderedFinal
		manifestHashMode = if ($SkipManifestCrossCheck) { 'skipped' } else { 'enforced' }
		setReadOnly = [bool]$SetReadOnly
	}
	$jsonOut = $snapshot | ConvertTo-Json -Depth 8 -Compress
	Set-Content -LiteralPath $Path -Value $jsonOut -Encoding UTF8
	Write-Output $jsonOut
	if (-not $Quiet) { Write-Host "[FixtureProtect] Snapshot complete ($Path)" -ForegroundColor Green }
	return $snapshot
}

function Get-ViolationSeverity {
	param([string]$Status)
	switch ($Status) {
		'MISSING' { return 3 }
		'SIZE_SHRINK' { return 2 }
		'HASH_MISMATCH' { return 1 }
		default { return 0 }
	}
}

function Assert-FixtureIntegrity {
	[CmdletBinding()]param(
		[string]$SnapshotPath = $SnapshotPath,
		[switch]$ClearReadOnly,
		[switch]$IgnoreManifestDrift,
		[switch]$Quiet,
		[switch]$CorrelateWatcher,
		[string]$WatcherLogPath
	)
	if (-not (Test-Path -LiteralPath $SnapshotPath)) { Write-Error "Snapshot not found: $SnapshotPath"; exit 16 }
	if (-not $Quiet) { Write-Host "[FixtureProtect] Assert using snapshot $SnapshotPath" -ForegroundColor Cyan }
	try { $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { Write-Error "Invalid snapshot JSON: $_"; exit 16 }
	$manifestCurrent = Get-FixtureManifest
	$manifestMap = @{}
	if ($manifestCurrent -and $manifestCurrent.files) { foreach ($f in $manifestCurrent.files) { $manifestMap[$f.name] = $f } }
	$filesReport = @()
	$worst = 0
	foreach ($snapFile in $snapshot.files) {
		$currentMeta = Get-FixtureMetadata -Name $snapFile.name -ManifestEntry ($manifestMap[$snapFile.name])
		$status = 'OK'
		if ($snapFile.exists -and -not $currentMeta.exists) { $status = 'MISSING' }
		elseif ($snapFile.exists -and $currentMeta.exists) {
			if ($snapFile.sha256 -and $currentMeta.sha256 -and ($snapFile.sha256 -ne $currentMeta.sha256)) { $status = 'HASH_MISMATCH' }
			if ($currentMeta.length -lt $snapFile.length) { $status = 'SIZE_SHRINK' }
		}
		$sev = Get-ViolationSeverity -Status $status
		if ($sev -gt $worst) { $worst = $sev }
		$filesReport += [pscustomobject]@{
			name = $snapFile.name
			expectedHash = $snapFile.sha256
			actualHash = $currentMeta.sha256
			expectedLength = $snapFile.length
			actualLength = $currentMeta.length
			status = $status
			deltas = [pscustomobject]@{
				lengthDelta = ($currentMeta.length - $snapFile.length)
				grew = ($currentMeta.length -gt $snapFile.length)
				shrank = ($currentMeta.length -lt $snapFile.length)
			}
			existedAtSnapshot = [bool]$snapFile.exists
			existsNow = [bool]$currentMeta.exists
			manifestHash = $currentMeta.manifestHash
			manifestMinBytes = $currentMeta.manifestMinBytes
		}
	}
	$manifestDrift = @()
	if ($manifestCurrent -and $snapshot.files) {
		foreach ($sf in $snapshot.files) {
			if ($manifestMap.ContainsKey($sf.name)) {
				$m = $manifestMap[$sf.name]
				if ($m.hash -and $sf.sha256 -and ($m.hash -ne $sf.sha256)) { $manifestDrift += "$($sf.name): hash changed (snapshot=$($sf.sha256) manifest=$($m.hash))" }
			}
		}
	}
	$overall = if ($worst -gt 0) { 'VIOLATION' } else { 'OK' }
	$correlated = @()
	if ($CorrelateWatcher -and $WatcherLogPath -and (Test-Path -LiteralPath $WatcherLogPath)) {
		try {
			# Read last 100 lines (if large) to limit memory, then parse JSON lines safely
			$rawLines = Get-Content -LiteralPath $WatcherLogPath -ErrorAction Stop
			if ($rawLines.Count -gt 1000) { $rawLines = $rawLines[-1000..-1] }
			$targetNames = [System.Collections.Generic.HashSet[string]]::new()
			foreach ($f in $filesReport) { [void]$targetNames.Add($f.name) }
			$events = @()
			foreach ($line in ($rawLines | Where-Object { $_.Length -gt 0 })) {
				try {
					$evt = $null
					$evt = $line | ConvertFrom-Json -ErrorAction Stop
					if ($evt -and ($evt.PSObject.Properties.Name -contains 'event')) {
						# Filter only events for our targets (name or oldName present)
						$related = $false
						if ($evt.PSObject.Properties.Name -contains 'name' -and $evt.name -and $targetNames.Contains($evt.name)) { $related = $true }
						elseif ($evt.PSObject.Properties.Name -contains 'oldName' -and $evt.oldName -and $targetNames.Contains($evt.oldName)) { $related = $true }
						if ($related) { $events += $evt }
					}
				} catch { }
			}
			if ($events.Count -gt 0) {
				# Sort by tsUtc if present, else keep original order; take last 25
				try {
					$events = $events | Sort-Object { $_.tsUtc }
				} catch { }
				$correlated = $events | Select-Object -Last 25
			}
		} catch { if (-not $Quiet) { Write-Warning "[FixtureProtect] Failed watcher correlation: $_" } }
	}
	$report = [ordered]@{
		schema = 'fixture-integrity-report-v1'
		version = 1
		root = (Get-Location).ProviderPath
		snapshotTakenAtUtc = $snapshot.takenAtUtc
		assertedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
		overallStatus = $overall
		violations = ($filesReport | Where-Object { $_.status -ne 'OK' }).Count
		files = ($filesReport | Sort-Object name)
		manifestDrift = if ($manifestDrift.Count -gt 0) { $manifestDrift } else { @() }
		correlatedWatcherEvents = $correlated
		correlatedWatcherSource = if ($CorrelateWatcher -and $WatcherLogPath) { $WatcherLogPath } else { $null }
	}
	$json = $report | ConvertTo-Json -Depth 8 -Compress
	Write-Output $json
	if ($ClearReadOnly) {
		foreach ($f in $filesReport) {
			if (Test-Path -LiteralPath $f.name) {
				$full = (Resolve-Path -LiteralPath $f.name).ProviderPath
				try {
					$item = Get-Item -LiteralPath $full
					if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) { $item.Attributes = ($item.Attributes -bxor [IO.FileAttributes]::ReadOnly) }
				} catch { Write-Warning "Failed clearing read-only: $full $_" }
			}
		}
	}
	$exitCode = 0
	switch ($worst) {
		3 { $exitCode = 15 }
		2 { $exitCode = 14 }
		1 { $exitCode = 13 }
		default { $exitCode = 0 }
	}
	if ($manifestDrift.Count -gt 0 -and -not $IgnoreManifestDrift) { $exitCode = 17 }
	if (-not $Quiet) {
		if ($exitCode -eq 0) { Write-Host "[FixtureProtect] Integrity OK" -ForegroundColor Green }
		else { Write-Host "[FixtureProtect] Integrity violations detected (exit $exitCode)" -ForegroundColor Red }
	}
	exit $exitCode
}

if ($PSCommandPath -and $MyInvocation.InvocationName -eq '.') { return } # dot-sourced

if ($Command) {
	switch ($Command) {
		'Start' { Start-FixtureSnapshot -Path $SnapshotPath -Targets $Targets -SkipManifestCrossCheck:$SkipManifestCrossCheck -SetReadOnly:$SetReadOnly -Quiet:$Quiet | Out-Null }
		'Assert' { Assert-FixtureIntegrity -SnapshotPath $SnapshotPath -ClearReadOnly:$ClearReadOnly -IgnoreManifestDrift:$IgnoreManifestDrift -Quiet:$Quiet -CorrelateWatcher:$CorrelateWatcher -WatcherLogPath $WatcherLogPath | Out-Null }
	}
}

