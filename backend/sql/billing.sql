-- Unapplied candidate. Install after achievements.sql (needs admin-approval.sql and
-- admin-users.sql). Canonical entitlements come only from signed provider events
-- (Stripe webhooks, App Store Server Notifications) verified by server-side edge
-- functions (see backend/billing/README.md). No price is stored here: the owner's
-- approved offers are two monthly tiers at USD 4.99 and USD 9.99; annual periods
-- require explicit owner configuration (owner_configured_at) before any product row
-- can be approved. Clients never write subscription status or tier.
begin;
create table sdi_private.billing_products (
 product_id text primary key check(length(product_id) between 1 and 200), provider text not null check(provider in('apple','stripe')),
 tier text not null check(tier in('creator','pro')), period text not null check(period in('monthly','annual')),
 approved boolean not null default false, owner_configured_at timestamptz, note text not null default '' check(length(note)<=500),
 check(period='monthly' or owner_configured_at is not null or not approved)
);
create table sdi_private.provider_events (
 id uuid primary key default gen_random_uuid(), provider text not null check(provider in('apple','stripe')),
 event_id text not null check(length(event_id) between 1 and 200), event_type text not null check(length(event_type) between 1 and 120),
 occurred_at timestamptz not null, received_at timestamptz not null default clock_timestamp(), payload jsonb not null,
 processed_at timestamptz, outcome text not null default 'received' check(outcome in('received','applied','ignored','error')),
 note text not null default '' check(length(note)<=500), unique(provider,event_id)
);
create table sdi_private.subscriptions (
 id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete set null,
 provider text not null check(provider in('apple','stripe')), provider_subscription_id text not null check(length(provider_subscription_id) between 1 and 200),
 product_id text not null references sdi_private.billing_products(product_id),
 status text not null check(status in('active','trialing','grace','past_due','cancelled','expired','revoked','refunded')),
 paid_through timestamptz not null, cancel_at_period_end boolean not null default false,
 last_event_at timestamptz not null, updated_at timestamptz not null default clock_timestamp(),
 unique(provider,provider_subscription_id)
);
-- Provider-reported money movements. Amounts are copied from signed provider
-- events in minor units; they are records, never an available balance.
create table sdi_private.finance_ledger (
 id uuid primary key default gen_random_uuid(), provider text not null check(provider in('apple','stripe','manual')),
 provider_ref text not null check(length(provider_ref) between 1 and 200),
 kind text not null check(kind in('charge','refund','fee','payout','adjustment','expense')),
 amount_minor bigint not null, currency text not null check(currency ~ '^[A-Z]{3}$'), occurred_at timestamptz not null,
 event_id uuid references sdi_private.provider_events(id), subscription_id uuid references sdi_private.subscriptions(id),
 note text not null default '' check(length(note)<=500), created_at timestamptz not null default clock_timestamp(),
 unique(provider,provider_ref,kind)
);
create table sdi_private.finance_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id), action text not null,
 reason text not null check(length(reason) between 1 and 2000), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.billing_products enable row level security;
alter table sdi_private.provider_events enable row level security;
alter table sdi_private.subscriptions enable row level security;
alter table sdi_private.finance_ledger enable row level security;
alter table sdi_private.finance_audit enable row level security;
revoke all on sdi_private.billing_products,sdi_private.provider_events,sdi_private.subscriptions,sdi_private.finance_ledger,sdi_private.finance_audit from public,anon,authenticated;
create index subscriptions_user on sdi_private.subscriptions(user_id,paid_through desc);
-- Entitlement: the best current paid tier. 'pro' outranks 'creator'. Grace and
-- past_due keep access until paid_through; nothing else grants anything.
create view sdi_private.entitlements as
 select s.user_id,p.tier,s.paid_through,s.status,s.provider,s.cancel_at_period_end
 from sdi_private.subscriptions s join sdi_private.billing_products p on p.product_id=s.product_id
 where s.user_id is not null and s.status in('active','trialing','grace','past_due') and s.paid_through>clock_timestamp();
revoke all on sdi_private.entitlements from public,anon,authenticated;
create function sdi_private.my_entitlement() returns jsonb language plpgsql security definer set search_path='' as $$
declare e record;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view your plan.'); end if;
 select * into e from sdi_private.entitlements where user_id=auth.uid()
  order by case tier when 'pro' then 0 else 1 end,paid_through desc limit 1;
 if not found then return jsonb_build_object('tier','free','status','none','paid_through',null,'provider',null); end if;
 return jsonb_build_object('tier',e.tier,'status',e.status,'paid_through',e.paid_through,'provider',e.provider,'cancel_at_period_end',e.cancel_at_period_end);
end $$;
revoke all on function sdi_private.my_entitlement() from public,anon;
grant execute on function sdi_private.my_entitlement() to authenticated;
create function public.sdi_my_entitlement() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.my_entitlement()$$;
revoke all on function public.sdi_my_entitlement() from public,anon;
grant execute on function public.sdi_my_entitlement() to authenticated;

