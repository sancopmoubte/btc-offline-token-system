-- Enforce the first block delay as well as the normal 10-minute interval.
CREATE TABLE IF NOT EXISTS public.mmc_mining_schedule (id integer PRIMARY KEY, initial_available_at timestamptz NOT NULL);
INSERT INTO public.mmc_mining_schedule (id, initial_available_at) VALUES (1, clock_timestamp() + interval '10 minutes') ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.mmc_mining_schedule ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mmc_mining_schedule FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_mining_status()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tip record; initial_at timestamptz; next_at timestamptz;
BEGIN
  SELECT initial_available_at INTO initial_at FROM public.mmc_mining_schedule WHERE id=1;
  SELECT r.height, (r.block->>'timestamp')::bigint AS tip_timestamp INTO tip FROM public.chain_blocks_raw r ORDER BY r.height DESC LIMIT 1;
  IF tip IS NULL THEN RETURN jsonb_build_object('ok',false,'error','CHAIN_EMPTY'); END IF;
  IF tip.height=0 THEN next_at := initial_at; ELSE next_at := to_timestamp(tip.tip_timestamp / 1000.0) + interval '10 minutes'; END IF;
  RETURN jsonb_build_object('ok',true,'height',tip.height,'next_available_at',extract(epoch FROM next_at)*1000,'remaining_ms',GREATEST(0,extract(epoch FROM (next_at-clock_timestamp()))*1000),'ready',clock_timestamp() >= next_at);
END; $$;
REVOKE ALL ON FUNCTION public.get_mining_status() FROM public;
GRANT EXECUTE ON FUNCTION public.get_mining_status() TO anon, authenticated;

-- The deployed function mine_block_locked uses the same schedule and rejects
-- every request before next_at, including the first request after genesis.
