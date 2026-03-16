import process from 'node:process';
import { runMetadataApply } from './github-metadata-lib.js';
function main() {
    const result = runMetadataApply();
    const label = result.exitCode === 0 ? '[info]' : '[warn]';
    // eslint-disable-next-line no-console
    console.log(`${label} GitHub metadata apply report written to ${result.reportPath}`);
    if (result.exitCode !== 0) {
        process.exitCode = result.exitCode;
    }
}
main();
