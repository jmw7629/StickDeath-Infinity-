-- Local assertions for the billing lifecycle (#258: grace, past due, cancellation,
-- downgrade, expiry, refund, reconciliation) and billing-finance.sql (#254/#255).
begin;
do $$
declare member uuid; owner uuid; r jsonb; ev jsonb; paid timestamptz:=clock_timestamp()+interval '30 days'; t0 timestamptz:=clock_timestamp()-interval '1 hour';
begin
 member:=sdi_test.user('lifecycle-member'); owner:=sdi_test.admin('lifecycle-owner',true,array[]::text[]);
 perform sdi_test.login(owner,'aal2');
 perform sdi_private.finance_admin('set_product',product=>'sdi.creator.monthly.web',provider=>'stripe',tier=>'creator',period=>'monthly',approved=>true,reason=>'USD 4.99 monthly.');
 perform sdi_private.finance_admin('set_product',product=>'sdi.pro.monthly.web',provider=>'stripe',tier=>'pro',period=>'monthly',approved=>true,reason=>'USD 9.99 monthly.');
 perform sdi_private.finance_admin('set_product',product=>'sdi.pro.monthly',provider=>'apple',tier=>'pro',period=>'monthly',approved=>true,reason=>'USD 9.99 monthly.');

 -- Active pro through the paid period.
 ev:=sdi_private.billing_apply_event('stripe','evt_1','customer.subscription.created',t0,'{}',member,'sub_1','sdi.pro.monthly.web','active',paid);
 perform sdi_test.check(ev->>'outcome'='applied','pro subscription applied');
 perform sdi_test.login(member);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='pro' and r->>'status'='active' and (r->>'cancel_at_period_end')::boolean=false,'pro entitlement: '||r::text);

 -- Cancellation at period end keeps access until paid_through and reports the flag.
 perform sdi_private.billing_apply_event('stripe','evt_2','customer.subscription.updated',t0+interval '1 minute','{}',member,'sub_1','sdi.pro.monthly.web','active',paid,true);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='pro' and (r->>'cancel_at_period_end')::boolean,'cancel at period end keeps access and is visible: '||r::text);

 -- Payment failure: past_due keeps access only while paid_through is in the future.
 perform sdi_private.billing_apply_event('stripe','evt_3','customer.subscription.updated',t0+interval '2 minutes','{}',member,'sub_1','sdi.pro.monthly.web','past_due',paid,false);
 perform sdi_test.check((sdi_private.my_entitlement()->>'status')='past_due','past due reported truthfully');
 perform sdi_private.billing_apply_event('stripe','evt_4','customer.subscription.updated',t0+interval '3 minutes','{}',member,'sub_1','sdi.pro.monthly.web','past_due',clock_timestamp()-interval '1 second',false);
 perform sdi_test.check((sdi_private.my_entitlement()->>'tier')='free','past due after paid_through grants nothing');

 -- Grace (Apple billing grace period) grants access until the grace expiry.
 perform sdi_private.billing_apply_event('apple','a1','SUBSCRIBED',t0,'{}',member,'orig-9','sdi.pro.monthly','active',paid);
 perform sdi_private.billing_apply_event('apple','a2','DID_FAIL_TO_RENEW',t0+interval '1 minute','{}',member,'orig-9','sdi.pro.monthly','grace',clock_timestamp()+interval '16 days');
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'status'='grace' and r->>'provider'='apple','grace keeps access: '||r::text);
 perform sdi_private.billing_apply_event('apple','a3','GRACE_PERIOD_EXPIRED',t0+interval '2 minutes','{}',member,'orig-9','sdi.pro.monthly','expired',clock_timestamp()-interval '1 second');
 perform sdi_test.check((sdi_private.my_entitlement()->>'tier')='free','grace expiry ends access');

 -- Recovery and downgrade: the same provider subscription moves to the creator product.
 perform sdi_private.billing_apply_event('stripe','evt_5','invoice.paid',t0+interval '4 minutes','{}',member,'sub_1','sdi.pro.monthly.web','active',paid,false,
  '[{"ref":"in_1","kind":"charge","amount_minor":999,"currency":"USD"}]');
 perform sdi_test.check((sdi_private.my_entitlement()->>'tier')='pro','recovered to pro');
 perform sdi_private.billing_apply_event('stripe','evt_6','customer.subscription.updated',t0+interval '5 minutes','{}',member,'sub_1','sdi.creator.monthly.web','active',paid,false);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='creator','downgrade changes the tier without a second subscription: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.subscriptions where user_id=member and provider='stripe')=1,'one stripe subscription row');

 -- A delayed older event cannot undo the downgrade.
 ev:=sdi_private.billing_apply_event('stripe','evt_late','customer.subscription.updated',t0+interval '4 minutes 30 seconds','{}',member,'sub_1','sdi.pro.monthly.web','active',paid,false);
 perform sdi_test.check(ev->>'outcome'='ignored' and (sdi_private.my_entitlement()->>'tier')='creator','late event ignored');

 -- Refund ends access and records the negative amount once.
 perform sdi_private.billing_apply_event('stripe','evt_7','charge.refunded',t0+interval '6 minutes','{}',member,'sub_1','sdi.creator.monthly.web','refunded',clock_timestamp()-interval '1 second',false,
  '[{"ref":"re_1","kind":"refund","amount_minor":-999,"currency":"USD"}]');
 perform sdi_test.check((sdi_private.my_entitlement()->>'tier')='free','refund ends access');
 perform sdi_test.check((select sum(amount_minor) from sdi_private.finance_ledger where provider='stripe')=0,'charge and refund net to zero in records');

 -- Reconciliation expires only subscriptions more than 16 days past paid_through.
 insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,last_event_at)
 values(member,'stripe','sub_old','sdi.creator.monthly.web','active',clock_timestamp()-interval '17 days',clock_timestamp()-interval '47 days'),
       (member,'stripe','sub_recent','sdi.creator.monthly.web','active',clock_timestamp()-interval '10 days',clock_timestamp()-interval '40 days');
 r:=sdi_private.billing_reconcile();
 perform sdi_test.check((r->>'expired_now')::integer=1,'one lapsed subscription expired: '||r::text);
 perform sdi_test.check((select status from sdi_private.subscriptions where provider_subscription_id='sub_old')='expired','17-day lapse expired');
 perform sdi_test.check((select status from sdi_private.subscriptions where provider_subscription_id='sub_recent')='active','10-day lapse kept for provider retry window');
 perform sdi_test.check((sdi_private.my_entitlement()->>'tier')='free','a lapsed row grants nothing even before the sweep');
 perform sdi_test.check((r->>'lapsing_in_grace')::integer>=1,'lapsing count reported');
