-- 猫猫币 MMC：服务端权威出块
-- 客户端只提交收款地址和待打包交易；高度、时间、coinbase、区块正文和哈希全部由数据库生成。
-- 不修改任何已有区块，只允许通过本函数追加下一个区块。

create extension if not exists pgcrypto;

create or replace function public.mine_block_locked(
  p_to text,
  p_transactions json
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
begin
  perform pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1', 0));

  if p_to is null or p_to !~ '^pqc1[A-Za-z0-9_-]+$' then
    raise exception 'INVALID_RECIPIENT: invalid MMC address';
  end if;
  if p_transactions is null or json_typeof(p_transactions) <> 'array' then
    raise exception 'INVALID_TRANSACTIONS: expected JSON array';
  end if;
  if exists (select 1 from json_array_elements(p_transactions) x where x->>'type' = 'coinbase') then
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
  next_timestamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  select 50 / power(2, floor(count(*)::numeric / 210000)) into reward
    from public.chain_blocks_raw r,
         jsonb_array_elements(coalesce(r.block, '{}'::jsonb)->'transactions') tx
   where tx->>'type' = 'coinbase';
  reward := coalesce(reward, 50);

  -- 使用 float8 输出与浏览器 JSON.stringify 一致的金额格式（50，而不是 50.0000000000000000）。
  coinbase_text := '{"type":"coinbase","to":' || to_json(p_to)::text
    || ',"amount":' || to_json(reward::float8)::text
    || ',"schedule":"halving-v1"}';
  if p_transactions::text = '[]' then
    transactions_text := '[' || coinbase_text || ']';
  else
    transactions_text := rtrim(p_transactions::text, ']') || ',' || coinbase_text || ']';
  end if;

  core_text := '{"index":' || next_height::text
    || ',"prevHash":' || to_json(tip.block_hash)::text
    || ',"timestamp":' || next_timestamp::text
    || ',"transactions":' || transactions_text || '}';
  block_hash := encode(extensions.digest(convert_to(core_text, 'UTF8'), 'sha256'), 'hex');
  full_text := left(core_text, length(core_text) - 1) || ',"hash":' || to_json(block_hash)::text || '}';

  insert into public.chain_blocks_raw
    (height, block_hash, prev_hash, block_text, block)
  values
    (next_height, block_hash, tip.block_hash, full_text, full_text::jsonb);

  select r.height, r.block_hash, r.prev_hash, r.block_text
    into saved
    from public.chain_blocks_raw as r
   where r.height = next_height;

  return jsonb_build_object(
    'ok', true,
    'height', saved.height,
    'block_hash', saved.block_hash,
    'prev_hash', saved.prev_hash,
    'block_text', saved.block_text
  );
exception
  when unique_violation then
    raise exception 'CHAIN_CONFLICT: another miner already appended this height';
end;
$$;

revoke all on function public.mine_block_locked(text, json) from public;
grant execute on function public.mine_block_locked(text, json) to anon, authenticated;

-- 新版客户端只能通过服务端权威函数出块；历史数据不受影响。
revoke insert on public.chain_blocks_raw from anon, authenticated;
