# ArgTokenization Module
# Provides shared constants and functions for LVCompare argument tokenization
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Canonical tokenization regex pattern
# Matches: double-quoted strings, single-quoted strings, or non-comma/non-whitespace sequences
# This pattern is intentionally simple and must not be changed without comprehensive test coverage
$script:LVCompareArgTokenPattern = '"[^\"]+"|''[^'']+''|[^,\s]+'

function Get-LVCompareArgTokenPattern {
  <#
  .SYNOPSIS
    Returns the canonical regex pattern for tokenizing LVCompare arguments.
  .DESCRIPTION
    The pattern matches:
    - Double-quoted strings (including quotes): "text"
    - Single-quoted strings (including quotes): 'text'
    - Non-comma, non-whitespace sequences: token
    
    This pattern is used consistently across CompareVI.ps1, CompareLoop.psm1, 
    Render-CompareReport.ps1, and other scripts that parse lvCompareArgs.
    
    The pattern is intentionally simple. Changes require comprehensive test coverage
    for edge cases (nested quotes, escaped quotes, etc.).
  .OUTPUTS
    String containing the regex pattern
  .EXAMPLE
    $pattern = Get-LVCompareArgTokenPattern
    $tokens = [regex]::Matches($argString, $pattern)
  #>
  return $script:LVCompareArgTokenPattern
}

Export-ModuleMember -Function Get-LVCompareArgTokenPattern
