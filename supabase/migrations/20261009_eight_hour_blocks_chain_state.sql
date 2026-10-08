-- Switch future blocks to an 8-hour interval without changing existing blocks.
-- Existing block timestamps and hashes remain untouched.
CREATE TABLE IF NOT EXISTS public.chain_state (
  id integer PRIMARY KEY,
  height bigint NOT NULL,
  block_hash text NOT NULL,
  block_timestamp bigint NOT NULL,
  coinbase_count bigint NOT NULL,
  total_supply numeric NOT NULL,
  state_hash text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chain_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chain_state FROM anon, authenticated;

-- The deployed get_mining_status and mine_block_locked functions now use:
-- next block time = previous block timestamp + interval '8 hours'
-- stale miner expiry = 16 hours
-- chain_state is updated in the same transaction as each new block.
