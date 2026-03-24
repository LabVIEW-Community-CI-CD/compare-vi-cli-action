<!-- markdownlint-disable-next-line MD041 -->
# Integration Tests Guide

Prerequisites and tips for running the Pester integration suite.

## Requirements

- LabVIEW 2025 Q3 with LVCompare at the canonical path.
- Environment variables:
  - `LV_BASE_VI`, `LV_HEAD_VI` – distinct fixtures.
  - Optional: `LV_PREVIEW=1` (preview args only), `CEILING_MS` (timing thresholds).
- Recommended noise filters: `-noattr -nofp -nofppos -nobd -nobdcosm`.

## Running locally

```powershell
$env:LV_BASE_VI = 'C:\VIs\VI1.vi'
$env:LV_HEAD_VI = 'C:\VIs\VI2.vi'
./Invoke-PesterTests.ps1 -IntegrationMode include
```

Artifacts appear under `tests/results/` (JSON summary, results XML, dispatcher log).

## GitHub workflows

- `Pester (self-hosted, real CLI)` – triggered by label `test-integration` or manual dispatch.
- `ci-orchestrated.yml` – use `strategy=single` (default) or `matrix` via input/variable.

## Checklist before running

- Runner online with labels `[self-hosted, Windows, X64, comparevi, capability-ingress]`.
- VI fixtures available and accessible by runner service.
- LVCompare not blocked by antivirus / pending updates.

## Troubleshooting

| Symptom | Suggestion |
| ------- | ---------- |
| `LVCompare.exe not found` | Reinstall Compare feature, verify canonical path |
| VIs missing | Fix `LV_BASE_VI` / `LV_HEAD_VI`, check permissions |
| Diff unexpected | Inspect `compare-exec.json`, re-run with watcher or preview mode |

## Related docs

- [`docs/SELFHOSTED_CI_SETUP.md`](./SELFHOSTED_CI_SETUP.md)
- [`docs/E2E_TESTING_GUIDE.md`](./E2E_TESTING_GUIDE.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
