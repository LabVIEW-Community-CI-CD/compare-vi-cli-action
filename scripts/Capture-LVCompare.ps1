param(
	[Parameter(Mandatory=$true)][string]$Base,
	[Parameter(Mandatory=$true)][string]$Head,
	[Parameter()][object]$LvArgs,
	[Parameter()][switch]$RenderReport,
	[Parameter()][string]$OutputDir = 'tests/results',
	[Parameter()][switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Resolve-CanonicalCliPath {
	$cli = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
	if (-not (Test-Path -LiteralPath $cli)) {
		throw "LVCompare.exe not found at canonical path: $cli"
	}
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
	$pattern = '"[^"]+"|''[^'']+''|[^,\s]+'
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
	$out = @()
	foreach ($t in $tokens) {
		if ($null -eq $t) { continue }
		$s = $t.Trim()
		if ($s -match '^-' -and $s -match '\s+') {
			# Split first whitespace into flag + value (preserve inner spaces of value)
			$firstSpace = $s.IndexOf(' ')
			if ($firstSpace -gt 0) {
				$flag = $s.Substring(0,$firstSpace)
				$val  = $s.Substring($firstSpace+1)
				if ($flag) { $out += $flag }
				if ($val)  { $out += $val }
				continue
			}
		}
		$out += $s
	}
	return $out
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
$basePath = (Resolve-Path -LiteralPath $Base).Path
$headPath = (Resolve-Path -LiteralPath $Head).Path
$argsList = ConvertTo-ArgList -value $LvArgs
$argsList = Convert-ArgTokensNormalized -tokens $argsList
Test-ArgTokensValid -tokens $argsList | Out-Null
$cliPath = Resolve-CanonicalCliPath

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
$psi.RedirectStandardError = $true

# Argument order: base, head, flags
$psi.ArgumentList.Clear()
$psi.ArgumentList.Add($basePath) | Out-Null
$psi.ArgumentList.Add($headPath) | Out-Null
foreach ($a in $argsList) { if ($a) { $psi.ArgumentList.Add([string]$a) | Out-Null } }

# Human-readable command string
$cmdTokens = @($cliPath, $basePath, $headPath) + @($argsList)
$commandDisplay = ($cmdTokens | ForEach-Object { Format-QuotedToken $_ }) -join ' '

# Invoke and capture
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$stdout = $p.StandardOutput.ReadToEnd()
$stderr = $p.StandardError.ReadToEnd()
$p.WaitForExit()
$sw.Stop()
$exitCode = [int]$p.ExitCode

# Write artifacts
Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding utf8
Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding utf8
Set-Content -LiteralPath $exitPath   -Value ($exitCode.ToString()) -Encoding utf8

$capture = [pscustomobject]@{
	schema    = 'lvcompare-capture-v1'
	timestamp = ([DateTime]::UtcNow.ToString('o'))
	base      = $basePath
	head      = $headPath
	cliPath   = $cliPath
	args      = @($argsList)
	exitCode  = $exitCode
	seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 6)
	stdoutLen = $stdout.Length
	stderrLen = $stderr.Length
	command   = $commandDisplay
	stdout    = $null
	stderr    = $null
}
$capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8

if ($RenderReport.IsPresent) {
	try {
		$diff = if ($exitCode -eq 1) { 'true' } elseif ($exitCode -eq 0) { 'false' } else { 'unknown' }
		$sec  = [Math]::Round($sw.Elapsed.TotalSeconds, 6)
		$reportScript = Join-Path $PSScriptRoot 'Render-CompareReport.ps1'
		pwsh -NoLogo -NoProfile -File $reportScript `
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
