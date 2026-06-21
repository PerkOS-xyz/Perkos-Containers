#!/usr/bin/env node
const BASE_URL = (process.env.KNOWLEDGE_BASE_URL || 'https://knowledge.perkos.xyz').replace(/\/$/, '');
const ORG_ID = process.env.KNOWLEDGE_ORG_ID || 'org_perkos';
const LLM_URL = (process.env.PERKOS_LLM_URL || 'http://127.0.0.1:5140').replace(/\/$/, '');
const MODEL = process.env.KNOWLEDGE_PROVIDER_MODEL || process.env.KNOWLEDGE_WORKER_MODEL || 'qwen2.5:7b';

function arg(name, fallback = undefined) {
  const eq = process.argv.find((x) => x.startsWith(`--${name}=`));
  if (eq) return eq.slice(name.length + 3);
  const i = process.argv.indexOf(`--${name}`);
  if (i >= 0) return process.argv[i + 1] ?? fallback;
  return fallback;
}

const AGENT_ID = arg('agent', process.env.KNOWLEDGE_AGENT_ID || 'perky');
const MAX = Number(arg('max', process.env.KNOWLEDGE_PROVIDER_MAX_PER_RUN || '1')) || 1;
const DRY_RUN = process.argv.includes('--dry-run');
const INCLUDE_TESTS = process.env.KNOWLEDGE_PROVIDER_INCLUDE_TESTS === '1' || process.argv.includes('--include-tests');

const profile = {
  perkyfi: {
    role: 'Markets Research Provider',
    focus: 'markets, trading, PERK/PERKOS, Base, Celo, Uniswap, wallet/token operations',
    terms: ['trading', 'trade', 'market', 'funding', 'rate', 'defi', 'perk', 'celo', 'base', 'uniswap', 'wallet', 'token', 'liquidity', 'swap', 'slippage'],
    phrases: ['perkos token', 'price support']
  },
  perky: {
    role: 'Research Librarian Provider',
    focus: 'general research, competitive intelligence, trend tracking, library/knowledge organization, uncategorized requests',
    terms: []
  },
  'perkos-agent': {
    role: 'Ecosystem Research Provider',
    focus: 'PerkOS ecosystem, architecture, x402, ERC-8004, A2A, Knowledge, agent workflows',
    terms: ['perkos', 'ecosystem', 'architecture', 'roadmap', 'agent', 'agents', 'x402', 'erc-8004', 'erc8004', 'a2a', 'knowledge', 'openclaw', 'plugin'],
    phrases: ['agent workflows', 'knowledge request lifecycle']
  }
}[AGENT_ID] || { role: 'Knowledge Provider', focus: 'general PerkOS Knowledge requests', terms: [], phrases: [] };

function log(msg) {
  console.log(`${new Date().toISOString()} ${AGENT_ID} ${msg}`);
}

function headers(auth = false) {
  const h = { 'content-type': 'application/json', 'x-agent-id': AGENT_ID, 'x-organization-id': ORG_ID };
  if (process.env.KNOWLEDGE_AGENT_WALLET) h['x-agent-wallet'] = process.env.KNOWLEDGE_AGENT_WALLET;
  if (process.env.KNOWLEDGE_AGENT_ERC8004) h['x-agent-erc8004'] = process.env.KNOWLEDGE_AGENT_ERC8004;
  if (auth && process.env.KNOWLEDGE_INGEST_TOKEN) h.authorization = `Bearer ${process.env.KNOWLEDGE_INGEST_TOKEN}`;
  return h;
}

