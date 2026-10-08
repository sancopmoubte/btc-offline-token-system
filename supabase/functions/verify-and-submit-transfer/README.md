# verify-and-submit-transfer

Verifies the CatCat MMC transfer format and ML-DSA-44 signature, then calls the
service-role-only `submit_verified_pending_transaction` database function.

Required secrets are provided automatically by Supabase:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

Deploy with:

```sh
supabase functions deploy verify-and-submit-transfer --no-verify-jwt
```

The function itself validates the request and the database RPC additionally
checks nonce reuse, available balance, zero fee and inserts atomically.
