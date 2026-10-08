-- Fair lucky-miner rounds.
-- Miners pre-register for the next block round. Selection is deterministic,
-- and exactly one address receives the block reward.
ALTER TABLE public.mmc_miners ADD COLUMN IF NOT EXISTS round_height bigint;
UPDATE public.mmc_miners SET enabled=false, round_height=NULL;

-- register_miner(p_address) records an address for current_tip + 1 before the
-- 8-hour window opens. mine_block_locked selects only this round_height.
-- Old addresses from previous rounds cannot affect the next round.
