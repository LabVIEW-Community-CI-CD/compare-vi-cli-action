Describe 'VI Binary Handling Invariants' -Tag 'Unit' {
  It 'declares *.vi as binary in .gitattributes' {
    $attrPath = Join-Path $PSScriptRoot '..' '.gitattributes'
    Test-Path $attrPath | Should -BeTrue
    $content = Get-Content $attrPath -Raw
    ($content -match '(?m)^\*\.vi\s+binary\s*$') | Should -BeTrue
  }

  It 'does not attempt textual reads of .vi files in scripts (grep heuristic)' {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $psFiles = Get-ChildItem $root -Recurse -Include *.ps1,*.psm1 | Where-Object { 
      $_.FullName -notmatch '[/\\]tests[/\\]' -and $_.FullName -notmatch '[/\\]tools[/\\]' 
    }
    $badPatterns = @(
      'Get-Content\s+[^\n]*\.vi',
      'ReadAllText\(',
      'StreamReader'
    )
    $violations = @()
    foreach ($f in $psFiles) {
      $text = Get-Content $f.FullName -Raw
      foreach ($pat in $badPatterns) {
        if ($text -match $pat) {
          $violations += [pscustomobject]@{ File=$f.FullName; Pattern=$pat }
        }
      }
    }
    if ($violations.Count -gt 0) {
      $violations | Format-Table | Out-String | Write-Host
    }
    $violations.Count | Should -Be 0
  }
}
