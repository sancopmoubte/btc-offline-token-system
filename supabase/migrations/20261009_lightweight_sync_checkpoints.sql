-- Safe sync acceleration foundation. Historical blocks remain unchanged.
CREATE TABLE IF NOT EXISTS public.chain_checkpoints (
  height bigint PRIMARY KEY,
  block_hash text NOT NULL,
  balances jsonb NOT NULL DEFAULT '{}'::jsonb,
  state_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chain_checkpoints ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chain_checkpoints FROM anon, authenticated;
INSERT INTO public.chain_checkpoints(height, block_hash, balances, state_hash)
SELECT 0, block_hash, '{}'::jsonb,
       encode(extensions.digest(convert_to('{}','UTF8'),'sha256'),'hex')
FROM public.chain_blocks_raw WHERE height=0 ON CONFLICT (height) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_chain_tip()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('ok',true,'height',height,'block_hash',block_hash,'prev_hash',prev_hash,'created_at',created_at)
     FROM public.chain_blocks_raw ORDER BY height DESC LIMIT 1),
    jsonb_build_object('ok',false,'error','CHAIN_EMPTY'));
$$;
REVOKE ALL ON FUNCTION public.get_chain_tip() FROM public;
GRANT EXECUTE ON FUNCTION public.get_chain_tip() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_latest_checkpoint()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('ok',true,'height',height,'block_hash',block_hash,'balances',balances,'state_hash',state_hash,'created_at',created_at)
     FROM public.chain_checkpoints ORDER BY height DESC LIMIT 1),
    jsonb_build_object('ok',false,'error','CHECKPOINT_EMPTY'));
$$;
REVOKE ALL ON FUNCTION public.get_latest_checkpoint() FROM public;
GRANT EXECUTE ON FUNCTION public.get_latest_checkpoint() TO anon, authenticated;
