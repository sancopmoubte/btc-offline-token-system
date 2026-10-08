CREATE OR REPLACE FUNCTION public.submit_verified_pending_transaction(p_tx jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n text;
  sender text;
  amount numeric;
  balance numeric;
  existing jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'FORBIDDEN: Edge Function verification required';
  END IF;
  IF p_tx IS NULL OR p_tx->>'type' <> 'transfer' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: transfer required';
  END IF;
  n := p_tx->>'nonce';
  sender := p_tx->>'from';
  IF n IS NULL OR length(n) < 8 OR length(n) > 200 THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: nonce required';
  END IF;
  IF sender IS NULL OR sender !~ '^pqc1[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: invalid sender';
  END IF;
  IF p_tx->>'to' IS NULL OR p_tx->>'to' !~ '^pqc1[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: invalid recipient';
  END IF;
  IF p_tx->>'amount' IS NULL OR p_tx->>'amount' !~ '^([0-9]+)(\.[0-9]{1,8})?$' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: invalid amount';
  END IF;
  amount := (p_tx->>'amount')::numeric;
  IF amount <= 0 THEN RAISE EXCEPTION 'INVALID_TRANSACTION: amount must be positive'; END IF;
  IF p_tx ? 'fee' AND COALESCE((p_tx->>'fee')::numeric, 0) <> 0 THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: fee must be zero';
  END IF;
  IF COALESCE(p_tx->>'publicKey','') = '' OR COALESCE(p_tx->>'signature','') = '' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: verified key and signature required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.chain_blocks_raw r,
      jsonb_array_elements(COALESCE(r.block->'transactions','[]'::jsonb)) tx
    WHERE tx->>'nonce' = n
  ) THEN
    RETURN jsonb_build_object('ok', true, 'status', 'already_confirmed', 'nonce', n);
  END IF;
  SELECT tx INTO existing FROM public.pending_transactions WHERE nonce = n LIMIT 1;
  IF existing IS NOT NULL THEN
    IF existing = p_tx THEN
      RETURN jsonb_build_object('ok', true, 'status', 'already_pending', 'nonce', n);
    END IF;
    RAISE EXCEPTION 'INVALID_TRANSACTION: nonce already used';
  END IF;

  SELECT COALESCE(sum(CASE
    WHEN tx->>'type' = 'coinbase' AND tx->>'to' = sender THEN (tx->>'amount')::numeric
    WHEN tx->>'type' = 'transfer' AND tx->>'to' = sender THEN (tx->>'amount')::numeric
    WHEN tx->>'type' = 'transfer' AND tx->>'from' = sender THEN -((tx->>'amount')::numeric)
    ELSE 0 END), 0)
  INTO balance
  FROM public.chain_blocks_raw r,
    jsonb_array_elements(COALESCE(r.block->'transactions','[]'::jsonb)) tx;

  SELECT balance - COALESCE(sum((tx->>'amount')::numeric), 0)
  INTO balance
  FROM public.pending_transactions p
  WHERE p.status = 'pending' AND p.tx->>'from' = sender;
  IF balance < amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: available balance is insufficient';
  END IF;

  INSERT INTO public.pending_transactions(nonce, tx) VALUES (n, p_tx);
  RETURN jsonb_build_object('ok', true, 'status', 'pending', 'nonce', n);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_verified_pending_transaction(jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_verified_pending_transaction(jsonb) TO service_role;
