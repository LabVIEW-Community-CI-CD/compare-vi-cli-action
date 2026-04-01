import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowsRoot = path.join(repoRoot, '.github', 'workflows');

function collectPwshContinuationViolations() {
  const violations = [];

  for (const entry of readdirSync(workflowsRoot)) {
    if (!entry.endsWith('.yml')) {
      continue;
    }

    const workflowPath = path.join(workflowsRoot, entry);
    const workflow = yaml.load(readFileSync(workflowPath, 'utf8'));
    const jobs = workflow?.jobs ?? {};

    for (const [jobId, job] of Object.entries(jobs)) {
      const steps = Array.isArray(job?.steps) ? job.steps : [];
      steps.forEach((step, index) => {
        if (!step || step.shell !== 'pwsh' || typeof step.run !== 'string') {
          return;
        }

        step.run.split(/\r?\n/).forEach((line, lineIndex) => {
          if (line.trimEnd().endsWith('\\')) {
            violations.push({
              workflow: entry,
              jobId,
              stepName: step.name ?? `step-${index + 1}`,
              line: lineIndex + 1,
              source: line.trim()
            });
          }
        });
      });
    }
  }

  return violations;
}

test('pwsh workflow steps never rely on bash-style line continuations', () => {
  const violations = collectPwshContinuationViolations();
  assert.deepEqual(violations, []);
});

test('publish-tools-image workflow resolves context through the dedicated helper', () => {
  const workflowPath = path.join(workflowsRoot, 'publish-tools-image.yml');
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /node tools\/priority\/resolve-tools-image-publish-context\.mjs/);
  assert.match(workflow, /steps\.context\.outputs\.stable_family_version/);
  assert.match(workflow, /steps\.context\.outputs\.is_tools_tag/);
  assert.match(workflow, /docker pull "\$image"/);
  assert.match(workflow, /cookiecutter --version/);
  assert.match(workflow, /COOKIECUTTER_VERSION:\s*'2\.7\.1'/);
});

test('publish-tools-image Dockerfile pins cookiecutter 2.7.1 for the conveyor surface', () => {
  const dockerfilePath = path.join(repoRoot, 'tools', 'docker', 'Dockerfile.tools');
  const dockerfile = readFileSync(dockerfilePath, 'utf8');

  assert.match(dockerfile, /cookiecutter==2\.7\.1/);
});

test('release workflow explicitly dispatches publish-tools-image with actions write permission', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(workflowRaw);
  const releaseJob = workflow?.jobs?.release;
  const dispatchStep = releaseJob?.steps?.find((step) => step?.name === 'Dispatch Publish Tools Image workflow');

  assert.equal(releaseJob?.permissions?.actions, 'write');
  assert.ok(dispatchStep, 'release workflow should dispatch publish-tools-image explicitly');
  assert.equal(dispatchStep.if, "env.RELEASE_PUBLICATION_MODE == 'publish'");
  assert.equal(dispatchStep.uses, 'actions/github-script@v8');
  assert.match(dispatchStep.with.script, /workflow_id:\s*'publish-tools-image\.yml'/);
  assert.match(dispatchStep.with.script, /ref:\s*'develop'/);
  assert.match(
    dispatchStep.with.script,
    /const releaseVersion = '\$\{\{\s*steps\.comparevi_tools\.outputs\.comparevi_tools_release_version\s*\}\}';/
  );
  assert.match(dispatchStep.with.script, /const releaseChannel = releaseVersion\.includes\('-rc\.'\) \? 'rc' : 'stable';/);
});

