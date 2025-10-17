import '../bootstrap/node-deprecations.js';
function getEnv(name) {
    return process.env[name];
}
function appendOutput(lines) {
    const outPath = getEnv('GITHUB_OUTPUT');
    if (!outPath)
        throw new Error('GITHUB_OUTPUT not set');
    const fs = require('fs');
    fs.appendFileSync(outPath, lines.join('\n') + '\n', { encoding: 'utf8' });
}
function setOutput(name, value) {
    const safe = (value ?? '').toString().replace(/\r?\n/g, ' ').trim();
    appendOutput([`${name}=${safe}`]);
}
function pad2(n) { return n < 10 ? '0' + n : '' + n; }
function formatSampleSuffix(d = new Date()) {
    const yyyy = d.getFullYear();
    const mm = pad2(d.getMonth() + 1);
    const dd = pad2(d.getDate());
    const HH = pad2(d.getHours());
    const MM = pad2(d.getMinutes());
    const SS = pad2(d.getSeconds());
    return `${yyyy}${mm}${dd}-${HH}${MM}${SS}-oc`;
}
function parseBoolToken(tok) {
    const lc = tok.toLowerCase();
    if (['true', 'yes', '1', 'on'].includes(lc))
        return 'true';
    if (['false', 'no', '0', 'off'].includes(lc))
        return 'false';
    return lc; // pass-through
}
function parse(body) {
    let strategy = 'matrix';
    let include = 'true';
    let sample = '';
    const lower = body.toLowerCase();
    const m = lower.match(/\s*\/run\s+orchestrated(.*)$/is);
    if (!m) {
        return { strategy, include, sample: formatSampleSuffix() };
    }
    const tailRaw = body.substring(body.toLowerCase().indexOf(m[0]) + '/run orchestrated'.length).trim();
    const tokens = tailRaw.split(/\s+/).filter(Boolean);
    let expectStrategy = false;
    let expectInclude = false;
    let expectSample = false;
    for (const tok of tokens) {
        if (expectStrategy) {
            const lc = tok.toLowerCase();
            if (lc === 'single' || lc === 'matrix')
                strategy = lc;
            else
                strategy = lc;
            expectStrategy = false;
            continue;
        }
        if (expectInclude) {
            include = parseBoolToken(tok);
            expectInclude = false;
            continue;
        }
        if (expectSample) {
            sample = tok;
            expectSample = false;
            continue;
        }
        const lc = tok.toLowerCase();
        const clean = lc.replace(/:/g, '=').replace(/^--/, '');
        // strategy keyword expects next token
        if (lc === 'strategy') {
            expectStrategy = true;
            continue;
        }
        // strategy=...
        if (clean.startsWith('strategy=')) {
            const v = clean.substring('strategy='.length);
            if (v === 'single' || v === 'matrix')
                strategy = v;
            continue;
        }
        // shorthand toggles
        if (['single', 'single=true', 'single=yes', 'single=1', 'single=on', '--single'].includes(clean)) {
            strategy = 'single';
            continue;
        }
        if (['matrix', 'matrix=true', 'matrix=yes', 'matrix=1', 'matrix=on', '--matrix'].includes(clean)) {
            strategy = 'matrix';
            continue;
        }
        // explicit integration toggles
        if (['integration=true', 'include_integration=true'].includes(clean)) {
            include = 'true';
            continue;
        }
        if (['integration=false', 'include_integration=false'].includes(clean)) {
            include = 'false';
            continue;
        }
        // include_integration=...
        if (clean.startsWith('include_integration=')) {
            include = clean.substring('include_integration='.length);
            continue;
        }
        // integration/include_integration keyword expects next token
        if (clean === 'include_integration' || clean === 'integration') {
            expectInclude = true;
            continue;
        }
        // sample tokens
        if (lc.startsWith('sample=') || lc.startsWith('sample_id=')) {
            sample = tok.substring(tok.indexOf('=') + 1);
            continue;
        }
        if (lc === 'sample' || lc === 'sample_id') {
            expectSample = true;
            continue;
        }
    }
    if (!sample)
        sample = formatSampleSuffix();
    return { strategy, include, sample };
}
function run() {
    const body = getEnv('INPUT_BODY') || '';
    const out = parse(body);
    setOutput('strategy', out.strategy);
    setOutput('include_integration', out.include);
    setOutput('sample_id', out.sample);
}
try {
    run();
}
catch (err) {
    const msg = err?.message || String(err);
    try {
        appendOutput([`error=${msg}`]);
    }
    catch { }
    process.stderr.write(`parse-orchestrated error: ${msg}\n`);
    process.exit(1);
}
