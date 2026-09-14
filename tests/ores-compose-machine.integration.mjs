import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const CONTRACT_SHA = '5dbda2127357b4be87821902d36e4ce9560f6876';
const CONTRACT_BASE = `https://raw.githubusercontent.com/ORESoftware/ores-interfaces/${CONTRACT_SHA}/contracts/ores-compose-machine/v1`;
const plan = JSON.parse(await readFile(new URL('../test-plan.json', import.meta.url), 'utf8'));

async function fetchContract(path) {
  const response = await fetch(`${CONTRACT_BASE}/${path}`);
  assert.equal(response.status, 200, `failed to fetch ${path}`);
  return response.text();
}

const schema = JSON.parse(await fetchContract('authored.schema.json'));
const defs = schema.$defs;

test('OCI harness retains Docker and Podman coverage with immutable source pins', () => {
  assert.equal(plan.profile, 'infra-e2e');
  assert.ok(plan.focus.includes('Docker and Podman'));
  assert.equal(plan.security.immutableSourcePins, true);
  assert.ok(plan.sources.every((source) => /^[0-9a-f]{40}$/.test(source.sha)));
});

test('runtime-private container addresses cannot become public machine ingress', () => {
  const pattern = new RegExp(defs.MachineIngress.properties.authority.pattern);
  assert.equal(pattern.test('172.17.0.2:8080'), false, 'Docker bridge address leaked');
  assert.equal(pattern.test('10.88.0.4:8080'), false, 'Podman bridge address leaked');
  assert.ok(pattern.test('127.0.0.1:39123'));
});

test('runtime swaps remain serialized through one machine job state contract', () => {
  const states = defs.JobStatusResponse.properties.state.anyOf.map((entry) => entry.const);
  assert.deepEqual(states, ['queued', 'running', 'ready', 'failed']);
  assert.equal(defs.EnqueueResponse.properties.state.anyOf.some((x) => x.const === 'running'), true);
});

test('public active-system contract has no Docker or Podman backend-address escape hatch', () => {
  for (const forbidden of ['container_ip', 'backend_ip', 'docker_host', 'podman_host', 'container_port']) {
    assert.equal(defs.ActiveSystem.properties[forbidden], undefined, forbidden);
    assert.equal(defs.MachineIngress.properties[forbidden], undefined, forbidden);
  }
});

test('public PR lane stays credential-free while machine integration consumes public contract evidence', () => {
  assert.equal(plan.security.pullRequestCredentials, false);
  assert.equal(plan.security.leastPrivilege, true);
  assert.match(schema.$id, /compose\/machine\/v1\.json$/);
  assert.equal(defs.EnsureRequest.properties.schema_version.const, 'ores.compose.machine.v1');
});
