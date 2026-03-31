# Pester Service Model Release Procedure

## Purpose

Define how the Pester service-model subsystem moves from a retained fork design
dossier to an upstream-mounted proof baseline and, eventually, a promotable
release surface.

## Procedure

1. Review the retained fork promotion dossier and confirm that it still matches
   the intended upstream slice.
2. Mount only the intended hosted workflow and packet changes onto the upstream
   integration rail.
3. Run `.github/workflows/pester-service-model-quality.yml`.
4. Run `.github/workflows/pester-service-model-release-evidence.yml`.
5. Compare the additive service-model proof against the monolithic gate.
6. Only after positive proof, advance the next minimal promotion slice on
   `#2069`.
7. Retain the upstream release-evidence bundle alongside the referenced fork
   dossier before proposing any wider service-model promotion.

## Baseline Rule

- Fork packet baselines are local design baselines.
- Upstream integration mounts are proving baselines.
- Promotion to release truth requires explicit comparative proof.

## Status Accounting

- Status is recorded in the issues and the retained release-evidence outputs.
- The upstream baseline must retain both the requirements packet and the hosted
  release-evidence bundle used to justify the move.
- The retained packet release-evidence bundle plus the referenced fork dossier
  is the minimum promotion handoff.
