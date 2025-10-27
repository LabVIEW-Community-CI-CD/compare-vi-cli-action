param(
	[Parameter(Mandatory=$true)][string]$Base,
	[Parameter(Mandatory=$true)][string]$Head,
	[Parameter()][object]$LvArgs,
	[Parameter()][string]$LvComparePath,
	[Parameter()][switch]$RenderReport,
	[Parameter()][string]$OutputDir = 'tests/results',
	[Parameter()][switch]$Quiet,
	[Parameter()][switch]$AllowSameLeaf
)

$ErrorActionPreference = 'Stop'

$stageCleanupRoot = $null

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
	$tokensArray = @($tokens | ForEach-Object { $_ })
	if ($tokensArray.Count -eq 0) { return @() }
	try {
		$converted = & $script:CompareModule { param($innerTokens) Convert-ArgTokenList -tokens $innerTokens } $tokensArray
		if ($null -eq $converted) { return $tokensArray }
		if ($converted -is [System.Array]) { return @($converted) }
		return @([string]$converted)
	} catch {
		return $tokensArray
	}
}

function Test-ArgTokensValid([string[]]$tokens) {
	if (-not $tokens) { return $true }
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

function Get-FileProductVersion([string]$Path) {
	if (-not $Path) { return $null }
	try {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
		return ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)).ProductVersion
	} catch { return $null }
}

function Get-BinaryBitness([string]$Path) {
	if (-not $Path) { return $null }
	try {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
		$fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
		try {
			$br = New-Object System.IO.BinaryReader($fs)
			try {
				$fs.Seek(0x3CL, [System.IO.SeekOrigin]::Begin) | Out-Null
				$peOffset = $br.ReadInt32()
				$fs.Seek($peOffset + 4, [System.IO.SeekOrigin]::Begin) | Out-Null
				$machine = $br.ReadUInt16()
				switch ($machine) {
					0x014c { return 'x86' }
					0x8664 { return 'x64' }
					default { return $null }
				}
			} finally {
				if ($br) { $br.Dispose() }
			}
		} finally {
			if ($fs) { $fs.Dispose() }
		}
	} catch { return $null }
}

function Get-LabVIEWPathFromArgs([string[]]$Tokens) {
	if (-not $Tokens) { return $null }
	for ($i = 0; $i -lt $Tokens.Count; $i++) {
		$token = $Tokens[$i]
		if (-not $token) { continue }
		if ($token -ieq '-lvpath') {
			if ($i + 1 -lt $Tokens.Count) { return $Tokens[$i + 1] }
		} elseif ($token -like '-lvpath=*') {
			return $token.Substring($token.IndexOf('=') + 1)
		}
	}
	return $null
}

function Resolve-ExistingFilePath([string]$Path) {
	if (-not $Path) { return $null }
	try {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
		return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
	} catch { return $Path }
}

function Get-RunnerIdentityHash {
	$seedParts = @(
		$env:RUNNER_TRACKING_ID,
		$env:RUNNER_NAME,
		$env:COMPUTERNAME,
		$env:GITHUB_RUN_ID,
		$env:GITHUB_RUN_ATTEMPT,
		$env:AGENT_OS
	) | Where-Object { $_ -and $_.Trim() -ne '' }
	if (-not $seedParts -or $seedParts.Count -eq 0) { return $null }
	$seed = ($seedParts -join '|')
	try {
		$sha = [System.Security.Cryptography.SHA256]::Create()
		try {
			$bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
			$hashBytes = $sha.ComputeHash($bytes)
			if (-not $hashBytes) { return $null }
			$hex = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
			if ($hex.Length -gt 16) { return $hex.Substring(0,16) }
			return $hex
		} finally {
			if ($sha) { $sha.Dispose() }
		}
	} catch { return $null }
}

