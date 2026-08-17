#!/usr/bin/env node
const BASE_URL = (process.env.KNOWLEDGE_BASE_URL || 'https://knowledge.perkos.xyz').replace(/\/$/, '');
const LLM_URL = (process.env.PERKOS_LLM_URL || 'https://api.llm.perkos.xyz').replace(/\/$/, '');

function openclawAgentId() {
  if (process.env.KNOWLEDGE_SEND_AGENT_ID !== '1') return null;
  return process.env.KNOWLEDGE_AGENT_ID || null;
}

function envValue(name) {
  return process.env[name] || '';
}

function headers(auth = false) {
  const h = { 'content-type': 'application/json' };
  const agentId = openclawAgentId();
  const wallet = envValue('KNOWLEDGE_AGENT_WALLET');
  const erc8004 = envValue('KNOWLEDGE_AGENT_ERC8004');
  const orgId = envValue('KNOWLEDGE_ORG_ID');
  const ingestToken = auth ? envValue('KNOWLEDGE_INGEST_TOKEN') : '';

  if (agentId) h['x-agent-id'] = agentId;
  if (wallet) h['x-agent-wallet'] = wallet;
  if (erc8004) h['x-agent-erc8004'] = erc8004;
  if (orgId) h['x-organization-id'] = orgId;
  if (ingestToken) h.authorization = `Bearer ${ingestToken}`;
  return h;
}

function requestOptions(method, body, auth) {
  return {
    method,
    headers: headers(auth),
    body: body ? JSON.stringify(body) : undefined
  };
}

async function req(method, path, body, auth = false) {
  const res = await fetch(`${BASE_URL}${path}`, requestOptions(method, body, auth));
  const text = await res.text();
  let payload;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = { raw: text }; }
  console.log(JSON.stringify(payload, null, 2));
  if (!res.ok) process.exit(1);
}

function take(args, name, fallback = undefined) {
  const i = args.indexOf(`--${name}`);
  if (i >= 0) return args.splice(i, 2)[1] ?? fallback;
  const prefix = `--${name}=`;
  const j = args.findIndex((x) => x.startsWith(prefix));
  if (j >= 0) return args.splice(j, 1)[0].slice(prefix.length);
  return fallback;
}

function takeAll(args, name) {
  const values = [];
  for (;;) {
    const before = args.length;
    const value = take(args, name, undefined);
    if (value !== undefined) values.push(value);
    if (args.length === before) break;
  }
  return values;
}


async function llmReq(path, token) {
  const res = await fetch(`${LLM_URL}${path}`, {
    method: 'GET',
    headers: { authorization: `Bearer ${token}` }
  });
  const text = await res.text();
  let payload;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = { raw: text }; }
  if (!res.ok) {
    console.log(JSON.stringify(payload, null, 2));
    process.exit(1);
  }
  return payload;
}

function currentAgentId() {
  return process.env.KNOWLEDGE_AGENT_ID || process.env.PERKOS_AGENT_ID || openclawAgentId() || '';
}

function filterUsageForAgent(payload, agentId) {
  if (!agentId || !payload || !Array.isArray(payload.agents)) return payload;
  return {
    ...payload,
    agents: payload.agents.filter((agent) => agent.agentGuid === agentId || agent.agentLabel === agentId),
    filter: { agentId }
  };
}

function parseEvidence(raw, urls, paths, notes) {
  const evidence = [];
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) throw new Error('must be a JSON array');
      evidence.push(...parsed);
    } catch (err) {
      console.error(`--evidence must be a JSON array: ${err.message}`);
      process.exit(2);
    }
  }
  evidence.push(...urls.map((url) => ({ type: 'url', url, verified: true })));
  evidence.push(...paths.map((path) => ({ type: 'file', path, verified: true })));
  evidence.push(...notes.map((note) => ({ type: 'note', note })));
  return evidence.length ? evidence : undefined;
}

const [cmd, ...rest0] = process.argv.slice(2);
const rest = [...rest0];
const usage = 'Usage: perkos_tech.mjs manifest|x402-policy|query|requests|request-create|request-claim|request-fulfill|request-validate|submit-research|llm-usage ...';
if (!cmd) { console.error(usage); process.exit(2); }

