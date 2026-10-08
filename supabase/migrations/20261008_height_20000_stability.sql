-- Stability fixes before height 20,000.
-- Existing blocks are not rewritten.
ALTER TABLE public.mmc_miners ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;
ALTER TABLE public.mmc_miners ADD COLUMN IF NOT EXISTS last_seen_height bigint;
UPDATE public.mmc_miners SET enabled=false;

-- Active miner registrations expire after two block intervals. A miner is
-- registered only after the server accepts its time-window request.
CREATE OR REPLACE FUNCTION public.mine_block_locked(p_to text, p_transactions_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  tip record; next_height integer; next_timestamp bigint; coinbase_count bigint;
  reward numeric; coinbase_text text; transactions_text text; core_text text;
  block_hash text; full_text text; supply numeric; initial_at timestamptz;
  next_at timestamptz; miner_count integer; winner text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1', 0));
  IF p_to IS NULL OR p_to !~ '^pqc1[A-Za-z0-9_-]+$' THEN RAISE EXCEPTION 'INVALID_RECIPIENT: invalid MMC address'; END IF;
  IF p_transactions_text IS NULL OR json_typeof(p_transactions_text::json) <> 'array' THEN RAISE EXCEPTION 'INVALID_TRANSACTIONS: expected JSON array'; END IF;
  IF EXISTS (SELECT 1 FROM json_array_elements(p_transactions_text::json) x WHERE x->>'type'='coinbase') THEN RAISE EXCEPTION 'INVALID_TRANSACTIONS: client cannot submit coinbase'; END IF;
  SELECT r.height,r.block_hash,(r.block->>'timestamp')::bigint AS tip_timestamp INTO tip FROM public.chain_blocks_raw r ORDER BY r.height DESC LIMIT 1 FOR UPDATE;
  IF tip IS NULL THEN RAISE EXCEPTION 'CHAIN_CONFLICT: shared chain has no genesis block'; END IF;
  next_height:=tip.height+1; next_timestamp:=floor(extract(epoch FROM clock_timestamp())*1000)::bigint;
  IF tip.height=0 THEN SELECT initial_available_at INTO initial_at FROM public.mmc_mining_schedule WHERE id=1; next_at:=initial_at; ELSE next_at:=to_timestamp(tip.tip_timestamp/1000.0)+interval '10 minutes'; END IF;
  IF clock_timestamp()<next_at THEN RAISE EXCEPTION 'MINING_INTERVAL: next block is not available yet'; END IF;

  UPDATE public.mmc_miners SET enabled=false WHERE enabled=true AND (last_seen_at IS NULL OR last_seen_at < clock_timestamp()-interval '20 minutes');
  INSERT INTO public.mmc_miners(address,enabled,last_seen_at,last_seen_height) VALUES(p_to,true,clock_timestamp(),next_height)
    ON CONFLICT(address) DO UPDATE SET enabled=true,last_seen_at=EXCLUDED.last_seen_at,last_seen_height=EXCLUDED.last_seen_height;
  SELECT count(*) INTO miner_count FROM public.mmc_miners WHERE enabled=true;
  SELECT m.address INTO winner FROM public.mmc_miners m WHERE m.enabled=true
    ORDER BY encode(extensions.digest(convert_to(tip.block_hash||':'||next_height::text||':'||m.address,'UTF8'),'sha256'),'hex') ASC,m.address ASC LIMIT 1;
  IF miner_count>1 AND winner<>p_to THEN RAISE EXCEPTION 'LUCKY_MINER_NOT_SELECTED: selected miner is %',winner; END IF;

  SELECT count(*) INTO coinbase_count FROM public.chain_blocks_raw r,jsonb_array_elements(COALESCE(r.block,'{}'::jsonb)->'transactions') tx WHERE tx->>'type'='coinbase';
  reward:=50/power(2,floor(coinbase_count::numeric/210000));
  IF reward<=0 THEN RAISE EXCEPTION 'MAX_SUPPLY: issuance complete'; END IF;
  SELECT COALESCE(sum((tx->>'amount')::numeric),0) INTO supply FROM public.chain_blocks_raw r,jsonb_array_elements(COALESCE(r.block,'{}'::jsonb)->'transactions') tx WHERE tx->>'type'='coinbase';
  IF supply+reward>21000000 THEN reward:=21000000-supply; END IF;
  IF reward<=0 THEN RAISE EXCEPTION 'MAX_SUPPLY: issuance complete'; END IF;
  coinbase_text:='{"type":"coinbase","to":'||to_json(p_to)::text||',"amount":'||to_json(reward::float8)::text||',"schedule":"halving-v1"}';
  IF p_transactions_text='[]' THEN transactions_text:='['||coinbase_text||']'; ELSE transactions_text:=rtrim(p_transactions_text,']')||','||coinbase_text||']'; END IF;
  core_text:='{"index":'||next_height::text||',"prevHash":'||to_json(tip.block_hash)::text||',"timestamp":'||next_timestamp::text||',"transactions":'||transactions_text||'}';
  block_hash:=encode(extensions.digest(convert_to(core_text,'UTF8'),'sha256'),'hex');
  full_text:=left(core_text,length(core_text)-1)||',"hash":'||to_json(block_hash)::text||'}';
  INSERT INTO public.chain_blocks_raw(height,block_hash,prev_hash,block_text,block) VALUES(next_height,block_hash,tip.block_hash,full_text,full_text::jsonb);
  RETURN jsonb_build_object('ok',true,'batch_count',1,'generated_blocks',1,'target_blocks',1,'done',true,'height',next_height,'block_hash',block_hash,'block_text',full_text,'lucky_miner_count',miner_count,'lucky_miner',winner);
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'CHAIN_CONFLICT: another miner already appended this height';
END; $$;
REVOKE ALL ON FUNCTION public.mine_block_locked(text,text) FROM public;
GRANT EXECUTE ON FUNCTION public.mine_block_locked(text,text) TO anon,authenticated;
