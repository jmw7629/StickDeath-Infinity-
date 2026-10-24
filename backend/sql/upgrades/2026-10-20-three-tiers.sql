-- Live-project upgrade for the owner decision of 2026-10-20 (three monthly tiers
-- with a 3-day free trial). GENERATED from billing.sql, admin-users.sql,
-- users-profiles.sql and spatter-draft-jobs.sql: every function and view below is
-- byte-identical to its definition there, so a project installed from the bundle
-- before this change ends up with the same schema as a fresh install.
--
-- Apply once on a project that already has the backend bundle installed (SQL
-- editor or psql, as the postgres role). It is idempotent: rerunning it changes
-- nothing further. A fresh project installs the bundle instead and must not run it.
--
-- What changes:
--  * billing_products.tier and users.subscription_tier accept 'unlimited'
--    ('monthly_19_99'); sdi_private.billing_tier_rank orders unlimited > pro > creator
--    for my_entitlement, the admin directory and the Spatter meter.
--  * subscriptions.in_trial (boolean, default false) records a provider-reported
--    free-trial period; entitlements.in_trial = in_trial or status 'trialing'.
--  * sdi_billing_apply_event gains a trailing in_trial argument (the 12-argument
--    version is dropped; deploy the matching backend/billing handlers after this).
--  * Spatter: creator 250 and pro 500 server-funded prompts per billing period
--    (spatter_usage_controls.creator_period_prompts / pro_period_prompts),
--    unlimited has no plan allowance; the break-even budget/estimate columns and
--    spatter_creator_period_limit are removed. global_daily_cap, the per-user
--    safety cap and per-minute rate keep their current values and apply to every
--    tier. Trial-only accounts are refused before anything is counted or spent.
begin;
-- Tables and constraints.
alter table sdi_private.billing_products drop constraint if exists billing_products_tier_check;
alter table sdi_private.billing_products add constraint billing_products_tier_check check(tier in('creator','pro','unlimited'));
alter table sdi_private.subscriptions add column if not exists in_trial boolean not null default false;
alter table public.users drop constraint if exists users_subscription_tier_check;
alter table public.users add constraint users_subscription_tier_check
 check(subscription_tier is null or subscription_tier in('free','monthly_4_99','monthly_9_99','monthly_19_99'));
alter table sdi_private.spatter_usage_controls add column if not exists creator_period_prompts integer not null default 250 check(creator_period_prompts between 0 and 1000000);
alter table sdi_private.spatter_usage_controls add column if not exists pro_period_prompts integer not null default 500 check(pro_period_prompts between 0 and 1000000);
alter table sdi_private.spatter_usage_reservations drop constraint if exists spatter_usage_reservations_plan_check;
alter table sdi_private.spatter_usage_reservations add constraint spatter_usage_reservations_plan_check check(plan in('free','creator','pro','unlimited'));

-- Tier rank and entitlement readers (billing.sql).
create or replace function sdi_private.billing_tier_rank(tier text) returns integer language sql immutable set search_path='' as $$
 select case tier when 'unlimited' then 3 when 'pro' then 2 when 'creator' then 1 else 0 end
$$;
revoke all on function sdi_private.billing_tier_rank(text) from public,anon,authenticated;
create or replace view sdi_private.entitlements as
 select s.user_id,p.tier,s.paid_through,s.status,s.provider,s.cancel_at_period_end,(s.in_trial or s.status='trialing') as in_trial
 from sdi_private.subscriptions s join sdi_private.billing_products p on p.product_id=s.product_id
 where s.user_id is not null and s.status in('active','trialing','grace','past_due') and s.paid_through>clock_timestamp();
revoke all on sdi_private.entitlements from public,anon,authenticated;
create or replace function sdi_private.my_entitlement() returns jsonb language plpgsql security definer set search_path='' as $$
declare e record;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view your plan.'); end if;
 select * into e from sdi_private.entitlements where user_id=auth.uid()
  order by sdi_private.billing_tier_rank(tier) desc,in_trial,paid_through desc limit 1;
 if not found then return jsonb_build_object('tier','free','status','none','paid_through',null,'provider',null,'in_trial',false); end if;
 return jsonb_build_object('tier',e.tier,'status',e.status,'paid_through',e.paid_through,'provider',e.provider,'cancel_at_period_end',e.cancel_at_period_end,
  'in_trial',e.in_trial);