-- Service-only ingestion of one verified provider event. The edge function has
-- already verified the signature and mapped the provider payload to this canonical
-- shape. Duplicate event ids are recorded once; out-of-order events never move a
-- subscription backwards; unknown or unapproved products are ignored, not granted.
create function sdi_private.billing_apply_event(provider text,event_id text,event_type text,occurred_at timestamptz,payload jsonb,
 user_id uuid default null,provider_subscription_id text default null,product_id text default null,status text default null,
 paid_through timestamptz default null,cancel_at_period_end boolean default false,ledger jsonb default '[]') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare ev uuid; existing sdi_private.subscriptions; sub uuid; entry jsonb; result text:='applied'; reason text:='';
begin
 if provider is null or provider not in('apple','stripe') or event_id is null or event_type is null or occurred_at is null or payload is null then
  return jsonb_build_object('error','Provider, event id, type, time and payload are required.'); end if;
 insert into sdi_private.provider_events(provider,event_id,event_type,occurred_at,payload) values(provider,event_id,event_type,occurred_at,payload)
 on conflict(provider,event_id) do nothing returning id into ev;
 if ev is null then return jsonb_build_object('duplicate',true); end if;
 if provider_subscription_id is not null then
  if product_id is null or not exists(select 1 from sdi_private.billing_products p where p.product_id=billing_apply_event.product_id and p.provider=billing_apply_event.provider and p.approved) then
   result:='ignored'; reason:='Product is not an approved offer.';
  elsif status is null or status not in('active','trialing','grace','past_due','cancelled','expired','revoked','refunded') or paid_through is null then
   result:='ignored'; reason:='Subscription status or paid-through date missing.';
  else
   select * into existing from sdi_private.subscriptions s where s.provider=billing_apply_event.provider and s.provider_subscription_id=billing_apply_event.provider_subscription_id for update;
   if found and existing.last_event_at>occurred_at then
    result:='ignored'; reason:='Older than the last applied event.';
   else
    insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,cancel_at_period_end,last_event_at)
    values(user_id,provider,provider_subscription_id,product_id,status,paid_through,coalesce(cancel_at_period_end,false),occurred_at)
    on conflict(provider,provider_subscription_id) do update set user_id=coalesce(excluded.user_id,subscriptions.user_id),product_id=excluded.product_id,
     status=excluded.status,paid_through=excluded.paid_through,cancel_at_period_end=excluded.cancel_at_period_end,last_event_at=excluded.last_event_at,updated_at=clock_timestamp()
    returning id into sub;
   end if;
  end if;
 end if;
 for entry in select * from jsonb_array_elements(coalesce(ledger,'[]'::jsonb)) loop
  if entry->>'kind' not in('charge','refund','fee','payout','adjustment') or (entry->>'amount_minor') !~ '^-?[0-9]{1,15}$' or (entry->>'currency') !~ '^[A-Z]{3}$'
   or length(coalesce(entry->>'ref',''))=0 then
   result:='error'; reason:='Ledger entry rejected: '||left(entry::text,200); exit;
  end if;
  insert into sdi_private.finance_ledger(provider,provider_ref,kind,amount_minor,currency,occurred_at,event_id,subscription_id)
  values(provider,entry->>'ref',entry->>'kind',(entry->>'amount_minor')::bigint,entry->>'currency',occurred_at,ev,sub)
  on conflict(provider,provider_ref,kind) do nothing;
 end loop;
 update sdi_private.provider_events set processed_at=clock_timestamp(),outcome=result,note=left(reason,500) where id=ev;
 return jsonb_build_object('event',ev,'outcome',result,'note',reason,'subscription',sub);
end $$;
-- Reconciliation: expire lapsed subscriptions after a 16-day grace window and
-- report counts. Edge functions also call this after replaying missed events.
create function sdi_private.billing_reconcile() returns jsonb language plpgsql security definer set search_path='' as $$
declare expired integer;
begin
 update sdi_private.subscriptions set status='expired',updated_at=clock_timestamp()
 where status in('active','trialing','grace','past_due') and paid_through<clock_timestamp()-interval '16 days';
 get diagnostics expired=row_count;
 return jsonb_build_object('expired_now',expired,
  'entitled',(select count(distinct user_id) from sdi_private.entitlements),
  'lapsing_in_grace',(select count(*) from sdi_private.subscriptions where status in('active','trialing','grace','past_due') and paid_through<=clock_timestamp()),
  'unprocessed_events',(select count(*) from sdi_private.provider_events where processed_at is null),
  'event_errors',(select count(*) from sdi_private.provider_events where outcome='error'),
  'measured_at',clock_timestamp());
end $$;
revoke all on function sdi_private.billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb),sdi_private.billing_reconcile() from public,anon,authenticated;
grant execute on function sdi_private.billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb),sdi_private.billing_reconcile() to service_role;
create function public.sdi_billing_apply_event(provider text,event_id text,event_type text,occurred_at timestamptz,payload jsonb,
 user_id uuid default null,provider_subscription_id text default null,product_id text default null,status text default null,
 paid_through timestamptz default null,cancel_at_period_end boolean default false,ledger jsonb default '[]') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.billing_apply_event(provider,event_id,event_type,occurred_at,payload,user_id,provider_subscription_id,product_id,status,paid_through,cancel_at_period_end,ledger)$$;
