import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { ml_dsa44 } from '@noble/post-quantum/ml-dsa.js';

const PORT = Number(process.env.PORT || 8787);
const DATA_DIR = process.env.DATA_DIR || '/var/lib/mmc-node';
const CHAIN_FILE = path.join(DATA_DIR, 'chain.json');
const PENDING_FILE = path.join(DATA_DIR, 'pending.json');
const SCHEDULE_FILE = path.join(DATA_DIR, 'schedule.json');
const MAX_SUPPLY = 21000000;
const INITIAL_REWARD = 50;
const HALVING_INTERVAL = 210000;
const MINING_INTERVAL_MS = 10 * 60 * 1000;
const GENESIS = { index: 0, prevHash: '0'.repeat(64), timestamp: 0, transactions: [{ type: 'genesis', amount: 0 }], hash: '3d8d22899a36c78da2aa082360f36ba770db9d312dd1a5c49687fec6287a39ee' };
let chain = [];
let pending = [];
let initialAvailableAt = 0;
let writeLock = Promise.resolve();

fs.mkdirSync(DATA_DIR, { recursive: true });
function loadJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
const saved = loadJson(CHAIN_FILE, { chain: [GENESIS] });
chain = Array.isArray(saved) ? saved : (Array.isArray(saved.chain) ? saved.chain : [GENESIS]);
if (!chain.length) chain = [GENESIS];
pending = loadJson(PENDING_FILE, []);
if (!Array.isArray(pending)) pending = [];
const savedSchedule = loadJson(SCHEDULE_FILE, {});
initialAvailableAt = Number(savedSchedule.initialAvailableAt || 0);
if (!Number.isFinite(initialAvailableAt) || initialAvailableAt <= 0) {
  initialAvailableAt = Date.now() + MINING_INTERVAL_MS;
  fs.writeFileSync(SCHEDULE_FILE, JSON.stringify({ initialAvailableAt }, null, 2));
}
function persist() {
  writeLock = writeLock.then(async () => {
    const tmpChain = `${CHAIN_FILE}.tmp`, tmpPending = `${PENDING_FILE}.tmp`;
    await fs.promises.writeFile(tmpChain, JSON.stringify({ chain }, null, 2));
    await fs.promises.writeFile(tmpPending, JSON.stringify(pending, null, 2));
    await fs.promises.rename(tmpChain, CHAIN_FILE);
    await fs.promises.rename(tmpPending, PENDING_FILE);
  });
  return writeLock;
}
function json(res, body, status = 200) { const text = JSON.stringify(body); res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Cache-Control': 'no-store' }); res.end(text); }
function readBody(req) { return new Promise((resolve, reject) => { let data = ''; req.on('data', c => { data += c; if (data.length > 2_000_000) reject(new Error('BODY_TOO_LARGE')); }); req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}); } catch { reject(new Error('INVALID_JSON')); } }); req.on('error', reject); }); }
function fail(message, status = 400) { const e = new Error(message); e.status = status; throw e; }
function sha256Hex(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function b64(value, field) { if (typeof value !== 'string' || !value) fail(`${field} is required`); try { return Buffer.from(value, 'base64'); } catch { fail(`${field} is not valid base64`); } }
function amountUnits(value) { if (typeof value !== 'string' || !/^\d+(?:\.\d{1,8})?$/.test(value) || Number(value) <= 0) fail('Invalid amount'); const parts=value.split('.'), decimals=parts[1]?.length||0, digits=parts.join(''); return BigInt(digits.padEnd(digits.length + 8 - decimals, '0')); }
function addressFromPublicKey(publicKey) { return `pqc1${crypto.createHash('sha256').update(publicKey).digest('hex').slice(0, 40)}`; }
function txMessage(tx) { return { type: tx.type, from: tx.from ?? null, to: tx.to ?? null, amount: tx.amount ?? 0, nonce: tx.nonce, memo: tx.memo ?? '', ...(tx.fee !== undefined ? { fee: tx.fee } : {}) }; }
function validateTx(tx) {
  if (!tx || typeof tx !== 'object' || tx.type !== 'transfer') fail('Only transfer transactions are accepted');
  if (typeof tx.nonce !== 'string' || tx.nonce.length < 8 || tx.nonce.length > 200) fail('Invalid nonce');
  if (typeof tx.from !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(tx.from)) fail('Invalid sender');
  if (typeof tx.to !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(tx.to)) fail('Invalid recipient');
  amountUnits(tx.amount);
  if (tx.fee !== undefined && String(tx.fee) !== '0' && String(tx.fee) !== '0.0') fail('Fees must be zero');
  if (typeof tx.memo !== 'string' || tx.memo.length > 60) fail('Invalid memo');
}
function balances() { const out = new Map(); for (const block of chain) for (const tx of block.transactions || []) { if (tx.type === 'coinbase') out.set(tx.to, (out.get(tx.to) || 0n) + amountUnits(String(tx.amount))); if (tx.type === 'transfer') { out.set(tx.from, (out.get(tx.from) || 0n) - amountUnits(tx.amount)); out.set(tx.to, (out.get(tx.to) || 0n) + amountUnits(tx.amount)); } } return out; }
function pendingCost(address) { return pending.filter(x => x.from === address).reduce((n, x) => n + amountUnits(x.amount), 0n); }
function coinbaseCount() { return chain.reduce((n, b) => n + (b.transactions || []).filter(x => x.type === 'coinbase').length, 0); }
function reward() { const issued = chain.reduce((n, b) => n + (b.transactions || []).filter(x => x.type === 'coinbase').reduce((m, x) => m + Number(x.amount || 0), 0), 0); const r = INITIAL_REWARD / (2 ** Math.floor(coinbaseCount() / HALVING_INTERVAL)); return Math.max(0, Math.min(r, MAX_SUPPLY - issued)); }
function miningStatus() { const tip = chain.at(-1); const next = tip.index === 0 ? initialAvailableAt : (Number(tip.timestamp) + MINING_INTERVAL_MS); return { ok: true, height: tip.index, next_available_at: next, remaining_ms: Math.max(0, next - Date.now()), ready: Date.now() >= next, interval_minutes: 10, miner_mode: 'single' }; }
async function handle(req, res) {
  if (req.method === 'OPTIONS') return json(res, { ok: true });
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (req.method === 'GET' && url.pathname === '/api/chain') return json(res, { ok: true, chain, pending });
    if (req.method === 'GET' && url.pathname === '/api/mining-status') return json(res, miningStatus());
    if (req.method === 'POST' && url.pathname === '/api/transfer') {
      const { tx } = await readBody(req); validateTx(tx);
      const publicKey = b64(tx.publicKey, 'publicKey'), signature = b64(tx.signature, 'signature');
      if (publicKey.length !== ml_dsa44.lengths.publicKey || signature.length !== ml_dsa44.lengths.signature) fail('Invalid ML-DSA-44 key or signature length');
      if (addressFromPublicKey(publicKey) !== tx.from) fail('Sender does not match public key');
      if (!ml_dsa44.verify(signature, new TextEncoder().encode(JSON.stringify(txMessage(tx))), publicKey)) fail('INVALID_SIGNATURE');
      const bal = balances(); if ((bal.get(tx.from) || 0n) - pendingCost(tx.from) < amountUnits(tx.amount)) fail('INSUFFICIENT_BALANCE');
      if (pending.some(x => x.nonce === tx.nonce)) fail('DUPLICATE_NONCE');
      pending.push(tx); await persist(); return json(res, { ok: true, status: 'pending' });
    }
    if (req.method === 'POST' && url.pathname === '/api/mine') {
      const body = await readBody(req), to = body.to, transactions = body.transactions;
      if (typeof to !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(to)) fail('INVALID_RECIPIENT');
      if (!Array.isArray(transactions) || transactions.some(x => x?.type === 'coinbase')) fail('INVALID_TRANSACTIONS');
      const status = miningStatus(); if (!status.ready) fail('MINING_INTERVAL');
      const r = reward(); if (r <= 0) fail('MAX_SUPPLY');
      for (const tx of transactions) validateTx(tx);
      const currentPending = new Set(pending.map(x => x.nonce)); const accepted = transactions.filter(x => currentPending.has(x.nonce));
      const coinbase = { type: 'coinbase', to, amount: r, schedule: 'halving-v1' };
      const next = chain.at(-1); const block = { index: next.index + 1, prevHash: next.hash, timestamp: Date.now(), transactions: [...accepted, coinbase] };
      block.hash = sha256Hex(JSON.stringify({ index: block.index, prevHash: block.prevHash, timestamp: block.timestamp, transactions: block.transactions }));
      chain.push(block); pending = pending.filter(x => !accepted.some(y => y.nonce === x.nonce)); await persist();
      return json(res, { ok: true, done: true, generated_blocks: 1, target_blocks: 1, height: block.index, block_hash: block.hash, block_text: JSON.stringify(block), miner_mode: 'single', interval_minutes: 10 });
    }
    return json(res, { ok: false, error: 'NOT_FOUND' }, 404);
  } catch (e) { return json(res, { ok: false, error: e?.message || 'INTERNAL_ERROR' }, e?.status || 400); }
}
http.createServer(handle).listen(PORT, '127.0.0.1', () => console.log(`MMC Oracle node listening on 127.0.0.1:${PORT}`));
