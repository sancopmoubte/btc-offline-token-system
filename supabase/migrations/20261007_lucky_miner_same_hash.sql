-- MMC 幸运矿工：只改变服务端出块资格，不改变区块正文或哈希格式。
-- 历史区块完全不动；单矿工 100% 放行，多矿工按确定性幸运值选择。
create table if not exists public.mmc_miners (
  address text primary key,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

-- 当前链上唯一出块地址作为初始唯一矿工。
insert into public.mmc_miners(address, enabled)
values ('pqc15e91a92ae40ac6acb449dcd8e079a84ddf2eb1ba', true)
on conflict (address) do update set enabled = true;

alter table public.mmc_miners enable row level security;
revoke all on public.mmc_miners from anon, authenticated;

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
  reward numeric;
  coinbase_text text;
  transactions_text text;
  core_text text;
  block_hash text;
  full_text text;
  saved record;
  miner_count integer;
  lucky_address text;
begin
  perform pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1', 0));
  if p_to is null or p_to !~ '^pqc1[A-Za-z0-9_-]+$' then
    raise exception 'INVALID_RECIPIENT: invalid MMC address';
  end if;
  if p_transactions_text is null or json_typeof(p_transactions_text::json) <> 'array' then
    raise exception 'INVALID_TRANSACTIONS: expected JSON array';
  end if;
  if exists (select 1 from json_array_elements(p_transactions_text::json) x where x->>'type' = 'coinbase') then
    raise exception 'INVALID_TRANSACTIONS: client cannot submit coinbase';
  end if;

  select r.height, r.block_hash into tip
    from public.chain_blocks_raw as r
   order by r.height desc
   limit 1
   for update;
  if tip is null then
    raise exception 'CHAIN_CONFLICT: shared chain has no genesis block';
  end if;
  next_height := tip.height + 1;

  select count(*)::integer into miner_count
    from public.mmc_miners
   where enabled = true;
  if not exists (select 1 from public.mmc_miners where address = p_to and enabled = true) then
    raise exception 'MINER_NOT_REGISTERED: miner address is not registered';
  end if;
  if miner_count > 1 then
    select m.address into lucky_address
      from public.mmc_miners as m
     where m.enabled = true
     order by encode(extensions.digest(convert_to(tip.block_hash || ':' || next_height::text || ':' || m.address, 'UTF8'), 'sha256'), 'hex'), m.address
     limit 1;
    if p_to <> lucky_address then
      raise exception 'LUCKY_MINER_MISS: another registered miner won this height';
    end if;
  end if;

  next_timestamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  select 50 / power(2, floor(count(*)::numeric / 210000)) into reward
    from public.chain_blocks_raw r,
         jsonb_array_elements(coalesce(r.block, '{}'::jsonb)->'transactions') tx
   where tx->>'type' = 'coinbase';
  reward := coalesce(reward, 50);
  coinbase_text := '{"type":"coinbase","to":' || to_json(p_to)::text
    || ',"amount":' || to_json(reward::float8)::text
    || ',"schedule":"halving-v1"}';
  if p_transactions_text = '[]' then
    transactions_text := '[' || coinbase_text || ']';
  else
    transactions_text := rtrim(p_transactions_text, ']') || ',' || coinbase_text || ']';
  end if;
  core_text := '{"index":' || next_height::text
    || ',"prevHash":' || to_json(tip.block_hash)::text
    || ',"timestamp":' || next_timestamp::text
    || ',"transactions":' || transactions_text || '}';
  block_hash := encode(extensions.digest(convert_to(core_text, 'UTF8'), 'sha256'), 'hex');
  full_text := left(core_text, length(core_text) - 1) || ',"hash":' || to_json(block_hash)::text || '}';
  insert into public.chain_blocks_raw(height, block_hash, prev_hash, block_text, block)
  values (next_height, block_hash, tip.block_hash, full_text, full_text::jsonb);
  select r.height, r.block_hash, r.prev_hash, r.block_text into saved
    from public.chain_blocks_raw as r where r.height = next_height;
  return jsonb_build_object('ok', true, 'height', saved.height, 'block_hash', saved.block_hash, 'prev_hash', saved.prev_hash, 'block_text', saved.block_text);
exception
  when unique_violation then
    raise exception 'CHAIN_CONFLICT: another miner already appended this height';
end;
$$;
revoke all on function public.mine_block_locked(text, text) from public;
grant execute on function public.mine_block_locked(text, text) to anon, authenticated;
drop function if exists public.mine_block_locked(text, json);
revoke insert on public.chain_blocks_raw from anon, authenticated;