function Get-CliMetadataFromOutput {
	param(
		[string]$StdOut,
		[string]$StdErr
	)

	$meta = [ordered]@{}
	$regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

	if (-not [string]::IsNullOrWhiteSpace($StdOut)) {
		$reportMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, 'Report\s+Type\s*[:=]\s*(?<val>[^\r\n]+)', $regexOptions)
		if ($reportMatch.Success) { $meta.reportType = $reportMatch.Groups['val'].Value.Trim() }

		$reportPathMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, 'Report\s+(?:can\s+be\s+found|saved)\s+(?:at|to)\s+(?<val>[^\r\n]+)', $regexOptions)
		if ($reportPathMatch.Success) { $meta.reportPath = $reportPathMatch.Groups['val'].Value.Trim().Trim('"') }

		$statusMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, '(?:Comparison\s+Status|Status|Result)\s*[:=]\s*(?<val>[^\r\n]+)', $regexOptions)
		if ($statusMatch.Success) { $meta.status = $statusMatch.Groups['val'].Value.Trim() }

		$lines = @($StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		if ($lines.Count -gt 0) {
			$lastLine = $lines[-1]
			if ($lastLine) { $meta.message = $lastLine }
		}
	}

	if (-not $meta.Contains('message') -and -not [string]::IsNullOrWhiteSpace($StdErr)) {
		$errLines = @($StdErr -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		if ($errLines.Count -gt 0) { $meta['message'] = $errLines[-1] }
	}

	if ($meta.Contains('message')) {
		$messageValue = $meta['message']
		if ($messageValue -and $messageValue.Length -gt 512) { $meta['message'] = $messageValue.Substring(0,512) }
	}

	if ($meta.Count -gt 0) { return [pscustomobject]$meta }
	return $null
}

function Get-CliReportFileExtension {
	param([string]$MimeType)
	if (-not $MimeType) { return 'bin' }
	switch -Regex ($MimeType) {
		'^image/png' { return 'png' }
		'^image/jpeg' { return 'jpg' }
		'^image/gif' { return 'gif' }
		'^image/bmp' { return 'bmp' }
		default { return 'bin' }
	}
}

function Get-CliReportArtifacts {
	param(
		[Parameter(Mandatory)][string]$ReportPath,
		[Parameter(Mandatory)][string]$OutputDir
	)

	if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $null }

	try {
		$html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
	} catch { return $null }

	$artifactInfo = [ordered]@{}
	try {
		$item = Get-Item -LiteralPath $ReportPath -ErrorAction Stop
		if ($item -and $item.Length -ge 0) { $artifactInfo.reportSizeBytes = [long]$item.Length }
	} catch {}

	$imageMatches = @()
	try {
		$imagePattern = '<img\b[^>]*\bsrc\s*=\s*"([^"]+)"'
		$imageMatches = [regex]::Matches($html, $imagePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	} catch { $imageMatches = @() }

	if ($imageMatches.Count -eq 0) {
		if ($artifactInfo.Count -gt 0) { return [pscustomobject]$artifactInfo }
		return $null
	}

	$images = @()
	$exportDir = Join-Path $OutputDir 'cli-images'
	$exportDirResolved = $null
	try {
		New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
		$exportDirResolved = (Resolve-Path -LiteralPath $exportDir -ErrorAction Stop).Path
	} catch {
		$exportDirResolved = $exportDir
	}

	for ($idx = 0; $idx -lt $imageMatches.Count; $idx++) {
		$srcValue = $imageMatches[$idx].Groups[1].Value
		$imageEntry = [ordered]@{
			index = $idx
			dataLength = $srcValue.Length
		}

		$mime = $null
		$base64Data = $null
		if ($srcValue -match '^data:(?<mime>[^;]+);base64,(?<data>.+)$') {
			$mime = $Matches['mime']
			$base64Data = $Matches['data']
			$imageEntry.mimeType = $mime
		} else {
			$imageEntry.source = $srcValue
		}

		if ($base64Data) {
			try {
				$cleanBase64 = $base64Data -replace '\s', ''
				$bytes = [System.Convert]::FromBase64String($cleanBase64)
				if ($bytes) {
					$imageEntry.byteLength = $bytes.Length
					$extension = Get-CliReportFileExtension -MimeType $mime
					$fileName = 'cli-image-{0:D2}.{1}' -f $idx, $extension
					$filePath = Join-Path $exportDir $fileName
					[System.IO.File]::WriteAllBytes($filePath, $bytes)
					try {
						$imageEntry.savedPath = (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).Path
					} catch {
						$imageEntry.savedPath = $filePath
					}
				}
			} catch {
				$imageEntry.decodeError = $_.Exception.Message
			}
		}

		$images += [pscustomobject]$imageEntry
	}

	if ($images.Count -gt 0) {
		$artifactInfo.imageCount = $images.Count
		$artifactInfo.images = $images
		if ($exportDirResolved) { $artifactInfo.exportDir = $exportDirResolved }
	}

	if ($artifactInfo.Count -gt 0) { return [pscustomobject]$artifactInfo }
	return $null
}