end $$;

do $$
declare owner uuid; finance uuid; viewer uuid; member uuid; r jsonb; entry uuid; sub uuid;
begin
 owner:=sdi_test.admin('fin-owner',true,array[]::text[]); finance:=sdi_test.admin('fin-admin',false,array['finance']);
 viewer:=sdi_test.admin('fin-viewer',false,array['overview']); member:=sdi_test.user('fin-member');
 perform sdi_test.check(not exists(select 1 from information_schema.columns where table_schema='sdi_private' and table_name='finance_ledger' and column_name ~ 'price|balance|estimate'),'ledger has no price, balance or estimate column');
 perform sdi_test.login(owner,'aal2');
 perform sdi_private.finance_admin('set_product',product=>'sdi.creator.monthly.web',provider=>'stripe',tier=>'creator',period=>'monthly',approved=>true,reason=>'USD 4.99 monthly.');
 r:=sdi_private.billing_apply_event('stripe','evt_f1','invoice.paid',clock_timestamp()-interval '2 days','{}',member,'sub_f','sdi.creator.monthly.web','active',clock_timestamp()+interval '28 days',false,
  '[{"ref":"in_f1","kind":"charge","amount_minor":499,"currency":"USD"}]');
 sub:=(r->>'subscription')::uuid;
 perform sdi_private.billing_apply_event('stripe','evt_f2','charge.succeeded',clock_timestamp()-interval '1 day','{}',ledger=>'[{"ref":"ch_orphan","kind":"charge","amount_minor":499,"currency":"USD"}]');
 perform sdi_private.billing_apply_event('stripe','evt_f3','charge.refunded',clock_timestamp()-interval '1 hour','{}',member,'sub_f','sdi.creator.monthly.web','refunded',clock_timestamp()-interval '1 hour',false,
  '[{"ref":"re_f1","kind":"refund","amount_minor":-998,"currency":"USD"}]');
 perform sdi_private.billing_apply_event('stripe','evt_f4','payout.paid',clock_timestamp()-interval '1 hour','{}',ledger=>'[{"ref":"po_f1","kind":"payout","amount_minor":10000,"currency":"USD"}]');
 insert into sdi_private.provider_events(provider,event_id,event_type,occurred_at,received_at,payload) values('stripe','evt_stuck','invoice.paid',clock_timestamp()-interval '3 hours',clock_timestamp()-interval '3 hours','{}');

 -- Reads need the finance capability with MFA; mutations also need a recent step-up.
 perform sdi_test.login(member);
 perform sdi_test.check((sdi_private.finance_report('reconciliation')->>'code')='forbidden','member cannot read finance reports');
 perform sdi_test.check((sdi_private.finance_record('expense',ref=>'x',amount_minor=>1,currency=>'USD',occurred_at=>clock_timestamp(),reason=>'r')->>'code')='forbidden','member cannot record');
 perform sdi_test.login(viewer,'aal2');
 perform sdi_test.check((sdi_private.finance_report('reconciliation')->>'code')='forbidden','overview admin lacks finance capability');
 perform sdi_test.login(finance,'aal2');
 r:=sdi_private.finance_record('expense',ref=>'host-2026-10',amount_minor=>2500,currency=>'USD',occurred_at=>clock_timestamp()-interval '1 day',note=>'Hosting October',reason=>'Monthly hosting invoice.');
 perform sdi_test.check(r->>'code'='step_up_required','recording an expense needs a recent MFA verification: '||r::text);
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_billing_reconcile()'),'clients cannot run the reconciliation sweep');
 perform sdi_test.login(finance,'aal2',60);
 r:=sdi_private.finance_record('expense',ref=>'host-2026-10',amount_minor=>2500,currency=>'USD',occurred_at=>clock_timestamp()-interval '1 day',note=>'Hosting October',reason=>'Monthly hosting invoice.');
 perform sdi_test.check(r->>'status'='recorded' and (r->>'possible_duplicate')::boolean=false,'expense recorded: '||r::text);
 entry:=(r->>'entry')::uuid;
 perform sdi_test.check((select amount_minor from sdi_private.finance_ledger where id=entry)=-2500,'expense stored as money out');
 r:=sdi_private.finance_record('expense',ref=>'host-2026-10',amount_minor=>2500,currency=>'USD',occurred_at=>clock_timestamp(),reason=>'Again.');
 perform sdi_test.check(r->>'status'='duplicate','same reference is a duplicate');
 r:=sdi_private.finance_record('expense',ref=>'host-2026-10-b',amount_minor=>2500,currency=>'USD',occurred_at=>clock_timestamp()-interval '1 day',reason=>'Second invoice same day.');
 perform sdi_test.check((r->>'possible_duplicate')::boolean,'same amount and day flagged as a possible duplicate');
 r:=sdi_private.finance_record('expense',ref=>'neg',amount_minor=>-5,currency=>'USD',occurred_at=>clock_timestamp(),reason=>'Bad.');
 perform sdi_test.check(r ? 'error','negative expense amount refused');
 r:=sdi_private.finance_record('import',reason=>'Provider fee statement.',rows=>'[{"ref":"fee-1","kind":"fee","amount_minor":-30,"currency":"USD","occurred_at":"2026-10-01T00:00:00Z"},
  {"ref":"fee-1","kind":"fee","amount_minor":-30,"currency":"USD","occurred_at":"2026-10-01T00:00:00Z"},{"ref":"bad","kind":"charge","amount_minor":"1","currency":"USD","occurred_at":"x"}]');
 perform sdi_test.check((r->>'added')::integer=1 and (r->>'duplicates')::integer=1 and jsonb_array_length(r->'rejected')=1,'import counts added, duplicate and rejected rows: '||r::text);
 r:=sdi_private.finance_record('correct',entry=>entry,amount_minor=>500,note=>'Credit applied by host.',reason=>'Invoice corrected.');
 perform sdi_test.check(r->>'status'='recorded' and (select corrects from sdi_private.finance_ledger where id=(r->>'entry')::uuid)=entry,'correction links to the original');
 perform sdi_test.check((sdi_private.finance_record('reconcile',entry=>entry,reason=>'Matched to bank statement.')->>'status')='confirmed','entry reconciled');
 perform sdi_test.check((select count(*) from sdi_private.finance_audit where actor=finance)=5,'every mutation audited');

 -- Reconciliation report names the discrepancies and labels the numbers as records.
 r:=sdi_private.finance_report('reconciliation',clock_timestamp()-interval '30 days',clock_timestamp()+interval '1 day');
 perform sdi_test.check(r->>'label' like '%Not an available balance%','report labelled');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'discrepancies') d where d->>'kind'='charge_without_subscription' and d->>'ref'='ch_orphan')=1,'orphan charge reported');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'discrepancies') d where d->>'kind'='refund_exceeds_charges' and d->>'subscription'=sub::text)=1,'refund larger than charges reported');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'discrepancies') d where d->>'kind'='event_unprocessed')=1,'stuck event reported');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'discrepancies') d where d->>'kind'='possible_duplicate' and d->>'ledger_kind'='expense')=1,'possible duplicate expense reported');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'discrepancies') d where d->>'kind'='subscription_without_charge')=0,'linked subscription not flagged');
 perform sdi_test.check((r->'subscriptions') ? 'refunded','subscription status counts present');
 perform sdi_test.check((r->>'entitled_accounts')::integer=0,'refunded member not entitled');
 r:=sdi_private.finance_report('period_summary',clock_timestamp()-interval '30 days',clock_timestamp()+interval '1 day');
 perform sdi_test.check((select count(distinct e->>'bucket') from jsonb_array_elements(r->'rows') e)=3,'cash movements, recognized records and expenses separated: '||r::text);
 perform sdi_test.check((select sum((e->>'amount_minor')::bigint) from jsonb_array_elements(r->'rows') e where e->>'bucket'='cash_movement')=10000,'payout is the only cash movement');
 r:=sdi_private.finance_report('export',clock_timestamp()-interval '30 days',clock_timestamp()+interval '1 day');
 -- Ten rows: the eight from this block plus in_1/re_1 from the lifecycle block (same transaction).
 perform sdi_test.check(jsonb_array_length(r->'rows')=10 and (r->'columns') ? 'reconciled' and r::text !~ 'user_id','export rows carry no member identity: '||jsonb_array_length(r->'rows'));
 perform sdi_test.check((sdi_private.finance_report('export',clock_timestamp(),clock_timestamp()-interval '1 day')) ? 'error','inverted period refused');
 perform sdi_test.check((sdi_private.finance_report('reconciliation',clock_timestamp()-interval '500 days',clock_timestamp())) ? 'error','period over 400 days refused');
 r:=sdi_private.finance_report('agent_costs');
 perform sdi_test.check(jsonb_array_length(r->'agents')=5 and (r->'agents'->0) ? 'cost_month_minor','agent costs listed against caps');
end $$;
rollback;
