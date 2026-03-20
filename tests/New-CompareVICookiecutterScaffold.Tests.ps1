Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-CompareVICookiecutterScaffold.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ScaffoldScript = Join-Path $script:RepoRoot 'tools' 'New-CompareVICookiecutterScaffold.ps1'
    if (-not (Test-Path -LiteralPath $script:ScaffoldScript -PathType Leaf)) {
      throw "New-CompareVICookiecutterScaffold.ps1 not found at $script:ScaffoldScript"
    }
  }

  It 'lists the available cookiecutter templates' {
    $output = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript -ListTemplates 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $templates = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -Depth 10
    @($templates.id) | Should -Contain 'scenario-pack'
    @($templates.id) | Should -Contain 'corpus-seed'
  }

  It 'validates the checked-in cookiecutter catalog against its schema' {
    $catalogPath = Join-Path $script:RepoRoot 'tools' 'policy' 'comparevi-cookiecutter-templates.json'
    $schemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'comparevi-cookiecutter-template-catalog-v1.schema.json'
    $runner = Join-Path $script:RepoRoot 'tools' 'npm' 'run-script.mjs'

    $output = & node $runner 'schema:validate' '--' '--schema' $schemaPath '--data' $catalogPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  }

  It 'scaffolds a scenario-pack and writes a receipt plus replay file' {
    $contextPath = Join-Path $TestDrive 'scenario-pack.context.json'
    @"
{
  "pack_slug": "generated-review-pack",
  "pack_description": "Generated test pack",
  "plane_applicability_csv": "linux-proof,windows-mirror-proof"
}
"@ | Set-Content -LiteralPath $contextPath -Encoding utf8

    $outputRoot = Join-Path $TestDrive 'scenario-pack-output'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -TemplateId scenario-pack `
      -ContextPath $contextPath `
      -OutputRoot $outputRoot `
      -NoInput 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $receipt = (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi-cookiecutter-scaffold@v1'
    $receipt.templateId | Should -Be 'scenario-pack'
    $receipt.replayFileExists | Should -BeTrue
    $receipt.generatedFiles | Should -Contain 'scenario-pack.json'
    $receipt.generatedFiles | Should -Contain 'docs/generated-review-pack.md'
    $receipt.generatedFiles | Should -Contain 'tests/generated-review-pack.Tests.ps1'

    $receiptPath = Join-Path $outputRoot 'generated-review-pack' 'comparevi-cookiecutter-scaffold.json'
    $receiptPath | Should -Exist
    $replayPath = Join-Path $outputRoot 'generated-review-pack' 'cookiecutter-replay.json'
    $replayPath | Should -Exist

    $scenarioPackPath = Join-Path $outputRoot 'generated-review-pack' 'scenario-pack.json'
    $scenarioPackPath | Should -Exist
    $scenarioPack = Get-Content -LiteralPath $scenarioPackPath -Raw | ConvertFrom-Json -Depth 20
    $scenarioPack.activeScenarioPackId | Should -Be 'generated-review-pack-v1'
    @($scenarioPack.scenarioPacks[0].planeApplicability) | Should -Contain 'linux-proof'
    @($scenarioPack.scenarioPacks[0].planeApplicability) | Should -Contain 'windows-mirror-proof'
  }

  It 'scaffolds a corpus seed with change-kind-aware print rendering metadata' {
    $contextPath = Join-Path $TestDrive 'corpus-seed.context.json'
    @"
{
  "target_slug": "generated-added-seed",
  "target_label": "Generated Added Seed",
  "repo_slug": "aphill93/linuxContainerDemo",
  "repo_url": "https://github.com/aphill93/linuxContainerDemo",
  "license_spdx": "",
  "target_path": "Test-VIs/NewThing.vi",
  "change_kind": "added",
  "pinned_commit": "0f31bc7a0c26624742101c925f58320dffece847",
  "public_pr_url": "https://github.com/aphill93/linuxContainerDemo/pull/7",
  "public_workflow_run_url": "https://github.com/aphill93/linuxContainerDemo/actions/runs/22909143209"
}
"@ | Set-Content -LiteralPath $contextPath -Encoding utf8

    $outputRoot = Join-Path $TestDrive 'corpus-seed-output'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -TemplateId corpus-seed `
      -ContextPath $contextPath `
      -OutputRoot $outputRoot `
      -NoInput 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $receipt = (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
    $receipt.templateId | Should -Be 'corpus-seed'
    $receipt.generatedFiles | Should -Contain 'sample-target.json'

    $targetPath = Join-Path $outputRoot 'generated-added-seed' 'sample-target.json'
    $targetPath | Should -Exist
    $targetJson = Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json -Depth 30
    $target = $targetJson.targets[0]
    $target.source.changeKind | Should -Be 'added'
    $target.renderStrategy.certificationSurface | Should -Be 'print-single-file'
    $target.renderStrategy.operation | Should -Be 'PrintToSingleFileHtml'
    $target.operationPayload.mode | Should -Be 'additional-operation-directory'
  }

  It 'refuses repo-local output roots outside the dedicated scaffold subtree' {
    $contextPath = Join-Path $TestDrive 'scenario-pack.context.json'
    @"
{
  "pack_slug": "blocked-output-pack"
}
"@ | Set-Content -LiteralPath $contextPath -Encoding utf8

    $outputRoot = Join-Path $script:RepoRoot 'tools' 'tmp-cookiecutter-output'
    try {
      $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
        -TemplateId scenario-pack `
        -ContextPath $contextPath `
        -OutputRoot $outputRoot `
        -NoInput 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'outside'
    } finally {
      if (Test-Path -LiteralPath $outputRoot) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
      }
    }
  }
}
