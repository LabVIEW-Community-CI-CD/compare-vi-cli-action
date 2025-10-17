import '../bootstrap/node-deprecations.js';
// Minimal JS/TS action without external deps.
// Reads INPUT_BODY, writes multi-line 'comment' and single-line 'target' to GITHUB_OUTPUT.
function getEnv(name) {
    return process.env[name];
}
function appendOutput(lines) {
    const outPath = getEnv('GITHUB_OUTPUT');
    if (!outPath) {
        throw new Error('GITHUB_OUTPUT not set');
    }
    const fs = require('fs');
    fs.appendFileSync(outPath, lines.join('\n') + '\n', { encoding: 'utf8' });
}
function setOutput(name, value) {
    // single-line safe output (no newlines)
    const safe = value.replace(/\r?\n/g, ' ').trim();
    appendOutput([`${name}=${safe}`]);
}
function setOutputMultiline(name, value) {
    const delim = '__CMD_BODY__';
    appendOutput([`${name}<<${delim}`, value, delim]);
}
function detectTarget(lower) {
    const m = lower.match(/^\s*\/run\s+(\S+)/);
    if (!m)
        return '';
    const first = m[1];
    switch (first) {
        case 'unit':
        case 'mock':
        case 'smoke':
        case 'pester-selfhosted':
        case 'orchestrated':
            return first;
        default:
            return '';
    }
}
function run() {
    const body = getEnv('INPUT_BODY') || '';
    const lower = body.toLowerCase();
    setOutputMultiline('comment', lower);
    const target = detectTarget(lower);
    if (target)
        setOutput('target', target);
}
try {
    run();
}
catch (err) {
    // Best-effort error emission (so consumers see failure reason)
    const msg = err && err.message ? err.message : String(err);
    try {
        appendOutput([`error=${msg}`]);
    }
    catch { }
    process.stderr.write(`normalize-command error: ${msg}\n`);
    process.exit(1);
}