async function api(method, path, body = undefined, auth = false) {
  const res = await fetch(`${BASE_URL}${path}`, { method, headers: headers(auth), body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let payload;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = { raw: text }; }
  if (!res.ok) {
    const detail = payload?.error || payload?.message || payload?.raw || res.statusText;
    throw new Error(`${method} ${path} failed ${res.status}: ${detail}`);
  }
  return payload;
}

function lowerRequest(r) {
  return `${r.query || ''} ${(r.missingTopics || []).join(' ')} ${r.desiredOutput || r.desired_output || ''}`.toLowerCase();
}

function isTestNoise(r) {
  const q = lowerRequest(r);
  return /\b(test|testing|qa|dummy|employing|hello|asdf)\b/.test(q) && q.length < 80;
}

function hasWord(q, term) {
  const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(^|[^a-z0-9])${escaped}([^a-z0-9]|$)`, 'i').test(q);
}

function matchesProfile(r) {
  if (isTestNoise(r) && !INCLUDE_TESTS) return false;
  if (AGENT_ID === 'perky') return true;
  const q = lowerRequest(r);
  const terms = profile.terms || [];
  const phrases = profile.phrases || [];
  return terms.some((t) => hasWord(q, t)) || phrases.some((p) => q.includes(p));
}

async function listRequests(status) {
  const data = await api('GET', `/knowledge/requests?status=${encodeURIComponent(status)}&limit=25`);
  return data?.requests || [];
}

async function generateResearch(request) {
  const query = request.query || '';
  const prompt = `You are ${AGENT_ID}, the ${profile.role} for PerkOS Knowledge.\n\nProvider focus: ${profile.focus}.\nKnowledge request: ${query}\nDesired output: ${request.desiredOutput || request.desired_output || 'research/context'}\nMissing topics: ${(request.missingTopics || []).join(', ') || 'none supplied'}\n\nProduce a concise internal research response. Requirements:\n- Answer directly and practically.\n- Include a short "Actionable findings" section.\n- Include an "Evidence / validation" section that clearly separates verified facts from assumptions.\n- If live external sources were not checked, say so and mark the item pending validation.\n- Do not invent secrets, tokens, private keys, or unsupported claims.\n- Keep under 900 words.`;
  const payload = { model: MODEL, stream: false, messages: [{ role: 'user', content: prompt }] };
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), Number(process.env.KNOWLEDGE_PROVIDER_LLM_TIMEOUT_MS || 120000));
  try {
    const res = await fetch(`${LLM_URL}/api/chat`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload), signal: ctrl.signal });
    const text = await res.text();
    if (!res.ok) throw new Error(`LLM failed ${res.status}: ${text.slice(0, 200)}`);
    const data = JSON.parse(text);
    const content = data?.message?.content?.trim();
    if (!content) throw new Error('LLM returned empty content');
    return content;
  } finally {
    clearTimeout(timer);
  }
}

function slug(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 70) || 'research';
}

function extractItemIds(payload) {
  const ids = [];
  function walk(x) {
    if (!x || typeof x !== 'object') return;
    if (typeof x.id === 'string' && x.id.startsWith('kitem_')) ids.push(x.id);
    for (const v of Object.values(x)) walk(v);
  }
  walk(payload);
  return [...new Set(ids)];
}

async function processRequest(r, alreadyClaimed = false) {
  const id = r.id;
  const query = r.query || id;
  log(`${DRY_RUN ? 'DRY ' : ''}selected request=${id} query=${query.slice(0, 140)}`);
  if (DRY_RUN) return true;

  if (!alreadyClaimed) {
    await api('POST', `/knowledge/requests/${encodeURIComponent(id)}/claim`, { notes: `Claimed by ${profile.role} (${AGENT_ID}) via provider loop.` }, true);
    log(`claimed request=${id}`);
  }

  const content = await generateResearch(r);
  const title = `Research response: ${query}`.slice(0, 180);
  const summary = content.replace(/\s+/g, ' ').slice(0, 500);
  const path = `requests/${id}-${AGENT_ID}-${slug(query)}.md`;
  const evidenceNote = `Generated by ${profile.role} (${AGENT_ID}) from PerkOS Knowledge request ${id}. Agent focus: ${profile.focus}. Content is pending validation unless explicit source links are included in the body.`;

  const submitted = await api('POST', '/api/ingest/research', {
    source: AGENT_ID,
    visibility: 'private',
    organization_id: ORG_ID,
    contribution_type: 'research',
    items: [{ path, title, summary, content, contribution_type: 'research', evidence: [{ type: 'note', note: evidenceNote }] }]
  }, true);
  const itemIds = extractItemIds(submitted);
  if (!itemIds.length) throw new Error(`submit succeeded but no kitem id returned for request=${id}`);

  await api('POST', `/knowledge/requests/${encodeURIComponent(id)}/fulfill`, { research_item_ids: itemIds, notes: `Fulfilled by ${profile.role} (${AGENT_ID}); pending validation/accounting.` }, true);
  log(`fulfilled request=${id} item_ids=${itemIds.join(',')}`);
  return true;
}

async function main() {
  if (!process.env.KNOWLEDGE_INGEST_TOKEN && !DRY_RUN) throw new Error('missing KNOWLEDGE_INGEST_TOKEN');
  const open = await listRequests('open');
  const claimed = await listRequests('claimed').catch(() => []);
  const candidates = [
    ...claimed.filter((r) => r.claimedByAgentId === AGENT_ID || r.claimed_by_agent_id === AGENT_ID).map((r) => ({ r, already: true })),
    ...open.filter((r) => !r.claimedByAgentId && !r.claimed_by_agent_id).map((r) => ({ r, already: false }))
  ].filter(({ r }) => matchesProfile(r));

  if (!candidates.length) {
    log('OK no matching requests');
    return;
  }

  let done = 0;
  for (const c of candidates) {
    if (done >= MAX) break;
    try {
      if (await processRequest(c.r, c.already)) done++;
    } catch (err) {
      log(`WARN failed request=${c.r.id}: ${err.message}`);
    }
  }
  log(`DONE processed=${done}`);
}

main().catch((err) => {
  log(`ERROR ${err.message}`);
  process.exit(1);
});
