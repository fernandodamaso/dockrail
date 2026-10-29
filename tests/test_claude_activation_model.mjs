import assert from 'node:assert/strict'
import { loadModel } from './host_harness.mjs'

const ClaudeActivation = loadModel('DockClaudeActivationModel')

// Exact route for a canonical Claude server id and a local_ session id.
assert.equal(
  ClaudeActivation.sessionUrl('claude:local', 'local_9c9eb232-bfa0-4023-ac76-79aee015b3c5'),
  'claude://code/continue?session=local_9c9eb232-bfa0-4023-ac76-79aee015b3c5')

// Boundary: 1 and 64 characters after local_ are accepted, 0 and 65 are not.
assert.ok(ClaudeActivation.sessionUrl('claude:local', 'local_a') !== '')
assert.ok(ClaudeActivation.sessionUrl('claude:local', 'local_' + 'a'.repeat(64)) !== '')
assert.equal(ClaudeActivation.sessionUrl('claude:local', 'local_'), '')
assert.equal(ClaudeActivation.sessionUrl('claude:local', 'local_' + 'a'.repeat(65)), '')

// Unknown session ids (the empty string from the provider) never build a route.
assert.equal(ClaudeActivation.sessionUrl('claude:local', ''), '')

for (const bad of [
  ['local:1', 'local_abc'],
  ['t3:env-1', 'local_abc'],
  ['herdr:x', 'local_abc'],
  ['', 'local_abc'],
  ['claude:local', 'last'],
  ['claude:local', '9c9eb232-bfa0-4023-ac76-79aee015b3c5'],
  ['claude:local', 'remote_abc'],
  ['claude:local', 'LOCAL_abc'],
  ['claude:local', 'local_has space'],
  ['claude:local', 'local_a/b'],
  ['claude:local', 'local_a?x=1'],
  ['claude:local', 'local_a#frag'],
  ['claude:local', 'local_a%2Fb'],
  ['claude:local', 'local_a_b'],
  ['claude:local', 'local_\n'],
  ['claude:' + 'y'.repeat(510), 'local_abc'],
]) {
  assert.equal(ClaudeActivation.sessionUrl(bad[0], bad[1]), '',
    'rejects ' + JSON.stringify(bad))
}

// Non-string inputs fail closed.
for (const bad of [
  [null, 'local_abc'],
  [undefined, 'local_abc'],
  ['claude:local', null],
  ['claude:local', undefined],
  ['claude:local', 42],
  [42, 'local_abc'],
  [['claude:local'], 'local_abc'],
  ['claude:local', ['local_abc']],
]) {
  assert.equal(ClaudeActivation.sessionUrl(bad[0], bad[1]), '',
    'rejects non-string ' + String(bad[0]) + ' / ' + String(bad[1]))
}

console.log('test_claude_activation_model: all assertions passed')
