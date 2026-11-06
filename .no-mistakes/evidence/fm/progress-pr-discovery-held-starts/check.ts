import { readFileSync } from 'node:fs';
import { checkProgressState } from './src/progress/state.ts';
for (const p of process.argv.slice(2)) {
  const problems = checkProgressState(JSON.parse(readFileSync(p, 'utf8')));
  console.log(p.split('/').pop(), problems.length ? 'REJECTED: ' + JSON.stringify(problems) : 'accepted (0 problems)');
}
