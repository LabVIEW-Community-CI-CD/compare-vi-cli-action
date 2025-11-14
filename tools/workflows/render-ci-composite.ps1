#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$RenderVendor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templatePath = Join-Path $PSScriptRoot 'templates/ci-composite.yml.tmpl'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
  throw "Template not found at '$templatePath'."
}
$templateText = Get-Content -LiteralPath $templatePath -Raw

function Invoke-Template {
  param(
    [string]$Template,
    [hashtable]$Context
  )

  $ifPattern = '\{\{#if\s+([a-zA-Z0-9_]+)\}\}([\s\S]*?)\{\{\/if\}\}'
  while ($Template -match $ifPattern) {
    $Template = [regex]::Replace(
      $Template,
      $ifPattern,
      {
        param($match)
        $varName = $match.Groups[1].Value
        $body = $match.Groups[2].Value
        $isTrue = $false
        if ($Context.ContainsKey($varName)) {
          $value = $Context[$varName]
          if ($value -is [bool]) {
            $isTrue = $value
          } elseif ($null -ne $value) {
            $isTrue = [bool]$value
          }
        }
        if ($isTrue) {
          return Invoke-Template -Template $body -Context $Context
        }
        return ''
      },
      'Singleline'
    )
  }

  $Template = [regex]::Replace(
    $Template,
    '\{\{([a-zA-Z0-9_]+)\}\}',
    {
      param($match)
      $name = $match.Groups[1].Value
      if ($Context.ContainsKey($name)) {
        return [string]$Context[$name]
      }
      return ''
    })

  return $Template
}

$rootContext = @{
  root                      = $true
  vendor                    = $false
  applyDepsRunsOn           = '[self-hosted, Windows, X64]'
  enableDevModeRunsOn       = '[self-hosted, Windows, X64]'
  enableDevModeIf           = '${{ needs.apply-deps.result == ''success'' || needs.apply-deps.result == ''skipped'' }}'
  versionRunsOn             = '[self-hosted, Windows, X64]'
  missingInProjectRunsOn    = '[self-hosted, Windows, X64]'
  testRunsOn                = '[self-hosted, Windows, X64]'
  iconEditorProjectFile     = 'vendor/icon-editor/lv_icon_editor.lvproj'
  buildPplNeeds             = '[test, version, enable-dev-mode]'
  buildPplRunsOn            = '[self-hosted, Windows, X64]'
  iconEditorRelativePath    = '${{ github.workspace }}/vendor/icon-editor'
  lvlibpCurrentPath         = '${{ github.workspace }}/vendor/icon-editor/resource/plugins/lv_icon.lvlibp'
  lvlibpNewPath             = '${{ github.workspace }}/vendor/icon-editor/resource/plugins/lv_icon_${{ matrix.suffix }}.lvlibp'
  lvlibpArtifactPath        = 'vendor/icon-editor/resource/plugins/lv_icon_${{ matrix.suffix }}.lvlibp'
  buildViPackageNeeds       = '[apply-deps, build-ppl, version, enable-dev-mode]'
  buildViPackageRunsOn      = '[self-hosted, Windows, X64]'
  disableDevModeRunsOn      = '[self-hosted, Windows, X64]'
}

$rootOutput = Invoke-Template -Template $templateText -Context $rootContext
$rootOutput = [regex]::Replace($rootOutput, "(\r?\n){3,}", "`n`n")
Set-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-composite.yml') -Value $rootOutput -Encoding utf8

if (-not $PSBoundParameters.ContainsKey('RenderVendor')) {
  $RenderVendor = $true
}

if ($RenderVendor) {
  $vendorContext = @{
    root                      = $false
    vendor                    = $true
    applyDepsRunsOn           = 'self-hosted-windows-lv'
    enableDevModeRunsOn       = 'self-hosted-windows-lv'
    enableDevModeIf           = '${{ needs.changes.result == ''success'' && (needs.apply-deps.result == ''success'' || needs.apply-deps.result == ''skipped'') }}'
    versionRunsOn             = 'self-hosted-windows-lv'
    missingInProjectRunsOn    = 'self-hosted-windows-lv'
    testRunsOn                = '${{ matrix.os == ''windows'' && ''self-hosted-windows-lv'' || ''self-hosted-linux-lv'' }}'
    iconEditorProjectFile     = 'lv_icon_editor.lvproj'
    buildPplNeeds             = '[test, version]'
    buildPplRunsOn            = 'self-hosted-windows-lv'
    iconEditorRelativePath    = '${{ github.workspace }}'
    lvlibpCurrentPath         = '${{ github.workspace }}/resource/plugins/lv_icon.lvlibp'
    lvlibpNewPath             = '${{ github.workspace }}/resource/plugins/lv_icon_${{ matrix.suffix }}.lvlibp'
    lvlibpArtifactPath        = 'resource/plugins/lv_icon_${{ matrix.suffix }}.lvlibp'
    buildViPackageNeeds       = '[build-ppl, version]'
    buildViPackageRunsOn      = 'self-hosted-windows-lv'
    disableDevModeRunsOn      = 'self-hosted-windows-lv'
  }

  $vendorOutput = Invoke-Template -Template $templateText -Context $vendorContext
  $vendorOutput = [regex]::Replace($vendorOutput, "(\r?\n){3,}", "`n`n")
  Set-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'vendor' 'icon-editor' '.github' 'workflows' 'ci-composite.yml') -Value $vendorOutput -Encoding utf8
}
