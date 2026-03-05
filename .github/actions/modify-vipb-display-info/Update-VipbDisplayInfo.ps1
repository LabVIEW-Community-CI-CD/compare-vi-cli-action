#Requires -Version 7.0

<#
.SYNOPSIS
    Updates VIPB metadata based on CLI inputs, mirroring Modify_VIPB_Display_Information.vi.

.DESCRIPTION
    Loads the specified VIPB file, adjusts display information fields (company,
    packager, summaries, release notes, etc.), regenerates the Modified_Date/ID,
    and keeps the configuration file reference aligned with the VIPB basename.
    Intended as a scriptable replacement for the LabVIEW helper VI.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$MinimumSupportedLVVersion,
    [ValidateSet('0','3')][string]$LabVIEWMinorRevision = '0',
    [Parameter(Mandatory)][ValidateSet('32','64')][string]$SupportedBitness,
    [Parameter(Mandatory)][int]$Major,
    [Parameter(Mandatory)][int]$Minor,
    [Parameter(Mandatory)][int]$Patch,
    [Parameter(Mandatory)][int]$Build,
    [string]$Commit,
    [Parameter(Mandatory)][string]$RelativePath,
    [Parameter(Mandatory)][string]$VIPBPath,
    [string]$ReleaseNotesFile,
    [Parameter(Mandatory)][string]$DisplayInformationJSON
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-VipbNodeValue {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$XPath,
        [AllowNull()][string]$Value
    )

    $node = $Document.SelectSingleNode($XPath)
    if (-not $node) {
        $lastSlash  = $XPath.LastIndexOf('/')
        if ($lastSlash -lt 0) { return }
        $parentPath = $XPath.Substring(0, $lastSlash)
        $childName  = $XPath.Substring($lastSlash + 1)
        $parent     = $Document.SelectSingleNode($parentPath)
        if (-not $parent) { return }

        $node = $Document.CreateElement($childName)
        $parent.AppendChild($node) | Out-Null
    }

    $node.InnerText = [string]$Value
}

function Resolve-ExistingPath {
    param([string]$PathCandidate)

    $resolved = Resolve-Path -Path $PathCandidate -ErrorAction SilentlyContinue
    if ($resolved) { return $resolved.ProviderPath }

    throw "Unable to resolve path '$PathCandidate'."
}

$resolvedRoot   = Resolve-ExistingPath -Path $RelativePath
$resolvedVipb   = Resolve-ExistingPath -Path (Join-Path -Path $resolvedRoot -ChildPath $VIPBPath)

if ($ReleaseNotesFile) {
    if ([System.IO.Path]::IsPathRooted($ReleaseNotesFile)) {
        $resolvedReleaseNotes = $ReleaseNotesFile
    } else {
        $resolvedReleaseNotes = Join-Path -Path $resolvedRoot -ChildPath $ReleaseNotesFile
    }
    if (-not (Test-Path -LiteralPath $resolvedReleaseNotes -PathType Leaf)) {
        New-Item -ItemType File -Path $resolvedReleaseNotes -Force | Out-Null
    }
}

try {
    $displayInfo = $DisplayInformationJSON | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "DisplayInformationJSON was not valid JSON: $($_.Exception.Message)"
}

$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($resolvedVipb)

$root = $xml.SelectSingleNode('/VI_Package_Builder_Settings')
if (-not $root) {
    throw "VIPB file '$resolvedVipb' does not contain VI_Package_Builder_Settings as the root element."
}

$root.SetAttribute('Modified_Date', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$root.SetAttribute('ID', ([guid]::NewGuid().ToString('N')))

$versionString = '{0}.{1}.{2}.{3}' -f $Major, $Minor, $Patch, $Build
Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Library_Version' -Value $versionString

$lvNumericMajor = $MinimumSupportedLVVersion - 2000
$packageLvVersion = '{0}.{1} ({2}-bit)' -f $lvNumericMajor, $LabVIEWMinorRevision, $SupportedBitness
Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Package_LabVIEW_Version' -Value $packageLvVersion

if ($displayInfo.'Company Name') {
    $company = $displayInfo.'Company Name'
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Company_Name' -Value ($company.ToUpperInvariant())
}

if ($displayInfo.'Product Name') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Product_Name' -Value $displayInfo.'Product Name'
}

if ($displayInfo.'Product Description Summary') {
    $summary = $displayInfo.'Product Description Summary'
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Library_Summary' -Value $summary
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/One_Line_Description_Summary' -Value $summary
}

if ($displayInfo.'Product Description') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/Description' -Value $displayInfo.'Product Description'
}

if ($displayInfo.'Release Notes - Change Log') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/Release_Notes' -Value $displayInfo.'Release Notes - Change Log'
}

if ($displayInfo.'Product Homepage (URL)') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/URL' -Value $displayInfo.'Product Homepage (URL)'
}

if ($displayInfo.'Author Name (Person or Company)') {
    $author = $displayInfo.'Author Name (Person or Company)'
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/Packager' -Value ($author.ToUpperInvariant())
}

if ($displayInfo.'Legal Copyright') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/Description/Copyright' -Value $displayInfo.'Legal Copyright'
}

if ($displayInfo.'License Agreement Name') {
    Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Library_General_Settings/Library_License' -Value $displayInfo.'License Agreement Name'
}

$vipcName = ([System.IO.Path]::GetFileNameWithoutExtension($resolvedVipb)) + '.vipc'
Set-VipbNodeValue -Document $xml -XPath '/VI_Package_Builder_Settings/Advanced_Settings/VI_Package_Configuration_File' -Value $vipcName

$xml.Save($resolvedVipb)
Write-Host "VIPB display information updated: $resolvedVipb"
