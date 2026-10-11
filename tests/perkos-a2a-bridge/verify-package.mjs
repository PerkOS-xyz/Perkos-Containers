import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.PACKAGE_ROOT || '/opt/perkos-a2a/node_modules/@perkos/perkos-a2a';
const expected = process.env.EXPECTED_A2A_VERSION;
assert.ok(expected, 'Expected package version is required');
for (const file of ['package.json', 'openclaw.plugin.json']) {
  assert.equal(JSON.parse(readFileSync(join(root, file), 'utf8')).version, expected);
}
for (const file of ['tools-token-listener.js', 'mcp-server.js']) {
  assert.match(readFileSync(join(root, 'dist', file), 'utf8'), /toolsActorName/);
}
const { toolsActorName } = await import(pathToFileURL(join(root, 'dist/tools-jwt.js')));
const { startToolsTokenListener } = await import(pathToFileURL(join(root, 'dist/tools-token-listener.js')));
assert.throws(() => toolsActorName(''));
const logger = { info() {}, error() {} };
assert.throws(() => startToolsTokenListener({ agentName: '', logger }));

// Only synthetic identities/secrets. No cloud calls, no credentials or JWTs logged.
const secret = 'synthetic-contract-test-secret-at-least-32-bytes';
const bridgeAuth = 'synthetic-runtime-auth';
const actor = 'contract-test-actor';
const identities = [
  { wallet: '0x' + 'Ab'.repeat(20), role: 'user' },
  { wallet: '0x' + 'Cd'.repeat(20), role: 'admin' },
  { wallet: 'So11111111111111111111111111111111111111112', role: 'admin' },
];
const registry = new Map(identities.map((entry, i) => [`test-conversation-${i}`, entry]));
const listener = startToolsTokenListener({
  agentName: actor, port: 0, bridgeAuthSecret: bridgeAuth,
  toolsJwtSecret: secret, toolsApiUrl: 'https://invalid.example/tools',
  registry: { get: (key) => registry.get(key), size: () => registry.size }, logger,
});
try {
  if (!listener.server.listening) await once(listener.server, 'listening');
  const url = `http://127.0.0.1:${listener.server.address().port}/v1/tools-token`;
  assert.equal((await fetch(url, { method: 'POST', body: '{}' })).status, 401);
  for (const [i, identity] of identities.entries()) {
    const response = await fetch(url, {
      method: 'POST', headers: { 'X-Bridge-Auth': bridgeAuth, 'content-type': 'application/json' },
      body: JSON.stringify({ convId: `test-conversation-${i}`, agent: 'untrusted-body-actor' }),
    });
    assert.equal(response.status, 200);
    const { token } = await response.json();
    const [header, payload, signature] = token.split('.');
    assert.equal(signature, createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url'));
    const claims = JSON.parse(Buffer.from(payload, 'base64url'));
    assert.equal(claims.agent, actor); // Not the body actor or conversation name.
    const solana = i === 2;
    assert.equal(claims.wallet, solana ? identity.wallet : identity.wallet.toLowerCase());
    assert.equal(claims.role, solana ? 'user' : identity.role);
    if (solana) assert.equal(claims.walletChain, 'solana');
    assert.ok(claims.exp > claims.iat);
  }
} finally {
  if (listener.server.listening) await listener.stop();
}
console.log('Installed package/manifests and authenticated actor emission verified (3 synthetic cases).');
