-- Keep the resumable one-time batch progress private to the SECURITY DEFINER RPC.
ALTER TABLE public.mmc_special_batch_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.mmc_special_batch_state FROM anon, authenticated;
