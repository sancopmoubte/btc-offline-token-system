-- CatCat Coin MMC: special miner batch cadence.
-- Normal miners: one call every 10 minutes. The exact special address: one call every 1 second.
-- Each special call still creates 10,000 ordinary-reward blocks; no reward multiplier.
create or replace function public.mine_block_locked(
  p_to text,
  p_transactions_text text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tip record;
  next_height integer;
  next_timestamp bigint;
  min_interval bigint := 600000;
  reward numeric;
  coinbase_count bigint;
  batch_count integer := 1;
  i integer;
  coinbase_text text;
  transactions_text text;
  core_text text;
  block_hash text;
  full_text text;
begin
  perform pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1', 0));
  if p_to is null or p_to !~ '^pqc1[A-Za-z0-9_-]+$' then raise exception 'INVALID_RECIPIENT: invalid MMC address'; end if;
  if p_transactions_text is null or json_typeof(p_transactions_text::json) <> 'array' then raise exception 'INVALID_TRANSACTIONS: expected JSON array'; end if;
  if exists (select 1 from json_array_elements(p_transactions_text::json) x where x->>'type' = 'coinbase') then raise exception 'INVALID_TRANSACTIONS: client cannot submit coinbase'; end if;
  select r.height, r.block_hash, (r.block->>'timestamp')::bigint as tip_timestamp into tip from public.chain_blocks_raw as r order by r.height desc limit 1 for update;
  if tip is null then raise exception 'CHAIN_CONFLICT: shared chain has no genesis block'; end if;
  next_height := tip.height + 1;
  next_timestamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  if p_to = 'pqc15e91a92ae40ac6acb449dcd8e079a84ddf2eb1ba' then batch_count := 10000; min_interval := 1000; end if;
  if tip.height > 0 and next_timestamp - tip.tip_timestamp < min_interval then raise exception 'MINING_INTERVAL: next block is not available yet'; end if;
  select count(*) into coinbase_count from public.chain_blocks_raw r, jsonb_array_elements(coalesce(r.block, '{}'::jsonb)->'transactions') tx where tx->>'type' = 'coinbase';
  for i in 1..batch_count loop
    reward := 50 / power(2, floor((coinbase_count + i - 1)::numeric / 210000));
    coinbase_text := '{"type":"coinbase","to":' || to_json(p_to)::text || ',"amount":' || to_json(reward::float8)::text || ',"schedule":"halving-v1"}';
    if i = 1 and p_transactions_text <> '[]' then transactions_text := rtrim(p_transactions_text, ']') || ',' || coinbase_text || ']'; else transactions_text := '[' || coinbase_text || ']'; end if;
    core_text := '{"index":' || next_height::text || ',"prevHash":' || to_json(tip.block_hash)::text || ',"timestamp":' || next_timestamp::text || ',"transactions":' || transactions_text || '}';
    block_hash := encode(extensions.digest(convert_to(core_text, 'UTF8'), 'sha256'), 'hex');
    full_text := left(core_text, length(core_text) - 1) || ',"hash":' || to_json(block_hash)::text || '}';
    insert into public.chain_blocks_raw (height, block_hash, prev_hash, block_text, block) values (next_height, block_hash, tip.block_hash, full_text, full_text::jsonb);
    tip.height := next_height; tip.block_hash := block_hash; next_height := next_height + 1;
  end loop;
  return jsonb_build_object('ok', true, 'batch_count', batch_count, 'height', next_height - 1, 'block_hash', tip.block_hash);
exception when unique_violation then raise exception 'CHAIN_CONFLICT: another miner already appended this height';
end;
$$;
revoke all on function public.mine_block_locked(text, text) from public;
grant execute on function public.mine_block_locked(text, text) to anon, authenticated;
