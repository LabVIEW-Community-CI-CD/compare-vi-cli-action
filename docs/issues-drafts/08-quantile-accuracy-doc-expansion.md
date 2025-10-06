# Expand quantile accuracy & tuning docs

**Labels:** docs, performance

## Summary

Provide empirical guidance for streaming/hybrid percentile accuracy, capacity sizing, and reconciliation frequency tuning.

## Motivation

- Users need concrete heuristics to choose `StreamCapacity`, `HybridExactThreshold`, and `ReconcileEvery`.
- Reduces guesswork and support questions about p99 instability.

## Content Plan

- Table comparing Exact vs StreamingReservoir vs Hybrid on synthetic latency distributions (unimodal, bimodal, heavy-tail) with relative error columns.
- Guidelines: when to increase capacity vs enable reconciliation.
- Example scenarios with recommended settings (short soak, long soak, bursty load).

## Acceptance Criteria

- [ ] New README subsection or dedicated doc linked from strategies section.
- [ ] Includes at least 3 comparative tables with relative error (%).
- [ ] Mentions trade-off: memory vs stability vs warm-up cost.
- [ ] Markdown lint passes.

## Risks

- Overfitting guidance to a narrow synthetic dataset (mitigate by stating assumptions & encouraging validation).
