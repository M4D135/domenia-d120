// Runs every test module of the shell and writes the report in the page (and in data-result for an automated reader).
import { run } from './harness.mjs';
import './shell/board.test.mjs';
import './shell/charts.test.mjs';
import './shell/commands.test.mjs';
import './shell/contrast.test.mjs';
import './shell/environment.test.mjs';
import './shell/exports.test.mjs';
import './shell/glyphs.test.mjs';
import './shell/guards.test.mjs';
import './shell/help.test.mjs';
import './shell/navigation.test.mjs';
import './shell/notify.test.mjs';
import './shell/overview.test.mjs';
import './shell/pickers.test.mjs';
import './shell/sheets.test.mjs';
import './shell/store.test.mjs';
import './shell/summary.test.mjs';
import './shell/tasks.test.mjs';
import './shell/appearance.test.mjs';

const report = await run();
const out = document.getElementById('out');
out.textContent = [`${report.passed} réussi(s), ${report.failed} en échec`, ...report.results.map((r) => `${r.passed ? 'OK ' : 'ÉCHEC'} ${r.name}${r.error ? ` : ${r.error}` : ''}`)].join('\n');
document.documentElement.dataset.result = report.failed ? 'failed' : 'passed';
