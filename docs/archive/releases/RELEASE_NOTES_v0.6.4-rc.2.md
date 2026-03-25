<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.2

Highlights

- The next RC publishes the producer-owned Docker contract in
  `CompareVI.Tools`.
  - `comparevi-tools-release.json` now carries
    `consumerContract.capabilities.dockerProfile`.
  - The same payload now exposes the producer-owned
    `consumerContract.dockerImageContract` source needed by downstream Docker
    distributors.
- `v0.6.4-rc.2` is the honest follow-up to the published `v0.6.4-rc.1` bundle.
  - `v0.6.4-rc.1` is now authoritative for the producer-native `vi-history`
    contract.
  - It still predates commit `5969b9114cafdab989dadb70c5bec188b07a3996`, so its
    published bundle does not include the new docker-profile capability.
- The template Docker-profile rail stays dependency-driven.
  - `LabviewGitHubCiTemplate#20` remains blocked until this RC is published and
    the producer bundle proves the Docker contract authoritatively.
  - The template should consume the published producer contract, not invent a
    template-local Docker image convention.

Upgrade Notes

- This is a release candidate. The final `v0.6.4` release still depends on RC
  validation, authoritative bundle publication, and the template follow-up
  consuming the published contract cleanly.
- The replay-routing repair from `#1942` stays part of the release story, but it
  is no longer the active publication blocker. The remaining release objective
  is publishing the newer producer contract on the next RC identity.

Validation Checklist

- [x] `node tools/npm/run-script.mjs release:branch -- 0.6.4-rc.2`
- [ ] Live hosted RC validation on `release/v0.6.4-rc.2`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.2`
- [ ] `node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel rc --version 0.6.4-rc.2`
- [ ] `node tools/npm/run-script.mjs priority:release:published:bundle`
- [ ] Published `CompareVI.Tools-v0.6.4-rc.2.zip` proves both:
  - producer-native `vi-history`
  - producer-owned `dockerProfile`
