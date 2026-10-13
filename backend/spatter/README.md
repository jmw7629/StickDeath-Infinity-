# Spatter cloud-advice handler (contract implementation)

`handler.py` is the server side of the versioned, provider-neutral Spatter
transport that `StickDeathInfinity/App/SpatterBackendClient.swift` speaks. It is
standard-library Python, framework-free, and makes no provider, network or
database call on its own. Deployment wires it to an HTTPS runtime and injects
the three collaborators below. **No provider is configured by this change**; the
default `NullProvider` answers `503 {"error":"not configured"}` and the iOS
client shows "Spatter cloud is not configured on the server" and keeps local
guidance. No paid external AI call is made anywhere in this repository.

## Contract (schemaVersion 1)

Request `POST <SPATTER_BACKEND_URL>` with `Authorization: Bearer <Supabase access token>`:

```json
{"schemaVersion": 1, "messages": [{"role": "system|user|assistant", "content": "…"}], "max_tokens": 500, "temperature": 0.8}
```

Bounds enforced server-side (mirroring the client): body ≤ 128 KiB, 1–41
messages, each non-blank and ≤ 32 KiB, last message from the user. A missing
`schemaVersion` is the legacy client; `≥ 2` is refused with 400.

Response:

```json
{"schemaVersion": 1, "reply": "…", "usage": {"units": 42}, "budget": {"remaining": 17, "resetsAt": "2026-10-13T00:00:00Z"}}
```

Errors use the same envelope with `error` instead of `reply`:
`400` malformed/unsupported, `401` missing/invalid/expired token, `403` non-user
role, `413` too large, `429` daily budget exhausted, `502` provider failure,
`503` not configured. The client maps 503 and 429 to honest unavailable states.
The legacy `{"choices":[{"message":{"content"}}]}` shape is still decoded by the
client but is not produced here.

## Supabase JWT verification contract

`verify_jwt(token) -> claims` must:

1. Verify the signature against the project's JWKS (`/auth/v1/.well-known/jwks.json`,
   RS256/ES256) or, for legacy projects, the JWT secret (HS256). Never accept `alg: none`.
2. Require `exp` in the future, `aud == "authenticated"`, and the project issuer.
3. Return the claims; the handler additionally refuses `role` values other than
   `authenticated` (service-role and anon keys never carry a user request).

The token is read from the `Authorization` header only, never from the body or
query, and is never logged. The handler re-checks `exp` against its own clock.

## Per-user daily budget table

The budget collaborator is backed by one table; the SQL below is a deployment
candidate, not an applied migration (same policy as `backend/sql/README.md`):

```sql
create table if not exists public.spatter_daily_budget (
  user_id uuid not null references auth.users(id) on delete cascade,
  budget_day date not null,
  used integer not null default 0 check (used >= 0),
  daily_limit integer not null default 40 check (daily_limit >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, budget_day)
);
alter table public.spatter_daily_budget enable row level security;
-- Users may read their own row; only the service role writes.
create policy "spatter budget self read" on public.spatter_daily_budget
  for select using (auth.uid() = user_id);

-- Atomic reserve: returns remaining units, or null when exhausted.
create or replace function public.sdi_spatter_reserve(p_user uuid)
returns table(remaining integer, resets_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_day date := (now() at time zone 'utc')::date; v_used int; v_limit int;
begin
  insert into spatter_daily_budget(user_id, budget_day) values (p_user, v_day)
    on conflict (user_id, budget_day) do nothing;
  select used, daily_limit into v_used, v_limit from spatter_daily_budget
    where user_id = p_user and budget_day = v_day for update;
  if v_used >= v_limit then return; end if;
  update spatter_daily_budget set used = used + 1, updated_at = now()
    where user_id = p_user and budget_day = v_day;
  return query select v_limit - v_used - 1, (v_day + 1)::timestamptz at time zone 'utc';
end $$;
revoke all on function public.sdi_spatter_reserve(uuid) from public, anon, authenticated;

create or replace function public.sdi_spatter_release(p_user uuid) returns void
language sql security definer set search_path = public as $$
  update spatter_daily_budget set used = greatest(used - 1, 0), updated_at = now()
    where user_id = p_user and budget_day = (now() at time zone 'utc')::date;
$$;
revoke all on function public.sdi_spatter_release(uuid) from public, anon, authenticated;
```

`handler.InMemoryBudget` implements the same semantics for tests. The default
limit (40 units/day) is a placeholder the owner sets; the handler reserves a unit
only after the provider is known to be configured and refunds it when the
provider call fails, so an unconfigured deployment never drains budgets.

## Tests

`python3 -m unittest backend.spatter.test_handler -v` runs the contract with
fakes: JWT acceptance/rejection, expiry, role refusal, bounds, 503 without a
provider (and no budget consumption), 429 exhaustion with reset time, 502 refund,
and the exact success envelope. No sockets, no provider, no database.

## Remaining (deferred by owner instruction)

Choosing and configuring a provider, deploying the function, applying the SQL,
and the model-switch/rate-limit integration runs. Account-level cost reporting
beyond `usage.units` is not defined yet. Nothing here claims a live deployment.
