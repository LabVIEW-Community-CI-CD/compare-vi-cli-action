Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe "Warmup-LabVIEWRuntime helpers" -Tag "Unit" {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
    $scriptPath = Join-Path $repoRoot "tools" "Warmup-LabVIEWRuntime.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      throw "Warmup-LabVIEWRuntime.ps1 not found at $scriptPath"
    }
    . $scriptPath
  }

  Context "Get-WarmupLabVIEWProcessState" {
    It "classifies matching and non-matching LabVIEW processes" {
      $expectedPath = Normalize-WarmupLabVIEWPath -Path "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"
      Mock -CommandName Get-Process -MockWith {
        @(
          [pscustomobject]@{ Id = 1001; Path = "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe" },
          [pscustomobject]@{ Id = 2002; Path = "D:\LabVIEW\LabVIEW.exe" }
        )
      }

      $state = Get-WarmupLabVIEWProcessState -ExpectedPath $expectedPath
      $state.Matching.Count | Should -Be 1
      $state.NonMatching.Count | Should -Be 1
      ($state.Matching[0].Id) | Should -Be 1001
      ($state.NonMatching[0].Id) | Should -Be 2002
    }

    It "treats processes without resolved paths as non-matching" {
      $expectedPath = Normalize-WarmupLabVIEWPath -Path "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"
      Mock -CommandName Get-Process -MockWith {
        @(
          [pscustomobject]@{ Id = 3003 },
          [pscustomobject]@{ Id = 4004; Path = $null }
        )
      }

      $state = Get-WarmupLabVIEWProcessState -ExpectedPath $expectedPath
      $state.Matching.Count | Should -Be 0
      $state.NonMatching.Count | Should -Be 2
      ($state.NonMatching | ForEach-Object { $_.Path }) | Should -Be @( $null, $null )
    }
  }

  Context "Normalize-WarmupLabVIEWPath" {
    It "normalizes LabVIEW paths via GetFullPath" {
      $raw = "C:\Program Files\National Instruments\..\National Instruments\LabVIEW 2025\LabVIEW.exe"
      $normalized = Normalize-WarmupLabVIEWPath -Path $raw
      $normalized | Should -Be "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"
    }
  }
}
