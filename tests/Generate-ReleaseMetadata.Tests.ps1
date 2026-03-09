Describe 'Release metadata generators' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SbomScript = Join-Path $script:RepoRoot 'tools' 'Generate-ReleaseSbom.ps1'
    $script:ProvenanceScript = Join-Path $script:RepoRoot 'tools' 'Generate-ReleaseProvenance.ps1'
  }

  It 'writes SBOM JSON without a UTF-8 BOM' {
    $artifactsRoot = Join-Path $TestDrive 'artifacts'
    $sbomPath = Join-Path $TestDrive 'sbom.spdx.json'
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'comparevi-cli-v1-win-x64-selfcontained.zip') -Value 'archive' -Encoding ascii

    & $script:SbomScript -ArtifactsRoot $artifactsRoot -OutputPath $sbomPath

    Test-Path -LiteralPath $sbomPath | Should -BeTrue
    $bytes = [System.IO.File]::ReadAllBytes($sbomPath)
    ([System.BitConverter]::ToString($bytes[0..2])) | Should -Not -Be 'EF-BB-BF'

    $payload = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
    $payload.spdxVersion | Should -Be 'SPDX-2.3'
  }

  It 'writes provenance JSON without a UTF-8 BOM' {
    $artifactsRoot = Join-Path $TestDrive 'artifacts-provenance'
    $provenancePath = Join-Path $TestDrive 'provenance.json'
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'comparevi-cli-v1-win-x64-selfcontained.zip') -Value 'archive' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'SHA256SUMS.txt') -Value 'checksums' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'sbom.spdx.json') -Value '{"spdxVersion":"SPDX-2.3"}' -Encoding ascii

    $originalEnv = @{
      GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
      GITHUB_WORKFLOW   = $env:GITHUB_WORKFLOW
      GITHUB_EVENT_NAME = $env:GITHUB_EVENT_NAME
      GITHUB_RUN_ID     = $env:GITHUB_RUN_ID
      GITHUB_RUN_ATTEMPT = $env:GITHUB_RUN_ATTEMPT
      GITHUB_REF        = $env:GITHUB_REF
      GITHUB_REF_NAME   = $env:GITHUB_REF_NAME
      GITHUB_HEAD_REF   = $env:GITHUB_HEAD_REF
      GITHUB_BASE_REF   = $env:GITHUB_BASE_REF
      GITHUB_SHA        = $env:GITHUB_SHA
    }

    try {
      $env:GITHUB_REPOSITORY = 'owner/repo'
      $env:GITHUB_WORKFLOW = 'Release on tag'
      $env:GITHUB_EVENT_NAME = 'push'
      $env:GITHUB_RUN_ID = '123'
      $env:GITHUB_RUN_ATTEMPT = '1'
      $env:GITHUB_REF = 'refs/tags/v1.2.3'
      $env:GITHUB_REF_NAME = 'v1.2.3'
      $env:GITHUB_HEAD_REF = ''
      $env:GITHUB_BASE_REF = ''
      $env:GITHUB_SHA = 'abc123'

      & $script:ProvenanceScript -ArtifactsRoot $artifactsRoot -OutputPath $provenancePath
    } finally {
      foreach ($entry in $originalEnv.GetEnumerator()) {
        if ($null -ne $entry.Value) {
          Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value
        } else {
          Remove-Item -Path ("Env:{0}" -f $entry.Key) -ErrorAction SilentlyContinue
        }
      }
    }

    Test-Path -LiteralPath $provenancePath | Should -BeTrue
    $bytes = [System.IO.File]::ReadAllBytes($provenancePath)
    ([System.BitConverter]::ToString($bytes[0..2])) | Should -Not -Be 'EF-BB-BF'

    $payload = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
    $payload.schema | Should -Be 'run-provenance/v1'
    $payload.repository | Should -Be 'owner/repo'
  }
}
