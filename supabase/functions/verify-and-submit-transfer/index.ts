import { createClient } from 'npm:@supabase/supabase-js@2.49.8';
import { ml_dsa44 } from 'npm:@noble/post-quantum@0.7.1/ml-dsa.js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new Error('Missing Supabase environment variables');

const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const enc = new TextEncoder();
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

function canonical(value: unknown): string {
  // This must remain JSON.stringify: it matches index.html message(tx).
  return JSON.stringify(value);
}

function decodeBase64(value: unknown, field: string): Uint8Array {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${field} is required`);
  try {
    return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
  } catch {
    throw new Error(`${field} is not valid base64`);
  }
}

async function addressFromPublicKey(publicKey: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', publicKey.buffer as ArrayBuffer);
  const hex = Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, '0')).join('');
  return `pqc1${hex.slice(0, 40)}`;
}

function validateShape(tx: Record<string, unknown>) {
  if (tx.type !== 'transfer') throw new Error('Only transfer transactions are accepted');
  if (typeof tx.nonce !== 'string' || tx.nonce.length < 8 || tx.nonce.length > 200) throw new Error('Invalid nonce');
  if (typeof tx.from !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(tx.from)) throw new Error('Invalid sender');
  if (typeof tx.to !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(tx.to)) throw new Error('Invalid recipient');
  if (typeof tx.amount !== 'string' || !/^\d+(?:\.\d{1,8})?$/.test(tx.amount) || Number(tx.amount) <= 0) throw new Error('Invalid amount');
  if (tx.fee !== undefined && String(tx.fee) !== '0' && String(tx.fee) !== '0.0') throw new Error('Fees must be zero');
  if (typeof tx.memo !== 'string' || tx.memo.length > 60) throw new Error('Invalid memo');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'METHOD_NOT_ALLOWED' }, 405);

  try {
    const body = await req.json();
    const tx = body?.tx as Record<string, unknown>;
    if (!tx || typeof tx !== 'object' || Array.isArray(tx)) throw new Error('tx object is required');
    validateShape(tx);

    const publicKey = decodeBase64(tx.publicKey, 'publicKey');
    const signature = decodeBase64(tx.signature, 'signature');
    if (publicKey.length !== ml_dsa44.lengths.publicKey) throw new Error('Invalid ML-DSA-44 public key length');
    if (signature.length !== ml_dsa44.lengths.signature) throw new Error('Invalid ML-DSA-44 signature length');

    const derivedAddress = await addressFromPublicKey(publicKey);
    if (derivedAddress !== tx.from) throw new Error('Sender does not match public key');

    const message = {
      type: tx.type,
      from: tx.from ?? null,
      to: tx.to ?? null,
      amount: tx.amount ?? 0,
      nonce: tx.nonce,
      memo: tx.memo ?? '',
      ...(tx.fee !== undefined ? { fee: tx.fee } : {}),
    };
    const valid = ml_dsa44.verify(signature, enc.encode(canonical(message)), publicKey);
    if (!valid) return json({ ok: false, error: 'INVALID_SIGNATURE' }, 400);

    // The service-role-only SQL function performs nonce and current-balance checks
    // atomically with insertion into the pending pool.
    const { data, error } = await db.rpc('submit_verified_pending_transaction', { p_tx: tx });
    if (error) return json({ ok: false, error: error.message }, 400);
    return json(data ?? { ok: true, status: 'pending' });
  } catch (error) {
    return json({ ok: false, error: error instanceof Error ? error.message : 'INVALID_REQUEST' }, 400);
  }
});
