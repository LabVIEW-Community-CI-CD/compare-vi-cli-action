import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { ArgumentParser } from 'argparse';

const parser = new ArgumentParser({
  description: 'Invoke the TestStand compare harness (tools/TestStand-CompareHarness.ps1)'
});

parser.add_argument('--base', {
  required: true,
  help: 'Path to the base VI'
});

parser.add_argument('--head', {
  required: true,
  help: 'Path to the head VI'
});

parser.add_argument('--labview', {
  help: 'Optional LabVIEW.exe path passed to the harness'
});

parser.add_argument('--lvcompare', {
  help: 'Optional LVCompare.exe path passed to the harness'
});

parser.add_argument('--output', {
  default: 'tests/results/teststand-session',
  help: 'Output root for generated artifacts (default: tests/results/teststand-session)'
});

parser.add_argument('--render-report', {
  action: 'store_true',
  help: 'Render compare-report.html via the harness'
});

parser.add_argument('--close-labview', {
  action: 'store_true',
  help: 'Request LabVIEW shutdown after compare completes'
});

parser.add_argument('--close-lvcompare', {
  action: 'store_true',
  help: 'Request LVCompare shutdown after compare completes'
});

const args = parser.parse_args();

const repoRoot = process.cwd();
const harnessPath = resolve(repoRoot, 'tools', 'TestStand-CompareHarness.ps1');

const pwshArgs: string[] = ['-NoLogo', '-NoProfile', '-File', harnessPath, '-BaseVi', args.base, '-HeadVi', args.head, '-OutputRoot', args.output];

if (args.labview) {
  pwshArgs.push('-LabVIEWPath', args.labview);
}

if (args.lvcompare) {
  pwshArgs.push('-LVComparePath', args.lvcompare);
}

if (args.render_report) {
  pwshArgs.push('-RenderReport');
}

if (args.close_labview) {
  pwshArgs.push('-CloseLabVIEW');
}

if (args.close_lvcompare) {
  pwshArgs.push('-CloseLVCompare');
}

const child = spawn('pwsh', pwshArgs, { stdio: 'inherit' });

child.on('exit', (code) => {
  process.exit(typeof code === 'number' ? code : 1);
});
