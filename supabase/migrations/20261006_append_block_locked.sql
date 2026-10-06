-- 猫猫币 MMC：原子出块锁
-- 只负责串行化“检查当前 tip + 写入下一个区块”，不会修改任何已有区块。
-- 部署后前端通过 supabase.rpc('append_block_locked', ...) 调用。

create or replace function public.append_block_locked(
  p_height integer,
  p_block_hash text,
  p_prev_hash text,
  p_block_text text,
  p_block jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tip record;
  saved record;
begin
  -- 同一条链的所有调用共用一个事务级锁；事务结束自动释放。
  perform pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1', 0));

  select height, block_hash
    into tip
    from public.chain_blocks_raw
   order by height desc
   limit 1
   for update;

  if tip is null then
    if p_height <> 0 then
      raise exception 'CHAIN_CONFLICT: empty chain requires height 0';
    end if;
  elsif p_height <> tip.height + 1 or p_prev_hash <> tip.block_hash then
    raise exception 'CHAIN_CONFLICT: expected height %, prev_hash %', tip.height + 1, tip.block_hash;
  end if;

  insert into public.chain_blocks_raw
    (height, block_hash, prev_hash, block_text, block)
  values
    (p_height, p_block_hash, p_prev_hash, p_block_text, p_block);

  select height, block_hash, prev_hash
    into saved
    from public.chain_blocks_raw
   where height = p_height;

  return jsonb_build_object(
    'ok', true,
    'height', saved.height,
    'block_hash', saved.block_hash,
    'prev_hash', saved.prev_hash
  );
exception
  when unique_violation then
    -- 幂等保护：同一哈希重复提交视为成功，不同哈希仍视为冲突。
    select height, block_hash, prev_hash
      into saved
      from public.chain_blocks_raw
     where height = p_height;
    if saved.block_hash = p_block_hash then
      return jsonb_build_object(
        'ok', true,
        'height', saved.height,
        'block_hash', saved.block_hash,
        'prev_hash', saved.prev_hash,
        'idempotent', true
      );
    end if;
    raise exception 'CHAIN_CONFLICT: height % already contains another hash', p_height;
end;
$$;

revoke all on function public.append_block_locked(integer, text, text, text, jsonb) from public;
grant execute on function public.append_block_locked(integer, text, text, text, jsonb) to anon, authenticated;
