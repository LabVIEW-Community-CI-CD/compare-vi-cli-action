<!-- markdownlint-disable-next-line MD041 -->
# External Consumption Template (Icon Editor)

Use this workflow job in an external repository (for example
`svelderrainruiz/labview-icon-editor`) to consume a pinned CLI release.

## Goals

- pin to a known release tag
- verify archive integrity before execution
- run lane command in non-interactive/headless mode
- upload lane artifacts for review

## GitHub Actions job template

```yaml
name: CompareVI CLI Consumer

on:
  workflow_dispatch:
    inputs:
      cli_tag:
        description: comparevi-cli release tag
        required: true
        default: v1.0.2

jobs:
  comparevi-cli:
    runs-on: windows-latest
    permissions:
      contents: read
    env:
      CLI_REPO: svelderrainruiz/compare-vi-cli-action
      CLI_TAG: ${{ inputs.cli_tag }}
      CLI_ARCHIVE: comparevi-cli-v0.1.0-win-x64-selfcontained.zip
      RESULTS_DIR: tests/results/comparevi-cli
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Prepare output directories
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Path .tmp/comparevi-cli -Force | Out-Null
          New-Item -ItemType Directory -Path $env:RESULTS_DIR -Force | Out-Null

      - name: Download pinned CLI + checksums
        shell: pwsh
        run: |
          gh release download $env:CLI_TAG --repo $env:CLI_REPO --pattern $env:CLI_ARCHIVE --pattern SHA256SUMS.txt --dir .tmp/comparevi-cli --clobber

      - name: Verify checksum
        shell: pwsh
        run: |
          $sumFile = Join-Path '.tmp/comparevi-cli' 'SHA256SUMS.txt'
          $archive = Join-Path '.tmp/comparevi-cli' $env:CLI_ARCHIVE
          $expected = Select-String -Path $sumFile -Pattern ([regex]::Escape($env:CLI_ARCHIVE)) | ForEach-Object {
            ($_ -split '\\s+')[0]
          } | Select-Object -First 1
          if (-not $expected) { throw "Checksum entry not found for $($env:CLI_ARCHIVE)" }
          $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($actual -ne $expected.ToLowerInvariant()) {
            throw "Checksum mismatch. expected=$expected actual=$actual"
          }

      - name: Extract CLI
        shell: pwsh
        run: |
          Expand-Archive -LiteralPath (Join-Path '.tmp/comparevi-cli' $env:CLI_ARCHIVE) -DestinationPath .tmp/comparevi-cli/tool -Force

      - name: Create lane input
        shell: pwsh
        run: |
          $input = @{
            fixture = 'icon-editor'
            baseVi = 'fixtures/vi-stage/bd-cosmetic/Base.vi'
            headVi = 'fixtures/vi-stage/bd-cosmetic/Head.vi'
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            note = 'External repo pinned CLI smoke run'
          }
          $input | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $env:RESULTS_DIR 'input.json') -Encoding utf8

      - name: Run compare single lane
        shell: pwsh
        run: |
          $cli = Join-Path '.tmp/comparevi-cli/tool' 'comparevi-cli.exe'
          $inputPath = Join-Path $env:RESULTS_DIR 'input.json'
          & $cli compare single --input $inputPath --out-dir $env:RESULTS_DIR --headless --non-interactive

      - name: Upload artifacts
        uses: actions/upload-artifact@v5
        with:
          name: comparevi-cli-consumer-${{ inputs.cli_tag }}
          path: ${{ env.RESULTS_DIR }}/**
          if-no-files-found: error
```

## Notes

- Keep the CLI tag pinned. Update only after validating in a non-blocking lane.
- Verify both checksum and expected payload fields before promoting changes.
- Start with one lane (`compare single`) and expand to additional lanes once
  the consumer pipeline is stable.