end $$;

-- Billing events carry the trial flag: replace the 12-argument signature.
drop function if exists public.sdi_billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb);
drop function if exists sdi_private.billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb);
create or replace function sdi_private.billing_apply_event(provider text,event_id text,event_type text,occurred_at timestamptz,payload jsonb,
 user_id uuid default null,provider_subscription_id text default null,product_id text default null,status text default null,
 paid_through timestamptz default null,cancel_at_period_end boolean default false,ledger jsonb default '[]',in_trial boolean default null) returns jsonb
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
    -- in_trial: the event's own report (null = not reported = not a trial).
    insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,cancel_at_period_end,in_trial,last_event_at)
    values(user_id,provider,provider_subscription_id,product_id,status,paid_through,coalesce(cancel_at_period_end,false),coalesce(in_trial,false),occurred_at)
    on conflict(provider,provider_subscription_id) do update set user_id=coalesce(excluded.user_id,subscriptions.user_id),product_id=excluded.product_id,
     status=excluded.status,paid_through=excluded.paid_through,cancel_at_period_end=excluded.cancel_at_period_end,in_trial=excluded.in_trial,
     last_event_at=excluded.last_event_at,updated_at=clock_timestamp()
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
revoke all on function sdi_private.billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb,boolean),sdi_private.billing_reconcile() from public,anon,authenticated;
grant execute on function sdi_private.billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb,boolean),sdi_private.billing_reconcile() to service_role;
create or replace function public.sdi_billing_apply_event(provider text,event_id text,event_type text,occurred_at timestamptz,payload jsonb,
 user_id uuid default null,provider_subscription_id text default null,product_id text default null,status text default null,
 paid_through timestamptz default null,cancel_at_period_end boolean default false,ledger jsonb default '[]',in_trial boolean default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.billing_apply_event(provider,event_id,event_type,occurred_at,payload,user_id,provider_subscription_id,product_id,status,paid_through,cancel_at_period_end,ledger,in_trial)$$;
create or replace function public.sdi_billing_reconcile() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.billing_reconcile()$$;
revoke all on function public.sdi_billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb,boolean),public.sdi_billing_reconcile() from public,anon,authenticated;
grant execute on function public.sdi_billing_apply_event(text,text,text,timestamptz,jsonb,uuid,text,text,text,timestamptz,boolean,jsonb,boolean),public.sdi_billing_reconcile() to service_role;

