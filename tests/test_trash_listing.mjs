import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../DockHost.qml', import.meta.url), 'utf8');
const body = source.match(/^  function settleTrashList\(\) \{[\s\S]*?^  }/m)?.[0];
assert.ok(body, 'Exercise the actual Trash listing settle handler');

function listing(previousCount, previousKnown) {
  const host = vm.createContext({
    trashListExitCode: -1, trashListOutputDone: false,
    trashItemCount: previousCount, trashStateKnown: previousKnown,
    trashListOutput: { text: '' },
    DockModel: { trashItemCount: text => text.split('\n').filter(Boolean).length },
  });
  vm.runInContext(body, host);
  return {
    host,
    output(text) { host.trashListOutput.text = text; host.trashListOutputDone = true; host.settleTrashList(); },
    exit(code) { host.trashListExitCode = code; host.settleTrashList(); },
  };
}

let run = listing(0, false);
run.output('a\nb\n');
assert.equal(run.host.trashStateKnown, false, 'Output alone does not settle a listing');
run.exit(0);
assert.deepEqual([run.host.trashItemCount, run.host.trashStateKnown], [2, true]);

run = listing(0, false);
run.exit(0);
assert.equal(run.host.trashStateKnown, false, 'A clean exit waits for its output');
run.output('a\n');
assert.deepEqual([run.host.trashItemCount, run.host.trashStateKnown], [1, true]);

run = listing(5, true);
run.exit(1);
assert.equal(run.host.trashStateKnown, false, 'A failed listing reads as unknown, never empty');
run.output('');
assert.equal(run.host.trashStateKnown, false, 'Late output of a failed listing changes nothing');
assert.equal(run.host.trashItemCount, 5);

console.log('Trash listing settles on exit code and output: PASS');