# Resolve inputs
# capture working directory if needed in future (not used currently)
try {
	$baseItem = Get-Item -LiteralPath $Base -ErrorAction Stop
	$headItem = Get-Item -LiteralPath $Head -ErrorAction Stop
	if ($baseItem.PSIsContainer) { throw "Base path refers to a directory, expected a VI file: $($baseItem.FullName)" }
	if ($headItem.PSIsContainer) { throw "Head path refers to a directory, expected a VI file: $($headItem.FullName)" }
$basePath = (Resolve-Path -LiteralPath $baseItem.FullName).Path
$headPath = (Resolve-Path -LiteralPath $headItem.FullName).Path
	$stageScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'Stage-CompareInputs.ps1'
	$baseLeaf = Split-Path -Leaf $basePath
	$headLeaf = Split-Path -Leaf $headPath
	$allowSameLeaf = $AllowSameLeaf.IsPresent
	if ($basePath -ne $headPath -and $baseLeaf -ieq $headLeaf -and -not $allowSameLeaf) {
		if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
			throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$basePath Head=$headPath"
		}
		try {
			$stagingInfo = & $stageScript -BaseVi $basePath -HeadVi $headPath
		} catch {
			throw ("Capture-LVCompare: staging failed -> {0}" -f $_.Exception.Message)
		}
		if (-not $stagingInfo) { throw "Capture-LVCompare: Stage-CompareInputs.ps1 returned no staging information." }
		if ($stagingInfo.Root) { $stageCleanupRoot = $stagingInfo.Root }
		try { $basePath = (Resolve-Path -LiteralPath $stagingInfo.Base -ErrorAction Stop).Path } catch { $basePath = $stagingInfo.Base }
		try { $headPath = (Resolve-Path -LiteralPath $stagingInfo.Head -ErrorAction Stop).Path } catch { $headPath = $stagingInfo.Head }
		if ($stagingInfo.PSObject.Properties['AllowSameLeaf']) {
			try { $allowSameLeaf = [bool]$stagingInfo.AllowSameLeaf } catch { $allowSameLeaf = $false }
		}
		$baseLeaf = Split-Path -Leaf $basePath
		$headLeaf = Split-Path -Leaf $headPath
	}
	# Preflight: disallow identical filenames in different directories (prevents LVCompare UI dialog)
	if ($baseLeaf -ieq $headLeaf -and $basePath -ne $headPath -and -not $allowSameLeaf) { throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$basePath Head=$headPath" }
	$argsList = ConvertTo-ArgList -value $LvArgs
	$argsList = Convert-ArgTokensNormalized -tokens $argsList
	Test-ArgTokensValid -tokens $argsList | Out-Null
	$cliPath = Resolve-CanonicalCliPath -Override $LvComparePath
	$labviewFromArgs = Get-LabVIEWPathFromArgs -Tokens $argsList
	$labviewResolved = Resolve-ExistingFilePath -Path $labviewFromArgs
	if (-not $labviewResolved) {
		$envLv = @($env:LABVIEW_EXE, $env:LABVIEW_PATH) | Where-Object { $_ } | Select-Object -First 1
		$labviewResolved = Resolve-ExistingFilePath -Path $envLv
	}

# Prepare output paths
New-DirectoryIfMissing -path $OutputDir
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$jsonPath   = Join-Path $OutputDir 'lvcompare-capture.json'
$reportPath = Join-Path $OutputDir 'compare-report.html'

# Clear stale CLI artifacts so CreateComparisonReport does not fail on existing files
try {
	if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
		Remove-Item -LiteralPath $reportPath -Force -ErrorAction Stop
	}
} catch {
	if (-not $Quiet) { Write-Warning ("Failed to purge stale report {0}: {1}" -f $reportPath, $_.Exception.Message) }
}
$cliImagesDir = Join-Path $OutputDir 'cli-images'
try {
	if (Test-Path -LiteralPath $cliImagesDir -PathType Container) {
		Remove-Item -LiteralPath $cliImagesDir -Recurse -Force -ErrorAction Stop
	}
} catch {
	if (-not $Quiet) { Write-Warning ("Failed to purge stale CLI images {0}: {1}" -f $cliImagesDir, $_.Exception.Message) }
}

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

$environmentMetadata = [ordered]@{}
$lvcompareVersion = Get-FileProductVersion -Path $cliPath
if ($lvcompareVersion) { $environmentMetadata.lvcompareVersion = $lvcompareVersion }
$labviewVersion = Get-FileProductVersion -Path $labviewResolved
if ($labviewVersion) { $environmentMetadata.labviewVersion = $labviewVersion }
$bitness = Get-BinaryBitness -Path $cliPath
if ($bitness) { $environmentMetadata.bitness = $bitness }
$osVersion = [System.Environment]::OSVersion.VersionString
if ($osVersion) { $environmentMetadata.osVersion = $osVersion }
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($arch) { $environmentMetadata.arch = $arch }
$compareMode = $env:LVCI_COMPARE_MODE
if (-not [string]::IsNullOrWhiteSpace($compareMode)) { $environmentMetadata.compareMode = $compareMode }
$comparePolicy = $env:LVCI_COMPARE_POLICY
if (-not [string]::IsNullOrWhiteSpace($comparePolicy)) { $environmentMetadata.comparePolicy = $comparePolicy }

