-- ─────────────────────────────────────────────────────────────────────────────
-- Send packs: an App Store purchase adds its sends once.
--
-- The edge function checks the purchase (Apple's signature, this app, a
-- known pack, the buyer's account) and calls add_purchase with the App Store
-- transaction id. The same transaction reported again (the app retries until
-- the backend confirms) adds nothing; credit_ledger_purchase_once (unique on
-- ref for purchases) backs this up if two reports race.
-- ─────────────────────────────────────────────────────────────────────────────

create function public.add_purchase(p_user uuid, p_transaction text, p_credits integer)
returns table (credits integer, added boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  bal integer;
begin
  if p_credits <= 0 then
    raise exception 'bad_credits';
  end if;

  select a.credits into bal from public.accounts a where a.user_id = p_user for update;
  if not found then
    raise exception 'no_account';
  end if;

  if exists (select 1 from public.credit_ledger l where l.reason = 'purchase' and l.ref = p_transaction) then
    return query select bal, false;
    return;
  end if;

  update public.accounts a set credits = a.credits + p_credits
    where a.user_id = p_user returning a.credits into bal;
  insert into public.credit_ledger (user_id, delta, reason, ref, balance_after)
    values (p_user, p_credits, 'purchase', p_transaction, bal);

  return query select bal, true;
end;
$$;

revoke all on function public.add_purchase(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.add_purchase(uuid, text, integer) to service_role;
