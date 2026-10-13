-- Unapplied candidate. Install after account-lifecycle.sql (needs billing.sql,
-- admin-hardening.sql for admin_gate and agent-controls.sql for agent costs).
-- Finance ledger operations for #254/#255: manually recorded or imported expenses
-- and corrections with a source and a reconciliation flag, a reconciliation report
-- that names concrete discrepancies, period summaries that keep cash movements
-- (payouts) apart from recognized records (charges, refunds, fees) and expenses, a
-- CSV-ready export, and agent cost against the configured caps (#248/#263).
-- Every amount is a provider-reported or operator-entered record in minor units.
-- Nothing here computes an available balance, an estimate or a forecast, and
-- nothing spends. Reads need the finance capability with MFA; every mutation also
-- needs a recent MFA step-up and is written to finance_audit.
begin;
alter table sdi_private.finance_ledger add column source text not null default 'provider' check(source in('provider','manual','import'));
alter table sdi_private.finance_ledger add column reconciled boolean not null default false;
alter table sdi_private.finance_ledger add column recorded_by uuid references auth.users(id) on delete set null;
alter table sdi_private.finance_ledger add column corrects uuid references sdi_private.finance_ledger(id);
create index finance_ledger_period on sdi_private.finance_ledger(occurred_at desc,provider,currency,kind);

-- Convention: money in is positive, money out is negative. Charges and payouts are
-- positive, refunds, fees and expenses are negative. Expenses are entered as a
-- positive amount and stored negative so operators cannot invert them by mistake.
create function sdi_private.finance_record(action text,ref text default null,kind text default null,amount_minor bigint default null,
 currency text default null,occurred_at timestamptz default null,note text default '',reason text default '',entry uuid default null,
 rows jsonb default '[]') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare denial jsonb; original sdi_private.finance_ledger; inserted uuid; possible boolean; item jsonb; added integer:=0; duplicates integer:=0; rejected jsonb:='[]';
begin
 denial:=sdi_private.admin_gate('finance_record.'||coalesce(action,'?'),'finance',true,30);
 if denial is not null then return denial; end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason of at most 2000 characters is required.'); end if;
 if action='expense' then
  if ref is null or length(trim(ref)) not between 1 and 200 or amount_minor is null or amount_minor<=0 or amount_minor>=10^15
   or currency is null or currency !~ '^[A-Z]{3}$' or occurred_at is null or occurred_at>clock_timestamp()+interval '1 day' or note is null or length(note)>500 then
   return jsonb_build_object('error','Provide a provider reference, a positive amount in minor units, an ISO currency and the date.'); end if;
  if exists(select 1 from sdi_private.finance_ledger l where l.provider='manual' and l.provider_ref=trim(ref) and l.kind='expense') then
   return jsonb_build_object('status','duplicate','ref',trim(ref)); end if;
  possible:=exists(select 1 from sdi_private.finance_ledger l where l.kind='expense' and l.currency=finance_record.currency and l.amount_minor=-finance_record.amount_minor
   and l.occurred_at::date=finance_record.occurred_at::date);
  insert into sdi_private.finance_ledger(provider,provider_ref,kind,amount_minor,currency,occurred_at,note,source,recorded_by)
  values('manual',trim(ref),'expense',-amount_minor,currency,occurred_at,coalesce(note,''),'manual',auth.uid()) returning id into inserted;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'expense '||trim(ref)||' '||(-amount_minor)||' '||currency,trim(reason));
  return jsonb_build_object('status','recorded','entry',inserted,'possible_duplicate',possible);
 elsif action='import' then
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows) not between 1 and 500 then return jsonb_build_object('error','Import 1 to 500 rows.'); end if;
  for item in select * from jsonb_array_elements(rows) loop
   if jsonb_typeof(item)<>'object' or length(coalesce(item->>'ref',''))not between 1 and 200 or coalesce(item->>'kind','') not in('expense','fee','adjustment')
    or coalesce(item->>'amount_minor','') !~ '^-?[0-9]{1,15}$' or coalesce(item->>'currency','') !~ '^[A-Z]{3}$'
    or (item->>'occurred_at') is null or length(coalesce(item->>'note',''))>500 then
    rejected:=rejected||jsonb_build_array(left(item::text,200)); continue; end if;
   begin
    insert into sdi_private.finance_ledger(provider,provider_ref,kind,amount_minor,currency,occurred_at,note,source,recorded_by)
    values('manual',item->>'ref',item->>'kind',(item->>'amount_minor')::bigint,item->>'currency',(item->>'occurred_at')::timestamptz,coalesce(item->>'note',''),'import',auth.uid())
    on conflict(provider,provider_ref,kind) do nothing;
    if found then added:=added+1; else duplicates:=duplicates+1; end if;
   exception when invalid_datetime_format or datetime_field_overflow then
    rejected:=rejected||jsonb_build_array(left(item::text,200));
   end;
  end loop;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'import added='||added||' duplicates='||duplicates||' rejected='||jsonb_array_length(rejected),trim(reason));
  return jsonb_build_object('status','imported','added',added,'duplicates',duplicates,'rejected',rejected);
 elsif action='correct' then
  if entry is null or amount_minor is null or amount_minor=0 or abs(amount_minor)>=10^15 or note is null or length(trim(note)) not between 1 and 500 then
   return jsonb_build_object('error','Select the entry, the signed correction amount and a note.'); end if;
  select * into original from sdi_private.finance_ledger where id=entry;
  if not found then return jsonb_build_object('error','Entry unavailable.'); end if;
  insert into sdi_private.finance_ledger(provider,provider_ref,kind,amount_minor,currency,occurred_at,note,source,recorded_by,corrects)
  values('manual','correction:'||original.id::text,'adjustment',amount_minor,original.currency,clock_timestamp(),trim(note),'manual',auth.uid(),original.id)
  on conflict(provider,provider_ref,kind) do nothing returning id into inserted;
  if inserted is null then return jsonb_build_object('status','duplicate','entry',original.id); end if;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'correct '||original.id||' by '||amount_minor||' '||original.currency,trim(reason));
  return jsonb_build_object('status','recorded','entry',inserted);
 elsif action='reconcile' then
  if entry is null then return jsonb_build_object('error','Select the entry.'); end if;
  update sdi_private.finance_ledger set reconciled=true where id=entry;
  if not found then return jsonb_build_object('error','Entry unavailable.'); end if;
  insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'reconcile '||entry,trim(reason));
  return jsonb_build_object('status','confirmed');
 end if;
 return jsonb_build_object('error','Unsupported finance operation.');
