param(
  [Parameter()]
  $Fixture
)

if ($null -ne $Fixture -and $Fixture -isnot [ScriptBlock]) {
  $Fixture = { $Fixture }
}

$script:MiniTestsFixture = $Fixture

Describe "Mini" -Tag Slow {
  It "runs a sanity check" {
    1 | Should -Be 1
  }
}
