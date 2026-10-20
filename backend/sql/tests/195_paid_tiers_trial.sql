-- Owner decision 2026-10-20: three monthly tiers (creator, pro, unlimited) ranked
-- unlimited > pro > creator, each with a 3-day free trial. Product registration
-- accepts the unlimited tier; every entitlement reader ranks it highest; the
-- free-trial flag is recorded from verified provider events, reported to the
-- member and to finance, and cleared by the first paid period.
begin;
do $$
declare member uuid; trial uuid; owner uuid; finance uuid; directory uuid; r jsonb; ev jsonb; item jsonb;
 paid timestamptz:=date_trunc('second',clock_timestamp())+interval '30 days';
begin
 member:=sdi_test.user('tiers-member'); trial:=sdi_test.user('tiers-trial');
 owner:=sdi_test.admin('tiers-owner',true,array[]::text[]); finance:=sdi_test.admin('tiers-finance',false,array['finance']);
 directory:=sdi_test.admin('tiers-directory',false,array['users','finance']);

 -- Registration: the owner approves the three Apple monthly products; nothing else is a tier.
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.finance_admin('set_product',product=>'com.willisbmb.StickDeathInfinity.creator.monthly',provider=>'apple',tier=>'creator',period=>'monthly',approved=>true,reason=>'USD 4.99.');
 perform sdi_test.check(r->>'status'='confirmed','creator product approved: '||r::text);
 r:=sdi_private.finance_admin('set_product',product=>'com.willisbmb.StickDeathInfinity.pro.monthly',provider=>'apple',tier=>'pro',period=>'monthly',approved=>true,reason=>'USD 9.99.');
 perform sdi_test.check(r->>'status'='confirmed','pro product approved: '||r::text);
 r:=sdi_private.finance_admin('set_product',product=>'com.willisbmb.StickDeathInfinity.unlimited.monthly',provider=>'apple',tier=>'unlimited',period=>'monthly',approved=>true,reason=>'USD 19.99.');
 perform sdi_test.check(r->>'status'='confirmed','unlimited product approved: '||r::text);
 r:=sdi_private.finance_admin('set_product',product=>'sdi.platinum.monthly',provider=>'apple',tier=>'platinum',period=>'monthly',approved=>true,reason=>'x');
 perform sdi_test.check(r->>'error' like 'Product id, provider, tier%','unknown tier refused: '||r::text);
 begin
  insert into sdi_private.billing_products(product_id,provider,tier,period,approved) values('bad.tier','apple','platinum','monthly',false);
  perform sdi_test.check(false,'tier check constraint must refuse platinum');
 exception when check_violation then null; end;
 r:=sdi_private.finance_admin('products');
 perform sdi_test.check(r->>'approved_offers' like '%unlimited USD 19.99%' and jsonb_array_length(r->'products')=3,'products list the three tiers: '||r::text);
 perform sdi_test.logout();

 -- Ranking: unlimited > pro > creator, whatever the paid-through order.
 perform sdi_private.billing_apply_event('apple','tiers-1','SUBSCRIBED',clock_timestamp()-interval '3 minutes','{}',member,'orig-tc',
  'com.willisbmb.StickDeathInfinity.creator.monthly','active',paid+interval '5 days');
 perform sdi_private.billing_apply_event('apple','tiers-2','SUBSCRIBED',clock_timestamp()-interval '3 minutes','{}',member,'orig-tu',
  'com.willisbmb.StickDeathInfinity.unlimited.monthly','active',paid-interval '5 days');
 perform sdi_private.billing_apply_event('apple','tiers-3','SUBSCRIBED',clock_timestamp()-interval '3 minutes','{}',member,'orig-tp',
  'com.willisbmb.StickDeathInfinity.pro.monthly','active',paid);
 perform sdi_test.check(sdi_private.billing_tier_rank('unlimited')>sdi_private.billing_tier_rank('pro')
  and sdi_private.billing_tier_rank('pro')>sdi_private.billing_tier_rank('creator') and sdi_private.billing_tier_rank('creator')>sdi_private.billing_tier_rank('free'),'tier rank order');
 perform sdi_test.login(member);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='unlimited' and (r->>'in_trial')::boolean=false,'unlimited ranks highest for the member: '||r::text);
 perform sdi_test.logout();
 perform sdi_test.login(directory,'aal2');
 r:=sdi_private.users_action('list',query=>'tiers-member');
 select x into item from jsonb_array_elements(r->'users') x where (x->>'id')::uuid=member;
 perform sdi_test.check(item->>'plan'='unlimited','admin directory shows the highest tier: '||coalesce(item::text,r::text));
 perform sdi_test.logout();
 r:=sdi_private.spatter_usage_plan(member);
 perform sdi_test.check(r->>'plan'='unlimited' and (r->>'unlimited')::boolean,'Spatter meters the highest tier: '||r::text);
 -- Unlimited ends: pro is next.
 perform sdi_private.billing_apply_event('apple','tiers-4','EXPIRED',clock_timestamp()-interval '2 minutes','{}',member,'orig-tu',
  'com.willisbmb.StickDeathInfinity.unlimited.monthly','expired',clock_timestamp()-interval '1 second');
 perform sdi_test.login(member);
 perform sdi_test.check(sdi_private.my_entitlement()->>'tier'='pro','pro outranks creator');
 perform sdi_test.logout();

 -- Free trial: recorded from the verified event, visible to member and finance.
 ev:=sdi_private.billing_apply_event('apple','tiers-t1','SUBSCRIBED',clock_timestamp()-interval '2 minutes','{}',trial,'orig-trial',
  'com.willisbmb.StickDeathInfinity.creator.monthly','trialing',clock_timestamp()+interval '3 days',in_trial=>true);
 perform sdi_test.check(ev->>'outcome'='applied','trial event applied: '||ev::text);
 perform sdi_test.login(trial);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='creator' and r->>'status'='trialing' and (r->>'in_trial')::boolean,'member sees the trial: '||r::text);
 r:=sdi_private.spatter_my_usage();
 perform sdi_test.check(r->>'plan'='creator' and (r->>'trial')::boolean and (r->>'available')::boolean=false and (r->>'remaining')::integer=0,
  'Spatter is preview-only in the trial: '||r::text);
 perform sdi_test.logout();
 perform sdi_test.login(finance,'aal2');
 r:=sdi_private.finance_admin('subscriptions');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'subscriptions') x where x->>'product_id'='com.willisbmb.StickDeathInfinity.creator.monthly'
  and (x->>'user_id')::uuid=trial and (x->>'in_trial')::boolean),'finance sees the trial flag: '||r::text);
 perform sdi_test.logout();
 -- An event that does not report a trial (null) records a paid period; a
 -- billing-retry event that reports the trial keeps it.
 perform sdi_private.billing_apply_event('apple','tiers-t2','DID_FAIL_TO_RENEW',clock_timestamp()-interval '1 minute','{}',trial,'orig-trial',
  'com.willisbmb.StickDeathInfinity.creator.monthly','grace',clock_timestamp()+interval '4 days',in_trial=>true);
 perform sdi_test.check((select in_trial from sdi_private.entitlements where user_id=trial),'grace after an unpaid trial is still a trial');
 perform sdi_private.billing_apply_event('apple','tiers-t3','DID_RENEW',clock_timestamp(),'{}',trial,'orig-trial',
  'com.willisbmb.StickDeathInfinity.creator.monthly','active',paid);
 perform sdi_test.login(trial);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'status'='active' and (r->>'in_trial')::boolean=false,'first paid period clears the trial: '||r::text);
 r:=sdi_private.spatter_my_usage();
 perform sdi_test.check(r->>'plan'='creator' and (r->>'trial')::boolean=false and (r->>'limit')::integer=250 and (r->>'remaining')::integer=250,
  'converted creator has 250 per period: '||r::text);
 perform sdi_test.logout();
end $$;
rollback;