test('release workflow remains tag-triggered and also supports workflow_dispatch replay for repaired tags', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(workflowRaw);

  assert.deepEqual(workflow?.on?.push?.tags, ['v*']);
  assert.ok(Object.prototype.hasOwnProperty.call(workflow?.on ?? {}, 'workflow_dispatch'));
  assert.equal(workflow?.on?.workflow_dispatch?.inputs?.release_tag?.required, true);
  assert.equal(workflow?.on?.workflow_dispatch?.inputs?.release_tag?.type, 'string');
  assert.equal(workflow?.on?.workflow_dispatch?.inputs?.publication_mode?.default, 'publish');
  assert.equal(workflow?.on?.workflow_dispatch?.inputs?.publication_mode?.type, 'choice');
  assert.deepEqual(workflow?.on?.workflow_dispatch?.inputs?.publication_mode?.options, ['publish', 'verify-existing-release']);
  assert.match(workflowRaw, /name: Resolve release target tag/);
  assert.match(workflowRaw, /tag='\$\{\{\s*inputs\.release_tag\s*\}\}'/);
  assert.match(workflowRaw, /name: Resolve publication mode/);
  assert.match(workflowRaw, /mode='\$\{\{\s*inputs\.publication_mode\s*\}\}'/);
  assert.match(workflowRaw, /target_tag:\s*\$\{\{\s*steps\.release_target\.outputs\.tag\s*\}\}/);
  assert.match(workflowRaw, /publication_mode:\s*\$\{\{\s*steps\.publication_mode\.outputs\.mode\s*\}\}/);
  assert.match(workflowRaw, /ref:\s*\$\{\{\s*steps\.release_target\.outputs\.tag\s*\}\}/);
  assert.match(workflowRaw, /RELEASE_TAG:\s*\$\{\{\s*needs\.certification-matrix\.outputs\.target_tag\s*\}\}/);
  assert.match(workflowRaw, /RELEASE_PUBLICATION_MODE:\s*\$\{\{\s*needs\.certification-matrix\.outputs\.publication_mode\s*\}\}/);
  assert.match(workflowRaw, /tag_name:\s*\$\{\{\s*env\.RELEASE_TAG\s*\}\}/);
  assert.match(workflowRaw, /if:\s*env\.RELEASE_PUBLICATION_MODE == 'publish' && steps\.notes\.outputs\.fallback == 'false'/);
  assert.match(workflowRaw, /if:\s*env\.RELEASE_PUBLICATION_MODE == 'publish' && steps\.notes\.outputs\.fallback == 'true'/);
  assert.match(workflowRaw, /name: Record protected-tag-safe replay mode/);
  assert.match(workflowRaw, /if:\s*env\.RELEASE_PUBLICATION_MODE == 'verify-existing-release'/);
});

