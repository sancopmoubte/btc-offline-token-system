-- Lucky miner consensus for MMC.
-- Legacy miner registrations are disabled; each address is re-enabled when it
-- submits a mining request. One enabled miner is always selected (100%).
UPDATE public.mmc_miners SET enabled=false WHERE enabled=true;

-- The deployed public.mine_block_locked implementation:
-- 1. takes the chain advisory lock;
-- 2. registers p_to as an enabled miner;
-- 3. counts enabled miners;
-- 4. if count=1, accepts p_to with 100% eligibility;
-- 5. if count>1, selects the enabled address with the smallest
--    SHA-256(tip_hash || ':' || next_height || ':' || address),
--    with address as deterministic tie-breaker;
-- 6. rejects non-selected callers without writing a block.
-- Block payloads do not contain a lucky-miner field, so the rule does not
-- alter already committed block hashes.
