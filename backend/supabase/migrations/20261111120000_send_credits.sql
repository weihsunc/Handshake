-- ─────────────────────────────────────────────────────────────────────────────
-- Send credits: new accounts get free sends, then each contract sent costs one.
--
-- Pricing (owner, Nov 11, 2026): 2 free sends per Apple ID, then $2.99 a send.
-- Only the sender pays; signing is always free. A credit pays for one contract
-- however many people sign it, and sending that same contract again (after
-- Revise Contract) is free for a few more sends.
--
-- Only the edge function (service role) touches these tables. Row level
-- security is on with no policies, so the app's own keys can't read or write
-- them; the functions below are callable by the service role only.
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per Handshake account: how many sends are left.
create table public.accounts (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  credits    integer not null default 0 check (credits >= 0),
  created_at timestamptz not null default now()
);

-- Every change to a balance, for support and refunds.
create table public.credit_ledger (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references auth.users (id) on delete cascade,
  delta         integer not null,
  reason        text not null check (reason in ('signup_bonus', 'purchase', 'send', 'refund', 'adjustment')),
  ref           text,             -- contract id for sends and refunds; App Store transaction id for purchases
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
create index credit_ledger_user on public.credit_ledger (user_id, created_at desc);
-- An App Store purchase adds credits once, however often the app reports it.
create unique index credit_ledger_purchase_once on public.credit_ledger (ref) where reason = 'purchase';

-- Free sends go to an Apple ID once, even if its account is deleted and made
-- again. Holds a hash of the sign-in identity, not the identity itself, and
-- isn't tied to the account so deleting the account doesn't clear it.
create table public.free_grants (
  identity_hash text primary key,
  granted_at    timestamptz not null default now()
);

-- Which contracts a credit has paid for, so sending one again is free.
create table public.contract_sends (
  user_id            uuid not null references auth.users (id) on delete cascade,
  contract_id        text not null,
  sends_since_charge integer not null default 1,
  updated_at         timestamptz not null default now(),
  primary key (user_id, contract_id)
);

alter table public.accounts       enable row level security;
alter table public.credit_ledger  enable row level security;
alter table public.free_grants    enable row level security;
alter table public.contract_sends enable row level security;

-- ── ensure_account ───────────────────────────────────────────────────────────
-- Makes the account on first use and gives the free sends, once per identity.
-- Returns the balance.
create function public.ensure_account(p_user uuid, p_identity_hash text, p_free_sends integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  bal integer;
begin
  select credits into bal from public.accounts where user_id = p_user;
  if found then
    return bal;
  end if;

  insert into public.accounts (user_id) values (p_user) on conflict do nothing;

  insert into public.free_grants (identity_hash) values (p_identity_hash) on conflict do nothing;
  if found and p_free_sends > 0 then
    update public.accounts set credits = credits + p_free_sends
      where user_id = p_user returning credits into bal;
    insert into public.credit_ledger (user_id, delta, reason, balance_after)
      values (p_user, p_free_sends, 'signup_bonus', bal);
  end if;

  select credits into bal from public.accounts where user_id = p_user;
  return bal;
end;
$$;

-- ── begin_send ───────────────────────────────────────────────────────────────
-- Called before the DocuSeal submission is made. Takes a credit, unless this
-- contract was already paid for and has sends left on that credit. Raises
-- 'no_credits' when there's nothing to take. Returns whether a credit was
-- taken and the balance after.
create function public.begin_send(p_user uuid, p_contract text, p_sends_per_credit integer)
returns table (charged boolean, credits integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  sent integer;
  bal  integer;
begin
  -- One send at a time per account, so two quick sends can't both spend the last credit.
  select a.credits into bal from public.accounts a where a.user_id = p_user for update;
  if not found then
    raise exception 'no_account';
  end if;

  select c.sends_since_charge into sent from public.contract_sends c
    where c.user_id = p_user and c.contract_id = p_contract;
  if found and sent < p_sends_per_credit then
    update public.contract_sends c set sends_since_charge = c.sends_since_charge + 1, updated_at = now()
      where c.user_id = p_user and c.contract_id = p_contract;
    return query select false, bal;
    return;
  end if;

  update public.accounts a set credits = a.credits - 1
    where a.user_id = p_user and a.credits > 0 returning a.credits into bal;
  if not found then
    raise exception 'no_credits';
  end if;

  insert into public.credit_ledger (user_id, delta, reason, ref, balance_after)
    values (p_user, -1, 'send', p_contract, bal);
  insert into public.contract_sends (user_id, contract_id) values (p_user, p_contract)
    on conflict (user_id, contract_id) do update set sends_since_charge = 1, updated_at = now();

  return query select true, bal;
end;
$$;

-- ── undo_send ────────────────────────────────────────────────────────────────
-- The send didn't go out (DocuSeal failed): give back what begin_send took.
-- Returns the balance.
create function public.undo_send(p_user uuid, p_contract text, p_charged boolean)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  bal integer;
begin
  if p_charged then
    update public.accounts set credits = credits + 1
      where user_id = p_user returning credits into bal;
    insert into public.credit_ledger (user_id, delta, reason, ref, balance_after)
      values (p_user, 1, 'refund', p_contract, bal);
    -- The next send of this contract pays again, as it would have.
    delete from public.contract_sends where user_id = p_user and contract_id = p_contract;
  else
    update public.contract_sends set sends_since_charge = greatest(sends_since_charge - 1, 0)
      where user_id = p_user and contract_id = p_contract;
    select credits into bal from public.accounts where user_id = p_user;
  end if;
  return bal;
end;
$$;

revoke all on function public.ensure_account(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.begin_send(uuid, text, integer)     from public, anon, authenticated;
revoke all on function public.undo_send(uuid, text, boolean)      from public, anon, authenticated;
grant execute on function public.ensure_account(uuid, text, integer) to service_role;
grant execute on function public.begin_send(uuid, text, integer)     to service_role;
grant execute on function public.undo_send(uuid, text, boolean)      to service_role;