test('release workflow resolves downloaded artifacts through the shared helper before validation', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(workflowRaw);
  const validateSteps = workflow?.jobs?.['validate-cli-artifacts']?.steps ?? [];
  const checkoutIndex = validateSteps.findIndex((step) => step?.uses === 'actions/checkout@v5');
  const resolveIndex = validateSteps.findIndex((step) => step?.name === 'Resolve validation artifact paths');
  const writeScenarioIndex = validateSteps.findIndex((step) => step?.name === 'Write release-review scenario summary');
  const uploadScenarioIndex = validateSteps.findIndex((step) => step?.name === 'Upload release-review scenario summary');
  const enforceValidationIndex = validateSteps.findIndex((step) => step?.name === 'Enforce validation outcomes');
  const releaseContractJob = workflow?.jobs?.['release-contract'];
  const releaseContractSteps = releaseContractJob?.steps ?? [];
  const releaseSourceIndex = releaseContractSteps.findIndex((step) => step?.name === 'Resolve release source commit');
  const currentDevelopIndex = releaseContractSteps.findIndex((step) => step?.name === 'Resolve current develop head');
  const downstreamPolicyIndex = releaseContractSteps.findIndex((step) => step?.name === 'Decide downstream proving enforcement mode');
  const downstreamResolveIndex = releaseContractSteps.findIndex((step) => step?.name === 'Resolve downstream proving artifact selection');
  const buildScorecardIndex = releaseContractSteps.findIndex((step) => step?.name === 'Build release scorecard');

  assert.ok(checkoutIndex >= 0, 'validate-cli-artifacts should check out the repository before helper-backed steps');
  assert.ok(resolveIndex > checkoutIndex, 'validate-cli-artifacts should resolve artifact paths after checkout');
  assert.ok(writeScenarioIndex > resolveIndex, 'validate-cli-artifacts should emit scenario summaries after artifact resolution');
  assert.ok(uploadScenarioIndex > writeScenarioIndex, 'validate-cli-artifacts should upload scenario summaries after writing them');
  assert.ok(enforceValidationIndex > uploadScenarioIndex, 'validate-cli-artifacts should fail only after scenario artifacts upload');
  assert.ok(releaseSourceIndex >= 0, 'release-contract should resolve the expected release source commit');
  assert.ok(currentDevelopIndex > releaseSourceIndex, 'release-contract should resolve the current develop head after the release source is known');
  assert.ok(
    downstreamPolicyIndex > currentDevelopIndex,
    'release-contract should decide downstream proving enforcement after resolving the current develop head'
  );
  assert.ok(
    downstreamResolveIndex > downstreamPolicyIndex,
    'release-contract should resolve downstream proving artifacts after the enforcement mode is known'
  );
  assert.ok(buildScorecardIndex > downstreamResolveIndex, 'release-contract should build the release scorecard after downstream proving resolution');
  assert.match(workflowRaw, /name: Resolve validation artifact paths/);
  assert.match(workflowRaw, /Resolve-DownloadedArtifactPath\.ps1/);
  assert.match(workflowRaw, /steps\.artifact_paths\.outputs\.archive_path/);
  assert.match(workflowRaw, /steps\.artifact_paths\.outputs\.checksum_path/);
  assert.match(workflowRaw, /name: Write release-review scenario summary/);
  assert.match(workflowRaw, /tools\/release-review\/Write-ReleaseReviewScenarioSummary\.ps1/);
  assert.match(workflowRaw, /name: Upload release-review scenario summary/);
  assert.match(workflowRaw, /release-review-scenario-\$\{\{\s*matrix\.os\s*\}\}-\$\{\{\s*github\.run_id\s*\}\}/);
  assert.match(workflowRaw, /name: Resolve release-contract artifact paths/);
  assert.match(workflowRaw, /steps\.contract_artifacts\.outputs\.provenance_path/);
  assert.match(workflowRaw, /name: Download release-review scenario artifacts/);
  assert.match(workflowRaw, /merge-multiple:\s*true/);
  assert.match(workflowRaw, /name: Resolve release source commit/);
  assert.match(workflowRaw, /git fetch --force --tags origin "refs\/tags\/\$\{RELEASE_TAG\}:refs\/tags\/\$\{RELEASE_TAG\}"/);
  assert.match(workflowRaw, /git rev-parse "\$\{RELEASE_TAG\}\^\{commit\}"/);
  assert.match(workflowRaw, /name: Resolve current develop head/);
  assert.match(workflowRaw, /git fetch --force origin "refs\/heads\/develop:refs\/remotes\/origin\/develop"/);
  assert.match(workflowRaw, /git rev-parse "refs\/remotes\/origin\/develop\^\{commit\}"/);
  assert.match(workflowRaw, /name: Decide downstream proving enforcement mode/);
  assert.match(workflowRaw, /mode='advisory-replay'/);
  assert.match(workflowRaw, /if \[\[ "\$\{RELEASE_PUBLICATION_MODE\}" == 'publish' \]\]; then/);
  assert.match(workflowRaw, /if \[\[ "\$source_sha" == "\$develop_sha" \]\]; then/);
  assert.match(workflowRaw, /mode='required'/);
  assert.match(workflowRaw, /mode='deferred-release-source-not-current-develop'/);
  assert.match(workflowRaw, /## Downstream Proving Gate/);
  assert.match(workflowRaw, /RELEASE_PUBLICATION_MODE:\s*\$\{\{\s*needs\.certification-matrix\.outputs\.publication_mode\s*\}\}/);
  assert.match(workflowRaw, /name: Download supply-chain trust artifact/);
  assert.match(workflowRaw, /path:\s*tests\/results\/_agent/);
  assert.match(workflowRaw, /name: Resolve downstream proving artifact selection/);
  assert.match(workflowRaw, /resolve-downstream-proving-artifact\.mjs/);
  assert.match(workflowRaw, /--workflow downstream-promotion\.yml/);
  assert.match(workflowRaw, /--expected-source-sha "\$\{\{\s*steps\.release_source\.outputs\.source_sha\s*\}\}"/);
  assert.match(workflowRaw, /tests\/results\/_agent\/release\/downstream-proving-selection\.json/);
  assert.match(workflowRaw, /name: Validate downstream proving selection schema/);
  assert.match(workflowRaw, /docs\/schemas\/downstream-proving-selection-v1\.schema\.json/);
  assert.match(workflowRaw, /steps\.downstream_proving_artifacts\.outputs\.downstream_proving_scorecard_path/);
  assert.match(workflowRaw, /downstream_promotion_path="\$\{\{\s*steps\.downstream_proving_artifacts\.outputs\.downstream_proving_scorecard_path\s*\}\}"/);
  assert.match(workflowRaw, /downstream_proving_selection_path='tests\/results\/_agent\/release\/downstream-proving-selection\.json'/);
  assert.match(
    workflowRaw,
    /if \[\[ "\$\{\{\s*steps\.downstream_proving_policy\.outputs\.mode\s*\}\}" == 'required' \]\]; then/
  );
  assert.match(
    workflowRaw,
    /scorecard_args\+=\(\s*--downstream-proving-selection "\$\{downstream_proving_selection_path\}"\s*--require-downstream-proving\s*\)/ms
  );
  assert.match(workflowRaw, /if \[ -n "\$\{downstream_promotion_path\}" \]; then/);
  assert.match(workflowRaw, /scorecard_args\+=\(--downstream-promotion "\$\{downstream_promotion_path\}"\)/);
  assert.match(workflowRaw, /tools\/release-review\/Evaluate-ReleaseReviewPolicy\.ps1/);
  assert.match(workflowRaw, /tests\/results\/release-contract\/review-comment\.md/);
  assert.match(workflowRaw, /--candidate-workflow release\.yml/);
  assert.doesNotMatch(workflowRaw, /--downstream-promotion "\$\{\{\s*steps\.downstream_proving_artifacts\.outputs\.downstream_proving_scorecard_path\s*\}\}"/);
  assert.match(workflowRaw, /signed_tag_args=\(\)/);
  assert.match(workflowRaw, /scorecard_args=\(/);
  assert.match(workflowRaw, /signed_tag_args\+=\(--require-signed-tag\)/);
  assert.equal(releaseContractJob?.permissions?.actions, 'read');
  assert.equal(releaseContractJob?.if, "${{ always() && needs.release.result == 'success' }}");
  assert.match(workflowRaw, /Out-File -FilePath \$env:GITHUB_OUTPUT -Encoding utf8 -Append/);
  assert.doesNotMatch(workflowRaw, /Write-ReleaseReviewContractArtifacts\.ps1/);
  assert.doesNotMatch(workflowRaw, /downstream-onboarding-feedback\.yml\/runs\?branch=develop&status=success/);
  assert.doesNotMatch(workflowRaw, /download-run-artifact\.mjs/);
  assert.doesNotMatch(workflowRaw, /--artifact downstream-onboarding-feedback/);
  assert.doesNotMatch(workflowRaw, /ls -1 cli-dl\/comparevi-cli-v\$\{v\}-linux-x64-selfcontained\.tar\.gz/);
  assert.doesNotMatch(workflowRaw, /tarball=\"cli-dl\/comparevi-cli-v\$\{v\}-linux-x64-selfcontained\.tar\.gz\"/);
  assert.doesNotMatch(workflowRaw, /cli-dl\/SHA256SUMS\.txt/);
  assert.doesNotMatch(workflowRaw, /steps\.contract_artifacts\.outputs\.linux_tarball_path/);
});

test('release workflow appends repair-mode guidance for unsigned or lightweight tags', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');

  assert.match(workflowRaw, /name: Append release trust remediation guidance/);
  assert.match(workflowRaw, /node "\$\{\{\s*steps\.automation_root\.outputs\.path\s*\}\}\/tools\/priority\/release-trust-remediation\.mjs"/);
  assert.match(workflowRaw, /--trust-report tests\/results\/_agent\/supply-chain\/release-trust-gate\.json/);
  assert.match(workflowRaw, /--tag-ref "\$\{RELEASE_TAG\}"/);
  assert.match(workflowRaw, /--output tests\/results\/_agent\/release\/release-trust-remediation\.md/);
  assert.match(workflowRaw, /--summary "\$GITHUB_STEP_SUMMARY"/);
  assert.match(workflowRaw, /tests\/results\/_agent\/release\/release-trust-remediation\.md/);
});

test('release workflow always evaluates rollback drill health after trust gate failures', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflow = yaml.load(readFileSync(workflowPath, 'utf8'));
  const releaseSteps = workflow?.jobs?.release?.steps ?? [];
  const rollbackHealthStep = releaseSteps.find((step) => step?.name === 'Enforce rollback drill health gate');
  const validateRollbackStep = releaseSteps.find((step) => step?.name === 'Validate rollback drill health schema');
  const uploadRollbackStep = releaseSteps.find((step) => step?.name === 'Upload rollback drill health artifact');

  assert.equal(rollbackHealthStep?.if, 'always()');
  assert.equal(validateRollbackStep?.if, 'always()');
  assert.equal(uploadRollbackStep?.if, 'always()');
});

test('monthly release workflow marks itself as the SLO remediation candidate', () => {
  const workflowPath = path.join(workflowsRoot, 'monthly-stability-release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');

  assert.match(workflowRaw, /--candidate-workflow monthly-stability-release\.yml/);
});

test('monthly release workflow routes breach umbrellas as standing-excluded governance issues', () => {
  const workflowPath = path.join(workflowsRoot, 'monthly-stability-release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');

  assert.match(workflowRaw, /--route-labels "slo,ci,governance,standing-excluded"/);
});