create function public.sdi_billing_reconcile() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.billing_reconcile()$$;
revoke all on function public.sdi_billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb),public.sdi_billing_reconcile() from public,anon,authenticated;
grant execute on function public.sdi_billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb),public.sdi_billing_reconcile() to service_role;

-- Finance-capability administrators read provider-backed records; product
-- approval is the only mutation and is audited. No balances are computed.
create function sdi_private.finance_admin(action text,page integer default 0,product text default null,provider text default null,
 tier text default null,period text default null,approved boolean default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare items jsonb;
begin
 if not sdi_private.admin_can('finance') or not sdi_private.account_active() then return jsonb_build_object('error','Current finance permission and MFA required.'); end if;
 if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid page.'); end if;
 if action='products' then
  select coalesce(jsonb_agg(row_to_json(p) order by p.provider,p.tier,p.period),'[]'::jsonb) into items from sdi_private.billing_products p;
  return jsonb_build_object('products',items,'approved_offers','Two monthly tiers (USD 4.99, USD 9.99). Annual periods require owner configuration.');
 elsif action='subscriptions' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select s.id,s.user_id,s.provider,s.product_id,s.status,s.paid_through,s.cancel_at_period_end,s.last_event_at from sdi_private.subscriptions s
   order by s.updated_at desc,s.id limit 50 offset page*50) item;
  return jsonb_build_object('subscriptions',items);
 elsif action='ledger' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select l.id,l.provider,l.provider_ref,l.kind,l.amount_minor,l.currency,l.occurred_at,l.note from sdi_private.finance_ledger l
   order by l.occurred_at desc,l.id limit 50 offset page*50) item;
  return jsonb_build_object('ledger',items,'label','Provider-reported records in minor units; not an available balance.');
 elsif action='events' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select e.id,e.provider,e.event_type,e.occurred_at,e.received_at,e.processed_at,e.outcome,e.note from sdi_private.provider_events e
   order by e.received_at desc,e.id limit 50 offset page*50) item;
  return jsonb_build_object('events',items);
 elsif action='summary' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select l.provider,l.currency,l.kind,sum(l.amount_minor) as amount_minor,count(*) as entries from sdi_private.finance_ledger l
   group by l.provider,l.currency,l.kind order by l.provider,l.currency,l.kind) item;
  return jsonb_build_object('totals',items,'label','Sums of provider-reported entries; estimates and cash are not shown here.',
   'entitled_accounts',(select count(distinct user_id) from sdi_private.entitlements));
 elsif action='configure_annual' then
  -- The owner's explicit annual decision (amounts live in the provider dashboards).
  if not exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) then return jsonb_build_object('error','Owner permission required.'); end if;
  if product is null or reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','Product id and reason required.'); end if;
  update sdi_private.billing_products p set owner_configured_at=clock_timestamp() where p.product_id=trim(product) and p.period='annual';
  if not found then return jsonb_build_object('error','No annual product with that id.'); end if;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'configure_annual '||trim(product),trim(finance_admin.reason));
  return jsonb_build_object('status','confirmed');
 elsif action='set_product' then
  if not exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) then return jsonb_build_object('error','Owner permission required.'); end if;
  if product is null or length(trim(product)) not between 1 and 200 or provider not in('apple','stripe') or tier not in('creator','pro') or period not in('monthly','annual')
   or approved is null or reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','Product id, provider, tier, period, approval and reason required.'); end if;
  if period='annual' and approved and not exists(select 1 from sdi_private.billing_products p where p.product_id=trim(product) and p.owner_configured_at is not null) then
   return jsonb_build_object('error','Annual offers need explicit owner configuration before approval.'); end if;
  insert into sdi_private.billing_products(product_id,provider,tier,period,approved,owner_configured_at)
  values(trim(product),provider,tier,period,approved,case when period='annual' then null else clock_timestamp() end)
  on conflict(product_id) do update set provider=excluded.provider,tier=excluded.tier,period=excluded.period,approved=excluded.approved;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'set_product '||trim(product)||' approved='||approved,trim(finance_admin.reason));
  return jsonb_build_object('status','confirmed');
 end if;
 return jsonb_build_object('error','Unsupported finance operation.');
end $$;
revoke all on function sdi_private.finance_admin(text,integer,text,text,text,text,boolean,text) from public,anon;
grant execute on function sdi_private.finance_admin(text,integer,text,text,text,text,boolean,text) to authenticated;
create function public.sdi_finance_admin(action text,page integer default 0,product text default null,provider text default null,
 tier text default null,period text default null,approved boolean default null,reason text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.finance_admin(action,page,product,provider,tier,period,approved,reason)$$;
revoke all on function public.sdi_finance_admin(text,integer,text,text,text,text,boolean,text) from public,anon;
grant execute on function public.sdi_finance_admin(text,integer,text,text,text,text,boolean,text) to authenticated;
commit;
