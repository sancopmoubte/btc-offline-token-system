-- Revoke direct public mutation of consensus and pending tables.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.chain_blocks_raw FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.pending_transactions FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.mmc_miners FROM anon, authenticated;

-- The deployed submit_verified_pending_transaction function also takes the
-- chain advisory lock before its balance + pending + nonce check and insert.