-- Finance product registration accepts the unlimited tier.
create or replace function sdi_private.finance_admin(action text,page integer default 0,product text default null,provider text default null,
 tier text default null,period text default null,approved boolean default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare items jsonb;
begin
 if not sdi_private.admin_can('finance') or not sdi_private.account_active() then return jsonb_build_object('error','Current finance permission and MFA required.'); end if;
 if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid page.'); end if;
 if action='products' then
  select coalesce(jsonb_agg(row_to_json(p) order by p.provider,p.tier,p.period),'[]'::jsonb) into items from sdi_private.billing_products p;
  return jsonb_build_object('products',items,'approved_offers','Three monthly tiers (creator USD 4.99, pro USD 9.99, unlimited USD 19.99), each with a 3-day free trial. Annual periods require owner configuration.');
 elsif action='subscriptions' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select s.id,s.user_id,s.provider,s.product_id,s.status,s.paid_through,s.cancel_at_period_end,s.in_trial,s.last_event_at from sdi_private.subscriptions s
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
  if product is null or length(trim(product)) not between 1 and 200 or provider not in('apple','stripe') or tier not in('creator','pro','unlimited') or period not in('monthly','annual')
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

-- Admin directory plan column ranks by billing_tier_rank (admin-users.sql).
create or replace function sdi_private.users_action(action text,subject uuid default null,query text default '',page integer default 0,reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; before_state text; denial jsonb; flagged integer:=0;
begin
 if not sdi_private.admin_can('users') or not sdi_private.account_active() then return jsonb_build_object('error','Administrator MFA authorization required.'); end if;
 -- Account-state changes need a recent second factor and are rate limited; every
 -- refusal is recorded (admin_gate in admin-hardening.sql, resolved at run time).
 if action in('suspend','ban','restore','signout','note','reset_flags') then
  denial:=sdi_private.admin_gate('users_action.'||action,'users',action<>'note',30);
  if denial is not null then return denial; end if;
 end if;
 if action='history' then
  if subject is null or page is null or page<0 or page>199 then return jsonb_build_object('error','Select an account and valid history page.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select a.id,a.actor,a.subject,a.action,a.reason,a.previous_state,a.created_at
   from sdi_private.admin_user_audit a where a.subject=users_action.subject
   order by a.created_at desc,a.id desc limit 50 offset page*50
  ) item;
  return jsonb_build_object('events',result,'has_more',exists(
   select 1 from sdi_private.admin_user_audit a where a.subject=users_action.subject
   order by a.created_at desc,a.id desc limit 1 offset (page+1)*50));
 end if;
 if action='list' then
  if page is null or page<0 or page>199 or query is null or length(query)>100 then return jsonb_build_object('error','Invalid directory query.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select u.id, coalesce(u.raw_user_meta_data->>'username','Member') as username,
    case when u.email is null then null else left(u.email,1)||'***@'||split_part(u.email,'@',2) end as masked_email,
    u.created_at,u.last_sign_in_at,coalesce(c.state,'active') as state,
    (select count(*) from sdi_private.feed_posts p where p.creator=u.id) as content_count,
    (select coalesce(jsonb_agg(method.provider order by method.provider),'[]'::jsonb)
     from (select distinct i.provider from auth.identities i where i.user_id=u.id) method) as sign_in_methods,
    case when sdi_private.admin_can('moderation') then
     (select count(*) from sdi_private.feed_reports r join sdi_private.feed_posts p on p.id=r.post where p.creator=u.id)
     else null end as feed_report_count,
    -- Open (pending) reports only; reset_flags dismisses these (#285).
    case when sdi_private.admin_can('moderation') then
     (select count(*) from sdi_private.feed_reports r join sdi_private.feed_posts p on p.id=r.post where p.creator=u.id and r.state='pending')
     else null end as open_report_count,
    -- Sign-up source: the provider name Supabase Auth records at first sign-in
    -- (apple, google, github, azure, email). A name only, never an identifier.
    nullif(u.raw_app_meta_data->>'provider','') as signup_source,
    -- Plan is billing data: shown only with the finance capability (billing.sql
    -- installs later; entitlements come only from signed provider events; the
    -- best tier by billing_tier_rank: unlimited > pro > creator).
    case when sdi_private.admin_can('finance') then
     coalesce((select e.tier from sdi_private.entitlements e where e.user_id=u.id
      order by sdi_private.billing_tier_rank(e.tier) desc,e.paid_through desc limit 1),'free')
     else null end as plan
   from auth.users u left join sdi_private.account_controls c on c.user_id=u.id
   where query='' or position(lower(query) in lower(coalesce(u.raw_user_meta_data->>'username','')))>0 or u.id::text=query
   order by u.created_at desc,u.id limit 50 offset page*50
  ) item;
  return jsonb_build_object('users',result,'has_more',jsonb_array_length(result)=50);
 end if;
 if subject is null or subject=auth.uid() or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','Select another account and provide a reason.'); end if;
 if exists(select 1 from sdi_private.admin_roles where user_id=subject and enabled) then
  return jsonb_build_object('error','Administrator accounts require the separate owner recovery procedure.'); end if;
 perform 1 from auth.users where id=subject for update;
 if not found then return jsonb_build_object('error','Account unavailable.'); end if;
 select state into before_state from sdi_private.account_controls where user_id=subject;
 if action in('suspend','ban','restore') then
  insert into sdi_private.account_controls(user_id,state,reason) values(subject,
   case action when 'suspend' then 'suspended' when 'ban' then 'banned' else 'active' end,trim(reason))
  on conflict(user_id) do update set state=excluded.state,reason=excluded.reason,updated_at=clock_timestamp();
 elsif action='reset_flags' then
  -- Dismiss every open report against the member's posts in one audited step,
  -- e.g. after a coordinated false-report campaign. Needs the moderation
  -- capability too; reports filed by the acting administrator stay for another
  -- reviewer (same rule as moderation_action). Each dismissal is recorded in
  -- moderation_audit; a reporter who changes their reason reopens the report.
  if not sdi_private.admin_can('moderation') then
   return jsonb_build_object('error','Resetting flags also needs the moderation capability.'); end if;
  with dismissed as (
   update sdi_private.feed_reports r set state='dismissed' from sdi_private.feed_posts p
   where p.id=r.post and p.creator=users_action.subject and r.state='pending' and r.actor<>auth.uid()
   returning r.id as report_id,p.media_id)
  insert into sdi_private.moderation_audit(report_id,actor,action,reason,media_id,render_digest)
  select d.report_id,auth.uid(),'dismiss','Account flags reset: '||left(trim(users_action.reason),1970),d.media_id,m.render_digest
  from dismissed d join public.sdi_watch_media m on m.id=d.media_id;
  get diagnostics flagged=row_count;
  -- Nothing open: nothing changed, so nothing is audited or notified.
  if flagged=0 then return jsonb_build_object('status','unchanged','dismissed',0); end if;
 elsif action not in('signout','note') then return jsonb_build_object('error','Unsupported account action.'); end if;
 if action in('suspend','ban','signout') then delete from auth.sessions where user_id=subject; end if;
 insert into sdi_private.admin_user_audit(actor,subject,action,reason,previous_state) values(auth.uid(),subject,action,trim(reason),coalesce(before_state,'active'));
 if action='reset_flags' then return jsonb_build_object('status','confirmed','dismissed',flagged); end if;
 return jsonb_build_object('status','confirmed');
end $$;

-- Spatter metering (spatter-draft-jobs.sql).
create or replace function sdi_private.spatter_plan_period_limit(c sdi_private.spatter_usage_controls,p_tier text) returns integer
 language sql immutable set search_path='' as $$
 select case p_tier when 'creator' then c.creator_period_prompts when 'pro' then c.pro_period_prompts else null end
$$;
create or replace function sdi_private.spatter_usage_plan(p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; v_tier text; v_paid timestamptz; v_trial boolean; v_bucket text; v_limit integer; v_used integer;
 v_credits integer:=sdi_private.spatter_credit_balance(p_user);
begin
 select * into c from sdi_private.spatter_usage_controls;
 select e.tier,e.paid_through,e.in_trial into v_tier,v_paid,v_trial from sdi_private.entitlements e where e.user_id=p_user
  order by e.in_trial,sdi_private.billing_tier_rank(e.tier) desc,e.paid_through desc limit 1;
 if v_trial then
  -- Free trial only: Spatter is preview-only; nothing is funded and credits are not spent.
  return jsonb_build_object('plan',v_tier,'trial',true,'unlimited',false,'limit',0,'used',0,'remaining',0,'period','trial','resets_at',to_jsonb(v_paid),
   'credits',v_credits,'available',false,'upgrade','after_trial');
 elsif v_tier='unlimited' then
  return jsonb_build_object('plan','unlimited','trial',false,'unlimited',true,'limit',null,'used',null,'remaining',null,'period','none','resets_at',null,
   'credits',v_credits,'available',true);
 elsif v_tier in('creator','pro') then
  v_bucket:='period:'||to_char(v_paid at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_limit:=sdi_private.spatter_plan_period_limit(c,v_tier);
  select u.used into v_used from sdi_private.spatter_usage_counters u where u.user_id=p_user and u.bucket=v_bucket;
  v_used:=coalesce(v_used,0);
  return jsonb_build_object('plan',v_tier,'trial',false,'unlimited',false,'limit',v_limit,'used',v_used,'remaining',greatest(v_limit-v_used,0),
   'period','billing_period','resets_at',to_jsonb(v_paid),'credits',v_credits,'available',v_limit>v_used or v_credits>0,'bucket',v_bucket);
 end if;
 -- Free: no server-funded allowance; Spatter works only on purchased credits.
 return jsonb_build_object('plan','free','trial',false,'unlimited',false,'limit',0,'used',0,'remaining',0,'period','none','resets_at',null,
  'credits',v_credits,'available',v_credits>0,'upgrade','creator_or_pro');
end $$;
create or replace function sdi_private.spatter_usage_reserve(p_user uuid,p_suggested_prompt text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; p jsonb; v_day date:=(clock_timestamp() at time zone 'utc')::date;
 v_minute text:=to_char(date_trunc('minute',clock_timestamp() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI');
 g integer; d integer; m integer; v_buckets text[]; b text; rid uuid; v_funding text; v_credits integer;
begin
 if p_user is null or not exists(select 1 from auth.users where id=p_user) then
  return jsonb_build_object('allowed',false,'code','unauthorized'); end if;
 if exists(select 1 from sdi_private.account_controls where user_id=p_user and state<>'active') then
  return jsonb_build_object('allowed',false,'code','account_restricted'); end if;
 -- Free without credits (owner decisions 2026-10-15): nothing is funded, so
 -- the request is refused before any counter or reservation.
 if not exists(select 1 from sdi_private.entitlements where user_id=p_user and tier in('creator','pro','unlimited'))
  and sdi_private.spatter_credit_balance(p_user)<=0 then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan','free','upgrade','creator_or_pro','buy_credits',true,'credits',0); end if;
 -- Free trial only (owner decision 2026-10-20): the same refusal shape, before
 -- any counter, reservation or credit spend. Purchased credits wait for the trial to end.
 if exists(select 1 from sdi_private.entitlements where user_id=p_user and in_trial)
  and not exists(select 1 from sdi_private.entitlements where user_id=p_user and not in_trial) then
  p:=sdi_private.spatter_usage_plan(p_user);
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan',p->>'plan','trial',true,'upgrade','after_trial',
   'resets_at',p->'resets_at','buy_credits',false,'credits',(p->>'credits')::integer); end if;
 if (select emergency_stop from sdi_private.agent_global) then
  return jsonb_build_object('allowed',false,'code','emergency_stop'); end if;
 if p_suggested_prompt is not null and not (p_suggested_prompt=any(sdi_private.spatter_suggested_prompt_ids())) then
  return jsonb_build_object('allowed',false,'code','unknown_suggested_prompt'); end if;
 select * into c from sdi_private.spatter_usage_controls;
 -- Serialize per account first, then lock the global day row; the order is fixed.
 perform pg_advisory_xact_lock(hashtextextended('sdi_spatter_usage:'||p_user::text,0));
 insert into sdi_private.spatter_usage_global(day) values(v_day) on conflict(day) do nothing;
 select used into g from sdi_private.spatter_usage_global where day=v_day for update;
 if g>=c.global_daily_cap then return jsonb_build_object('allowed',false,'code','global_limit'); end if;
 select coalesce((select used from sdi_private.spatter_usage_counters where user_id=p_user and bucket='minute:'||v_minute),0) into m;
 if m>=c.user_per_minute_cap then
  return jsonb_build_object('allowed',false,'code','rate_limited',
   'retry_after_seconds',greatest(1,60-floor(extract(second from clock_timestamp() at time zone 'utc'))::integer)); end if;
 select coalesce((select used from sdi_private.spatter_usage_counters where user_id=p_user and bucket='day:'||v_day::text),0) into d;
 if d>=c.user_daily_safety_cap then
  return jsonb_build_object('allowed',false,'code','daily_safety_limit','resets_at',(v_day+1)::timestamp at time zone 'utc'); end if;
 -- Funding order: plan allowance (unlimited, or the creator/pro period), then one credit.
 p:=sdi_private.spatter_usage_plan(p_user);
 v_credits:=(p->>'credits')::integer;
 if (p->>'trial')::boolean then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan',p->>'plan','trial',true,'upgrade','after_trial',
   'resets_at',p->'resets_at','buy_credits',false,'credits',v_credits);
 elsif (p->>'unlimited')::boolean then v_funding:='unlimited';
 elsif (p->>'remaining')::integer>0 then v_funding:='allowance';
 elsif v_credits>0 then v_funding:='credit';
 elsif p->>'plan'='free' then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan','free','upgrade','creator_or_pro','buy_credits',true,'credits',0);
 else
  return jsonb_build_object('allowed',false,'code','plan_allowance_exhausted','plan',p->>'plan','period',p->>'period','resets_at',p->'resets_at',
   'upgrade',case p->>'plan' when 'creator' then 'pro' else 'unlimited' end,'buy_credits',true,'credits',0); end if;
 v_buckets:=array['minute:'||v_minute,'day:'||v_day::text];
 if v_funding='allowance' then v_buckets:=v_buckets||(p->>'bucket'); end if;
 foreach b in array v_buckets loop
  insert into sdi_private.spatter_usage_counters as u(user_id,bucket,used) values(p_user,b,1)
   on conflict(user_id,bucket) do update set used=u.used+1,updated_at=clock_timestamp();
 end loop;
 update sdi_private.spatter_usage_global set used=used+1,updated_at=clock_timestamp() where day=v_day;
 insert into sdi_private.spatter_usage_reservations(user_id,plan,funding,buckets,day) values(p_user,p->>'plan',v_funding,v_buckets,v_day) returning id into rid;
 if v_funding='credit' then
  insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,reservation_id) values(p_user,-1,'spend',rid);
  v_credits:=v_credits-1;
 end if;
 return jsonb_build_object('allowed',true,'reservation',rid,'plan',p->>'plan','period',p->>'period','funding',v_funding,
  'remaining',case v_funding when 'unlimited' then null when 'allowance' then to_jsonb((p->>'remaining')::integer-1) else to_jsonb((p->>'remaining')::integer) end,
  'credits',v_credits,'resets_at',p->'resets_at');
end $$;
create or replace function sdi_private.spatter_usage_admin(action text,revision bigint default null,payload jsonb default '{}',reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; is_owner boolean; v_day date:=(clock_timestamp() at time zone 'utc')::date; next_rev bigint;
begin
 if not sdi_private.admin_can('overview') or not sdi_private.account_active() then return jsonb_build_object('error','Current administrator MFA session required.'); end if;
 select r.owner into is_owner from sdi_private.admin_roles r where r.user_id=auth.uid() and r.enabled;
 select * into c from sdi_private.spatter_usage_controls;
 if action='get' then
  return jsonb_build_object('controls',to_jsonb(c)-'singleton'-'updated_by',
   'period_limits',jsonb_build_object('creator',sdi_private.spatter_plan_period_limit(c,'creator'),
    'pro',sdi_private.spatter_plan_period_limit(c,'pro'),'unlimited',null),
   'global_used_today',coalesce((select g.used from sdi_private.spatter_usage_global g where g.day=v_day),0),
   'committed_units_today',coalesce((select sum(r.units) from sdi_private.spatter_usage_reservations r where r.day=v_day and r.state='committed'),0),
   'emergency_stop',(select a.emergency_stop from sdi_private.agent_global a));
 elsif action='set' then
  if not coalesce(is_owner,false) then return jsonb_build_object('error','Only the owner can change Spatter limits.'); end if;
  if spatter_usage_admin.revision is distinct from c.revision then return jsonb_build_object('error','Limits changed elsewhere; reload.','revision',c.revision); end if;
  if length(trim(coalesce(spatter_usage_admin.reason,''))) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
  if payload is null or jsonb_typeof(payload)<>'object' or exists(select 1 from jsonb_object_keys(payload) k
   where k not in('global_daily_cap','user_daily_safety_cap','user_per_minute_cap','creator_period_prompts','pro_period_prompts')) then
   return jsonb_build_object('error','Unknown limit.'); end if;
  begin
   update sdi_private.spatter_usage_controls u set
    global_daily_cap=coalesce((payload->>'global_daily_cap')::integer,u.global_daily_cap),
    user_daily_safety_cap=coalesce((payload->>'user_daily_safety_cap')::integer,u.user_daily_safety_cap),
    user_per_minute_cap=coalesce((payload->>'user_per_minute_cap')::integer,u.user_per_minute_cap),
    creator_period_prompts=coalesce((payload->>'creator_period_prompts')::integer,u.creator_period_prompts),
    pro_period_prompts=coalesce((payload->>'pro_period_prompts')::integer,u.pro_period_prompts),
    revision=c.revision+1,updated_by=auth.uid(),updated_at=clock_timestamp()
   returning u.revision into next_rev;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
   return jsonb_build_object('error','A limit is outside its allowed range.');
  end;
  insert into sdi_private.agent_audit(actor,agent_key,action,reason)
   values(auth.uid(),'spatter_advice','set_usage_limits '||payload::text,trim(spatter_usage_admin.reason));
  return jsonb_build_object('status','confirmed','revision',next_rev);
 end if;
 return jsonb_build_object('error','Unknown action.');
end $$;
revoke all on function sdi_private.spatter_plan_period_limit(sdi_private.spatter_usage_controls,text) from public,anon,authenticated;
drop function if exists sdi_private.spatter_creator_period_limit(sdi_private.spatter_usage_controls);
alter table sdi_private.spatter_usage_controls drop column if exists creator_period_budget_microusd;
alter table sdi_private.spatter_usage_controls drop column if exists prompt_cost_estimate_microusd;
commit;