$cliCandidates = @($env:LABVIEW_CLI_PATH, $env:LABVIEWCLI_PATH, $env:LABVIEW_CLI)
$defaultCliPath = $null
if ([Environment]::Is64BitOperatingSystem) {
	$canonicalCli = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
	if (Test-Path -LiteralPath $canonicalCli -PathType Leaf) { $defaultCliPath = $canonicalCli }
} else {
	$canonicalCli = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
	if (Test-Path -LiteralPath $canonicalCli -PathType Leaf) { $defaultCliPath = $canonicalCli }
}
if ($defaultCliPath) { $cliCandidates += $defaultCliPath }
$labviewCliResolved = $null
foreach ($candidate in $cliCandidates) {
	if (-not [string]::IsNullOrWhiteSpace($candidate)) {
		$resolvedCandidate = Resolve-ExistingFilePath -Path $candidate
		if ($resolvedCandidate) { $labviewCliResolved = $resolvedCandidate; break }
	}
}
$cliInfo = [ordered]@{}
if ($labviewCliResolved) {
	$cliInfo.path = $labviewCliResolved
	$labviewCliVersion = Get-FileProductVersion -Path $labviewCliResolved
	if ($labviewCliVersion) { $cliInfo.version = $labviewCliVersion }
}
$cliOutputMeta = Get-CliMetadataFromOutput -StdOut $stdout -StdErr $stderr
if ($cliOutputMeta) {
	if ($cliOutputMeta.PSObject.Properties.Name -contains 'reportType' -and $cliOutputMeta.reportType) { $cliInfo.reportType = $cliOutputMeta.reportType }
	if ($cliOutputMeta.PSObject.Properties.Name -contains 'reportPath' -and $cliOutputMeta.reportPath) { $cliInfo.reportPath = $cliOutputMeta.reportPath }
	if ($cliOutputMeta.PSObject.Properties.Name -contains 'status' -and $cliOutputMeta.status) { $cliInfo.status = $cliOutputMeta.status }
	if ($cliOutputMeta.PSObject.Properties.Name -contains 'message' -and $cliOutputMeta.message) { $cliInfo.message = $cliOutputMeta.message }
}
$cliArtifacts = $null
if ($cliInfo.PSObject.Properties.Name -contains 'reportPath') {
	$cliReportPath = $cliInfo.reportPath
	if (-not $cliReportPath -and $cliInfo.PSObject.Properties.Name -contains 'ReportPath') {
		$cliReportPath = $cliInfo.ReportPath
	}
	if ($cliReportPath -and (Test-Path -LiteralPath $cliReportPath -PathType Leaf)) {
		try {
			$cliArtifacts = Get-CliReportArtifacts -ReportPath $cliReportPath -OutputDir $OutputDir
  } catch {}
}
} finally {
	if ($stageCleanupRoot) {
		try {
			if (Test-Path -LiteralPath $stageCleanupRoot -PathType Container) {
				Remove-Item -LiteralPath $stageCleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
			}
		} catch {}
	}
}
if ($cliArtifacts) { $cliInfo.artifacts = $cliArtifacts }
$cliInfoObject = [pscustomobject]$cliInfo
if ($cliInfoObject.PSObject.Properties.Count -gt 0) { $environmentMetadata.cli = $cliInfoObject }

$runnerInfo = [ordered]@{}
$runnerLabels = if ($env:RUNNER_LABELS) { $env:RUNNER_LABELS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
if ($runnerLabels.Count -gt 0) { $runnerInfo.labels = $runnerLabels }
$identityHash = Get-RunnerIdentityHash
if ($identityHash) { $runnerInfo.identityHash = $identityHash }
if ($runnerInfo.Count -gt 0) { $environmentMetadata.runner = [pscustomobject]$runnerInfo }
if ($environmentMetadata.Count -gt 0) {
	$envObject = [pscustomobject]$environmentMetadata
	$capture | Add-Member -NotePropertyName environment -NotePropertyValue $envObject -Force
}

$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding utf8

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

# Cleanup policy: do not close LabVIEW by default. Allow opt-in via ENABLE_LABVIEW_CLEANUP=1.
if ($env:ENABLE_LABVIEW_CLEANUP -match '^(?i:1|true|yes|on)$') {
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
