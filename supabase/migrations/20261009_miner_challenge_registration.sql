CREATE TABLE IF NOT EXISTS public.miner_challenges (
  challenge_id uuid PRIMARY KEY,
  address text NOT NULL,
  public_key text NOT NULL,
  challenge text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '5 minutes'),
  used_at timestamptz
);
CREATE INDEX IF NOT EXISTS miner_challenges_expiry_idx ON public.miner_challenges(expires_at);
ALTER TABLE public.miner_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.miner_challenges FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_miner_challenge(p_challenge_id uuid, p_address text, p_public_key text, p_challenge text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF COALESCE(auth.role(),'') <> 'service_role' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  DELETE FROM public.miner_challenges WHERE expires_at < clock_timestamp() OR used_at IS NOT NULL;
  INSERT INTO public.miner_challenges(challenge_id,address,public_key,challenge)
  VALUES(p_challenge_id,p_address,p_public_key,p_challenge);
  RETURN jsonb_build_object('ok',true,'expires_at',extract(epoch FROM(clock_timestamp()+interval '5 minutes'))*1000);
END; $$;
REVOKE ALL ON FUNCTION public.create_miner_challenge(uuid,text,text,text) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_miner_challenge(uuid,text,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.get_miner_challenge_for_verification(p_challenge_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r record;
BEGIN
  IF COALESCE(auth.role(),'') <> 'service_role' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT address,public_key,challenge,expires_at,used_at INTO r FROM public.miner_challenges WHERE challenge_id=p_challenge_id FOR UPDATE;
  IF r IS NULL OR r.used_at IS NOT NULL OR r.expires_at <= clock_timestamp() THEN RAISE EXCEPTION 'CHALLENGE_EXPIRED_OR_USED'; END IF;
  RETURN jsonb_build_object('ok',true,'address',r.address,'public_key',r.public_key,'challenge',r.challenge,'expires_at',extract(epoch FROM r.expires_at)*1000);
END; $$;
REVOKE ALL ON FUNCTION public.get_miner_challenge_for_verification(uuid) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_miner_challenge_for_verification(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.register_verified_miner(p_challenge_id uuid, p_address text, p_public_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r record; tip record; next_height bigint; eligible timestamptz; participant_count integer;
BEGIN
  IF COALESCE(auth.role(),'') <> 'service_role' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('catcat-mmc-chain-v1',0));
  SELECT address,public_key,challenge,expires_at,used_at INTO r FROM public.miner_challenges WHERE challenge_id=p_challenge_id FOR UPDATE;
  IF r IS NULL OR r.used_at IS NOT NULL OR r.expires_at <= clock_timestamp() THEN RAISE EXCEPTION 'CHALLENGE_EXPIRED_OR_USED'; END IF;
  IF r.address<>p_address OR r.public_key<>p_public_key THEN RAISE EXCEPTION 'CHALLENGE_IDENTITY_MISMATCH'; END IF;
  SELECT height INTO tip FROM public.chain_blocks_raw ORDER BY height DESC LIMIT 1;
  IF tip IS NULL THEN RAISE EXCEPTION 'CHAIN_CONFLICT: shared chain has no genesis block'; END IF;
  next_height:=tip.height+1; eligible:=clock_timestamp()+interval '8 hours';
  INSERT INTO public.mmc_miners(address,enabled,last_seen_at,last_seen_height,round_height,eligible_at)
  VALUES(p_address,true,clock_timestamp(),next_height,next_height,eligible)
  ON CONFLICT(address) DO UPDATE SET enabled=true,last_seen_at=EXCLUDED.last_seen_at,last_seen_height=EXCLUDED.last_seen_height,round_height=EXCLUDED.round_height,eligible_at=CASE WHEN public.mmc_miners.round_height=EXCLUDED.round_height THEN public.mmc_miners.eligible_at ELSE EXCLUDED.eligible_at END;
  UPDATE public.miner_challenges SET used_at=clock_timestamp() WHERE challenge_id=p_challenge_id;
  SELECT count(*) INTO participant_count FROM public.mmc_miners WHERE enabled=true AND round_height=next_height AND eligible_at<=clock_timestamp();
  SELECT eligible_at INTO eligible FROM public.mmc_miners WHERE address=p_address;
  RETURN jsonb_build_object('ok',true,'round_height',next_height,'participant_count',participant_count,'eligible_at',extract(epoch FROM eligible)*1000,'remaining_ms',GREATEST(0,extract(epoch FROM(eligible-clock_timestamp()))*1000));
END; $$;
REVOKE ALL ON FUNCTION public.register_verified_miner(uuid,text,text) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.register_verified_miner(uuid,text,text) TO service_role;

REVOKE ALL ON FUNCTION public.register_miner(text) FROM public,anon,authenticated;