end $$;
revoke all on function sdi_private.finance_record(text,text,text,bigint,text,timestamptz,text,text,uuid,jsonb) from public,anon;
grant execute on function sdi_private.finance_record(text,text,text,bigint,text,timestamptz,text,text,uuid,jsonb) to authenticated;
create function public.sdi_finance_record(action text,ref text default null,kind text default null,amount_minor bigint default null,
 currency text default null,occurred_at timestamptz default null,note text default '',reason text default '',entry uuid default null,
 rows jsonb default '[]') returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.finance_record(action,ref,kind,amount_minor,currency,occurred_at,note,reason,entry,rows)$$;
revoke all on function public.sdi_finance_record(text,text,text,bigint,text,timestamptz,text,text,uuid,jsonb) from public,anon;
grant execute on function public.sdi_finance_record(text,text,text,bigint,text,timestamptz,text,text,uuid,jsonb) to authenticated;

create function sdi_private.finance_report(action text,period_start timestamptz default null,period_end timestamptz default null,
 provider text default null,currency text default null,page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare denial jsonb; p0 timestamptz; p1 timestamptz; items jsonb; discrepancies jsonb:='[]'; label constant text:=
 'Provider-reported and operator-recorded entries in minor units. Not an available balance; no estimate or forecast is included. Apple proceeds appear only when imported from App Store Connect reports.';
begin
 denial:=sdi_private.admin_gate('finance_report.'||coalesce(action,'?'),'finance',false,60);
 if denial is not null then return denial; end if;
 p1:=coalesce(period_end,clock_timestamp()); p0:=coalesce(period_start,p1-interval '90 days');
 if p1<=p0 or p1-p0>interval '400 days' then return jsonb_build_object('error','Choose a period of at most 400 days.'); end if;
 if page is null or page not between 0 and 49 then return jsonb_build_object('error','Invalid page.'); end if;
 if finance_report.provider is not null and finance_report.provider not in('apple','stripe','manual') then return jsonb_build_object('error','Unknown provider.'); end if;
 if action='reconciliation' then
  select coalesce(jsonb_agg(row_to_json(t) order by t.provider,t.currency,t.kind),'[]'::jsonb) into items from (
   select l.provider,l.currency,l.kind,l.source,sum(l.amount_minor) as amount_minor,count(*) as entries,count(*) filter(where not l.reconciled) as unreconciled
   from sdi_private.finance_ledger l where l.occurred_at>=p0 and l.occurred_at<p1 and (finance_report.provider is null or l.provider=finance_report.provider) and (finance_report.currency is null or l.currency=finance_report.currency)
   group by l.provider,l.currency,l.kind,l.source) t;
  -- 1. Stripe subscriptions updated in the period without any charge record linked to them.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind','subscription_without_charge','subscription',s.id,'provider',s.provider,'status',s.status,'paid_through',s.paid_through))
   from sdi_private.subscriptions s where s.provider='stripe' and s.status in('active','trialing','grace','past_due') and s.last_event_at>=p0 and s.last_event_at<p1
   and not exists(select 1 from sdi_private.finance_ledger l where l.subscription_id=s.id and l.kind='charge')),'[]'::jsonb);
  -- 2. Charges that no subscription explains.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind','charge_without_subscription','entry',l.id,'provider',l.provider,'ref',l.provider_ref,'amount_minor',l.amount_minor,'currency',l.currency))
   from sdi_private.finance_ledger l where l.kind='charge' and l.subscription_id is null and l.occurred_at>=p0 and l.occurred_at<p1),'[]'::jsonb);
  -- 3. Refunds larger than the charges recorded for the same subscription.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind','refund_exceeds_charges','subscription',t.subscription_id,'charged',t.charged,'refunded',t.refunded,'currency',t.currency))
   from (select l.subscription_id,l.currency,sum(l.amount_minor) filter(where l.kind='charge') as charged,-sum(l.amount_minor) filter(where l.kind='refund') as refunded
    from sdi_private.finance_ledger l where l.subscription_id is not null and l.occurred_at<p1 group by l.subscription_id,l.currency) t
   where coalesce(t.refunded,0)>coalesce(t.charged,0)),'[]'::jsonb);
  -- 4. Provider events that errored or were never processed.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind',case when e.outcome='error' then 'event_error' else 'event_unprocessed' end,'event',e.id,'provider',e.provider,'event_type',e.event_type,'note',e.note,'received_at',e.received_at))
   from sdi_private.provider_events e where e.received_at>=p0 and e.received_at<p1 and (e.outcome='error' or (e.processed_at is null and e.received_at<clock_timestamp()-interval '1 hour'))),'[]'::jsonb);
  -- 5. Same provider, kind, amount, currency and day under different references.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind','possible_duplicate','provider',t.provider,'ledger_kind',t.kind,'amount_minor',t.amount_minor,'currency',t.currency,'day',t.day,'refs',t.refs))
   from (select l.provider,l.kind,l.amount_minor,l.currency,l.occurred_at::date as day,jsonb_agg(l.provider_ref order by l.provider_ref) as refs
    from sdi_private.finance_ledger l where l.occurred_at>=p0 and l.occurred_at<p1 and l.kind<>'adjustment' group by 1,2,3,4,5 having count(distinct l.provider_ref)>1) t),'[]'::jsonb);
  -- 6. Manual or imported rows nobody reconciled within 30 days.
  discrepancies:=discrepancies||coalesce((select jsonb_agg(jsonb_build_object('kind','manual_unreconciled','entry',l.id,'ref',l.provider_ref,'ledger_kind',l.kind,'amount_minor',l.amount_minor,'currency',l.currency,'occurred_at',l.occurred_at))
   from sdi_private.finance_ledger l where l.source in('manual','import') and not l.reconciled and l.occurred_at>=p0 and l.occurred_at<p1 and l.created_at<clock_timestamp()-interval '30 days'),'[]'::jsonb);
  return jsonb_build_object('period_start',p0,'period_end',p1,'totals',items,'discrepancies',discrepancies,'discrepancy_count',jsonb_array_length(discrepancies),
   'subscriptions',(select coalesce(jsonb_object_agg(t.status,t.n),'{}'::jsonb) from (select s.status,count(*) as n from sdi_private.subscriptions s group by s.status) t),
   'cancelling_at_period_end',(select count(*) from sdi_private.subscriptions s where s.cancel_at_period_end and s.status in('active','trialing','grace','past_due')),
   'lapsed_within_grace',(select count(*) from sdi_private.subscriptions s where s.status in('active','trialing','grace','past_due') and s.paid_through<=clock_timestamp() and s.paid_through>clock_timestamp()-interval '16 days'),
   'entitled_accounts',(select count(distinct user_id) from sdi_private.entitlements),'label',label);
 elsif action='period_summary' then
  select coalesce(jsonb_agg(row_to_json(t) order by t.month,t.provider,t.currency,t.bucket),'[]'::jsonb) into items from (
   select date_trunc('month',l.occurred_at)::date as month,l.provider,l.currency,
    case l.kind when 'payout' then 'cash_movement' when 'expense' then 'expense' else 'recognized_record' end as bucket,l.kind,
    sum(l.amount_minor) as amount_minor,count(*) as entries
   from sdi_private.finance_ledger l where l.occurred_at>=p0 and l.occurred_at<p1 and (finance_report.provider is null or l.provider=finance_report.provider) and (finance_report.currency is null or l.currency=finance_report.currency)
   group by 1,2,3,4,5) t;
  return jsonb_build_object('period_start',p0,'period_end',p1,'rows',items,'buckets',jsonb_build_array('recognized_record','cash_movement','expense'),'label',label);
 elsif action='export' then
  select coalesce(jsonb_agg(row_to_json(t)),'[]'::jsonb) into items from (
   select l.id,l.occurred_at,l.provider,l.provider_ref,l.kind,l.amount_minor,l.currency,l.source,l.reconciled,l.subscription_id,l.event_id,l.corrects,l.note
   from sdi_private.finance_ledger l where l.occurred_at>=p0 and l.occurred_at<p1 and (finance_report.provider is null or l.provider=finance_report.provider) and (finance_report.currency is null or l.currency=finance_report.currency)
   order by l.occurred_at,l.id limit 1000 offset page*1000) t;
  return jsonb_build_object('period_start',p0,'period_end',p1,'columns',jsonb_build_array('id','occurred_at','provider','provider_ref','kind','amount_minor','currency','source','reconciled','subscription_id','event_id','corrects','note'),
   'rows',items,'has_more',jsonb_array_length(items)=1000,'label',label);
 elsif action='agent_costs' then
  select coalesce(jsonb_agg(row_to_json(t) order by t.key),'[]'::jsonb) into items from (
   select a.key,a.title,a.monthly_cost_cap_minor,a.paused,
    (select coalesce(sum(r.cost_minor),0) from sdi_private.agent_runs r where r.agent_key=a.key and r.started_at>=date_trunc('month',clock_timestamp())) as cost_month_minor,
    (select count(*) from sdi_private.agent_runs r where r.agent_key=a.key and r.state='failed' and r.started_at>=date_trunc('month',clock_timestamp())) as failed_month
   from sdi_private.agents a) t;
  return jsonb_build_object('agents',items,'label','Costs are the amounts agents reported per run in minor units against configured caps; caps are configuration, not spending.');
 end if;
 return jsonb_build_object('error','Unsupported finance report.');
end $$;
revoke all on function sdi_private.finance_report(text,timestamptz,timestamptz,text,text,integer) from public,anon;
grant execute on function sdi_private.finance_report(text,timestamptz,timestamptz,text,text,integer) to authenticated;
create function public.sdi_finance_report(action text,period_start timestamptz default null,period_end timestamptz default null,
 provider text default null,currency text default null,page integer default 0) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.finance_report(action,period_start,period_end,provider,currency,page)$$;
revoke all on function public.sdi_finance_report(text,timestamptz,timestamptz,text,text,integer) from public,anon;
grant execute on function public.sdi_finance_report(text,timestamptz,timestamptz,text,text,integer) to authenticated;
commit;
