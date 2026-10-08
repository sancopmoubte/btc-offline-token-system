-- New miners must register before eligibility and wait a full 8 hours.
-- The server stores eligible_at per address and round_height.
-- mine_block_locked only considers enabled miners whose eligible_at has passed;
-- a late or unregistered address cannot alter the round or mine immediately.
ALTER TABLE public.mmc_miners ADD COLUMN IF NOT EXISTS eligible_at timestamptz;
