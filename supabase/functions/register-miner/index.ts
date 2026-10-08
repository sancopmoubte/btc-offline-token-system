import { createClient } from 'npm:@supabase/supabase-js@2.49.8';
import { ml_dsa44 } from 'npm:@noble/post-quantum@0.7.1/ml-dsa.js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new Error('Missing Supabase environment variables');
const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const enc = new TextEncoder();
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const DOMAIN = 'catcat-mmc-miner-registration-v1';

function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } }); }
function canonical(value: unknown) { return JSON.stringify(value); }
function b64(value: unknown, field: string): Uint8Array { if (typeof value !== 'string' || !value) throw new Error(`${field} is required`); try { return Uint8Array.from(atob(value), c => c.charCodeAt(0)); } catch { throw new Error(`${field} is not valid base64`); } }
async function addressFromPublicKey(publicKey: Uint8Array) { const digest = await crypto.subtle.digest('SHA-256', publicKey.buffer as ArrayBuffer); const hex = Array.from(new Uint8Array(digest), x => x.toString(16).padStart(2, '0')).join(''); return `pqc1${hex.slice(0, 40)}`; }
function challengeMessage(x: { challengeId: string; challenge: string; address: string; publicKey: string }) { return { domain: DOMAIN, challengeId: x.challengeId, challenge: x.challenge, address: x.address, publicKey: x.publicKey }; }
function validateAddress(address: unknown) { if (typeof address !== 'string' || !/^pqc1[A-Za-z0-9_-]+$/.test(address)) throw new Error('Invalid miner address'); }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'METHOD_NOT_ALLOWED' }, 405);
  try {
    const body = await req.json();
    const action = body?.action;
    if (action === 'challenge') {
      const publicKeyBytes = b64(body.publicKey, 'publicKey');
      if (publicKeyBytes.length !== ml_dsa44.lengths.publicKey) throw new Error('Invalid ML-DSA-44 public key length');
      const address = await addressFromPublicKey(publicKeyBytes);
      if (body.address && body.address !== address) throw new Error('Address does not match public key');
      const challengeId = crypto.randomUUID();
      const challenge = b64ToBase64Url(crypto.getRandomValues(new Uint8Array(32)));
      const { data, error } = await db.rpc('create_miner_challenge', { p_challenge_id: challengeId, p_address: address, p_public_key: body.publicKey, p_challenge: challenge });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, ...data, challengeId, challenge, address, domain: DOMAIN });
    }
    if (action !== 'register') throw new Error('action must be challenge or register');
    const publicKeyBytes = b64(body.publicKey, 'publicKey');
    const signature = b64(body.signature, 'signature');
    validateAddress(body.address);
    if (publicKeyBytes.length !== ml_dsa44.lengths.publicKey) throw new Error('Invalid ML-DSA-44 public key length');
    if (signature.length !== ml_dsa44.lengths.signature) throw new Error('Invalid ML-DSA-44 signature length');
    const derivedAddress = await addressFromPublicKey(publicKeyBytes);
    if (derivedAddress !== body.address) throw new Error('Address does not match public key');
    const { data: challengeRow, error: challengeError } = await db.rpc('get_miner_challenge_for_verification', { p_challenge_id: body.challengeId });
    if (challengeError || !challengeRow?.ok) throw new Error(challengeError?.message || 'Challenge not found');
    if (challengeRow.address !== body.address || challengeRow.public_key !== body.publicKey) throw new Error('Challenge identity mismatch');
    const message = challengeMessage({ challengeId: body.challengeId, challenge: challengeRow.challenge, address: body.address, publicKey: body.publicKey });
    if (!ml_dsa44.verify(signature, enc.encode(canonical(message)), publicKeyBytes)) return json({ ok: false, error: 'INVALID_MINER_SIGNATURE' }, 400);
    const { data, error } = await db.rpc('register_verified_miner', { p_challenge_id: body.challengeId, p_address: body.address, p_public_key: body.publicKey });
    if (error) return json({ ok: false, error: error.message }, 400);
    return json(data ?? { ok: true });
  } catch (error) { return json({ ok: false, error: error instanceof Error ? error.message : 'INVALID_REQUEST' }, 400); }
});

function b64ToBase64Url(bytes: Uint8Array) { return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, ''); }