if (cmd === 'manifest') await req('GET', '/skill/manifest');
else if (cmd === 'x402-policy') await req('GET', '/api/x402/policy');
else if (cmd === 'query') {
  const limit = Number(take(rest, 'limit', process.env.KNOWLEDGE_LIMIT || 5));
  const create = take(rest, 'create-request-on-miss', undefined);
  const desired = take(rest, 'desired-output', undefined);
  const qualityMode = take(rest, 'quality-mode', process.env.KNOWLEDGE_QUALITY_MODE || undefined);
  const minConfidenceRaw = take(rest, 'min-confidence', process.env.KNOWLEDGE_MIN_CONFIDENCE || undefined);
  const requireValidatedRaw = take(rest, 'require-validated', undefined);
  const query = rest.join(' ').trim();
  if (!query) { console.error('query required'); process.exit(2); }
  await req('POST', '/skill/query', {
    query,
    limit,
    createRequestOnMiss: create === undefined ? undefined : create !== 'false',
    desired_output: desired,
    qualityMode,
    minConfidence: minConfidenceRaw === undefined ? undefined : Number(minConfidenceRaw),
    requireValidated: requireValidatedRaw === undefined ? undefined : requireValidatedRaw !== 'false'
  });
} else if (cmd === 'requests') {
  const status = encodeURIComponent(take(rest, 'status', 'open'));
  const limit = encodeURIComponent(take(rest, 'limit', '25'));
  await req('GET', `/knowledge/requests?status=${status}&limit=${limit}`);
} else if (cmd === 'request-create') {
  const priority = take(rest, 'priority', undefined);
  const desired = take(rest, 'desired-output', undefined);
  const query = rest.join(' ').trim();
  if (!query) { console.error('query required'); process.exit(2); }
  await req('POST', '/knowledge/requests', { query, priority, desired_output: desired });
} else if (cmd === 'request-claim') {
  const requestId = take(rest, 'request') || rest[0];
  if (!requestId) { console.error('request id required'); process.exit(2); }
  await req('POST', `/knowledge/requests/${encodeURIComponent(requestId)}/claim`, { notes: take(rest, 'notes', undefined) }, true);
} else if (cmd === 'request-fulfill') {
  const requestId = take(rest, 'request') || rest[0];
  const itemIds = (take(rest, 'item-ids', '') || '').split(',').map((x) => x.trim()).filter(Boolean);
  if (!requestId || !itemIds.length) { console.error('request id and --item-ids required'); process.exit(2); }
  await req('POST', `/knowledge/requests/${encodeURIComponent(requestId)}/fulfill`, { research_item_ids: itemIds, notes: take(rest, 'notes', undefined) }, true);
} else if (cmd === 'request-validate') {
  const requestId = take(rest, 'request') || rest[0];
  if (!requestId) { console.error('request id required'); process.exit(2); }
  await req('POST', `/knowledge/requests/${encodeURIComponent(requestId)}/validate`, { accepted: take(rest, 'accepted', 'true') !== 'false', validation_notes: take(rest, 'notes', undefined) }, true);
} else if (cmd === 'llm-usage') {
  const token = process.env.PERKOS_LLM_ADMIN_TOKEN || process.env.ADMIN_TOKEN || '';
  if (!token) { console.error('PERKOS_LLM_ADMIN_TOKEN or ADMIN_TOKEN required'); process.exit(2); }
  const hours = encodeURIComponent(take(rest, 'hours', '24'));
  const limit = encodeURIComponent(take(rest, 'limit', '10000'));
  const self = take(rest, 'self', undefined) !== undefined;
  const agent = take(rest, 'agent', self ? currentAgentId() : '');
  const payload = await llmReq(`/admin/llm-usage?hours=${hours}&limit=${limit}`, token);
  console.log(JSON.stringify(agent ? filterUsageForAgent(payload, agent) : payload, null, 2));
} else if (cmd === 'submit-research') {
  const path = take(rest, 'path', undefined);
  if (!path) { console.error('--path required'); process.exit(2); }
  const source = take(rest, 'source', undefined);
  const visibility = take(rest, 'visibility', 'private');
  const organizationId = take(rest, 'organization-id', process.env.KNOWLEDGE_ORG_ID || undefined);
  const contributionType = take(rest, 'contribution-type', 'research');
  const evidence = parseEvidence(
    take(rest, 'evidence', undefined),
    takeAll(rest, 'evidence-url'),
    takeAll(rest, 'evidence-path'),
    takeAll(rest, 'evidence-note')
  );
  await req('POST', '/api/ingest/research', {
    source,
    visibility,
    organization_id: organizationId,
    contribution_type: contributionType,
    items: [{
      path,
      title: take(rest, 'title', path),
      summary: take(rest, 'summary', undefined),
      content: take(rest, 'content', undefined),
      contribution_type: contributionType,
      evidence
    }]
  }, true);
} else {
  console.error(usage);
  process.exit(2);
}
