-- Local assertions for spatter-draft-jobs.sql (#212 queue state machine behind the
-- agent gate, #214 storyboard/source-digest binding and approval invalidation).
begin;
do $$
declare owner uuid; viewer uuid; member uuid; r jsonb; rev bigint; job uuid; review uuid; today date:=(clock_timestamp() at time zone 'utc')::date;
 sha text:=repeat('ab',32); digest text:=repeat('cd',32); brief jsonb:='{"text":"A red stick figure walks left to right, then falls; 3 seconds; seed 11."}';
 story jsonb:='{"schema":"spatter_storyboard","version":1,"frameCount":40}'; quality jsonb:='{"passes":true,"findings":[]}';
begin
 owner:=sdi_test.admin('draft-owner',true,array[]::text[]); viewer:=sdi_test.admin('draft-viewer',false,array['reviews']); member:=sdi_test.user('draft-member');

 -- Agent paused: nothing can be claimed; the job row exists as planned, never as success.
 r:=sdi_private.spatter_draft_claim(today,'worker-a',11,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean=false and r->>'reason'='Agent is paused.','claim refused while the agent is paused: '||r::text);
 perform sdi_test.check((select state from sdi_private.spatter_draft_jobs where target_date=today)='planned','paused claim leaves a planned job');

 -- Owner enables the agent exactly as in agent-controls.
 perform sdi_test.login(owner,'aal2');
 select revision into rev from sdi_private.agents where key='spatter_daily_video';
 r:=sdi_private.agent_admin('publish_instructions','spatter_daily_video',rev,'{"body":"One private draft per day. Never publish."}','Initial.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('set_caps','spatter_daily_video',rev,'{"daily_run_cap":"3","per_run_item_cap":"1","monthly_cost_cap_minor":"0"}','Caps.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('resume','spatter_daily_video',rev,'{}','Enable drafts.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed','agent resumed');

 -- Monthly cost cap of 0 blocks; raise it and claim.
 r:=sdi_private.spatter_draft_claim(today,'worker-a',11,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean=false and r->>'reason'='Monthly cost cap reached.','zero cost cap blocks the claim');
 r:=sdi_private.agent_admin('set_caps','spatter_daily_video',rev,'{"daily_run_cap":"3","per_run_item_cap":"1","monthly_cost_cap_minor":"100"}','Allow local work.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.spatter_draft_claim(today,'worker-a',11,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean and (r->>'attempt')::integer=1 and r->'brief'=brief and (r->>'planner_seed')::bigint=11,'first claim succeeds: '||r::text);
 job:=(r->>'job')::uuid;
 -- Deduplication: a second worker for the same day cannot claim or recreate the job.
 r:=sdi_private.spatter_draft_claim(today,'worker-b',99,'briefs.v2','{"text":"other"}');
 perform sdi_test.check((r->>'claimed')::boolean=false and r->>'reason'='Job is claimed.' and (r->>'job')::uuid=job,'second claim is refused, no duplicate job');
 perform sdi_test.check((select count(*) from sdi_private.spatter_draft_jobs where target_date=today)=1 and (select planner_seed from sdi_private.spatter_draft_jobs where id=job)=11,'target_date is unique and the first seed is kept');

 -- Only the lease holder progresses; transitions are forward-only.
 r:=sdi_private.spatter_draft_progress(job,'worker-b','rendering');
 perform sdi_test.check(r->>'status'='refused','non-holder cannot progress');
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,quality,sha,'',jsonb_build_object('creator',owner,'preview_url','https://private.example/draft.mp4','source_project_digest',digest));
 perform sdi_test.check(r->>'status'='refused','cannot skip rendering');
 r:=sdi_private.spatter_draft_progress(job,'worker-a','rendering',story);
 perform sdi_test.check(r->>'status'='confirmed','claimed → rendering');
 -- A failing quality report cannot enter review; it must be a failure with the finding.
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,'{"passes":false,"findings":["blank frame"]}',sha,'',jsonb_build_object('creator',owner,'preview_url','https://private.example/draft.mp4','source_project_digest',digest));
 perform sdi_test.check(r->>'status'='refused' and r->>'reason' like 'The quality report did not pass%','failing quality report refused');
 r:=sdi_private.spatter_draft_progress(job,'worker-a','failed',null,'{"passes":false,"findings":["blank frame"]}',null,'Quality gate: 1 blank frame.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.spatter_draft_jobs where id=job)='failed','rendering → failed records the finding');
 perform sdi_test.check((select state from sdi_private.agent_runs where id=(select agent_run from sdi_private.spatter_draft_jobs where id=job))='failed','agent run finished as failed');

 -- Retry: failed jobs are reclaimable up to three attempts, through the gate again.
 r:=sdi_private.spatter_draft_claim(today,'worker-a',11,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean and (r->>'attempt')::integer=2,'failed job reclaimed as attempt 2: '||r::text);
 r:=sdi_private.spatter_draft_progress(job,'worker-a','rendering',story);
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,quality,sha,'',jsonb_build_object('creator',owner,'preview_url','https://private.example/draft.mp4','source_project_digest',digest,'title','Daily draft'));
 perform sdi_test.check(r->>'status'='confirmed' and r->>'state'='review_pending','rendering → review_pending with a review row: '||r::text);
 review:=(r->>'review')::uuid;
 perform sdi_test.check((select spatter_generated and state='pending' and render_digest=sha and storyboard=story and source_project_digest=digest and cardinality(destinations)=0
  from sdi_private.render_reviews where id=review),'review binds digest, storyboard and source digest, no destinations yet');
 perform sdi_test.check((select state from sdi_private.agent_runs where id=(select agent_run from sdi_private.spatter_draft_jobs where id=job))='succeeded','agent run finished as succeeded');
 perform sdi_test.check((select count(*) from sdi_private.agent_runs where agent_key='spatter_daily_video')=2,'exactly one agent run per attempt');
 -- Nobody can claim a review-pending job again.
 r:=sdi_private.spatter_draft_claim(today,'worker-c',11,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean=false and r->>'reason'='Job is review_pending.','review-pending job is not reclaimable');

 -- Approval needs destinations; a storyboard change afterwards invalidates approval (#214).
 update sdi_private.render_reviews set destinations=array['feed'] where id=review;
 select version into rev from sdi_private.render_reviews where id=review;
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Looks right.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.render_reviews where id=review)='approved','owner approved the exact digest');
 perform sdi_test.check(sdi_private.spatter_draft_sweep()>=1,'sweep touched the approved job');
 perform sdi_test.check((select state from sdi_private.spatter_draft_jobs where id=job)='approved','sweep copies the review outcome to the job');
 update sdi_private.render_reviews set storyboard=story||'{"frameCount":41}' where id=review;
 perform sdi_test.check((select state='pending' and version=rev+1 from sdi_private.render_reviews where id=review),'storyboard change returned the review to pending with a new version');
 update sdi_private.render_reviews set source_project_digest=repeat('ef',32) where id=review;
 perform sdi_test.check((select version=rev+2 from sdi_private.render_reviews where id=review),'source digest change bumps the version again');

 -- Missed days are recorded, never back-filled; status shows them to review admins only.
 r:=sdi_private.spatter_draft_claim(today-1,'worker-a',10,'briefs.v2',brief);
 perform sdi_test.check((r->>'claimed')::boolean=false and r->>'reason' like 'The target date has passed%','past dates cannot be claimed');
 insert into sdi_private.spatter_draft_jobs(target_date,planner_seed,brief_version,brief) values(today-2,9,'briefs.v2',brief);
 perform sdi_private.spatter_draft_sweep();
 perform sdi_test.check((select state from sdi_private.spatter_draft_jobs where target_date=today-2)='missed','old planned job becomes missed');
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.spatter_draft_status(today-3,today);
 perform sdi_test.check(jsonb_array_length(r->'days')=4 and r->'days'->0->>'state'='missed' and r->'days'->2->>'state'='missed' and r->'days'->3->>'state'='approved'
  and r->>'capacity' like 'owner-gated%','status lists missed and unplanned days truthfully: '||r::text);
 r:=sdi_private.spatter_draft_status(today-100,today);
 perform sdi_test.check(r->>'error' like 'Choose a range%','status range is bounded');
 perform sdi_test.login(member);
 r:=sdi_private.spatter_draft_status(today-1,today);
 perform sdi_test.check(r->>'error' like 'Current video-review permission%','members cannot read the queue');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_spatter_draft_claim(current_date,''x'',1,''v'',''{}'')'),'clients cannot claim draft jobs');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_spatter_draft_progress(gen_random_uuid(),''x'',''failed'')'),'clients cannot progress draft jobs');
end $$;

-- #209 cloud-advice metering: Free refused (upgrade_required), Creator's
-- break-even cost model, safety/rate/global limits, emergency stop,
-- exactly-once settlement and owner-only limit changes.
do $$
declare owner uuid; viewer uuid; free_user uuid; creator uuid; pro uuid; banned uuid; trial_c uuid; trial_p uuid; r jsonb; rid uuid; i integer; rev bigint;
 paid timestamptz:=date_trunc('second',clock_timestamp())+interval '20 days';
begin
 owner:=sdi_test.admin('meter-owner',true,array[]::text[]); viewer:=sdi_test.admin('meter-viewer',false,array['overview']);
 free_user:=sdi_test.user('meter-free'); creator:=sdi_test.user('meter-creator'); pro:=sdi_test.user('meter-pro'); banned:=sdi_test.user('meter-banned');
 insert into sdi_private.billing_products(product_id,provider,tier,period,approved) values('meter.creator','stripe','creator','monthly',true),('meter.pro','stripe','pro','monthly',true);
 insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,last_event_at)
  values(creator,'stripe','sub_meter_c','meter.creator','active',paid,clock_timestamp()),(pro,'stripe','sub_meter_p','meter.pro','active',paid,clock_timestamp());
 insert into sdi_private.account_controls(user_id,state,reason) values(banned,'suspended','Test.');

 -- Closed by default: the global ceiling is 0 until the owner sets it.
 r:=sdi_private.spatter_usage_meter('reserve',creator,p_suggested_prompt=>'animation_tips');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='global_limit','global ceiling defaults closed: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.spatter_usage_reservations)=0,'a refusal reserves nothing');

 -- Only the owner changes limits, with revision, reason and audit.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.spatter_usage_admin('get');
 perform sdi_test.check((r->'controls'->>'creator_period_budget_microusd')::integer=3490000 and (r->'controls'->>'prompt_cost_estimate_microusd')::integer=20000
  and (r->>'creator_period_limit')::integer=174 and not (r->'controls') ? 'free_prompts' and not (r->'controls') ? 'creator_period_prompts',
  'defaults match the owner decision (USD 4.99 net of 30% / USD 0.02 = 174): '||r::text);
 rev:=(r->'controls'->>'revision')::bigint;
 r:=sdi_private.spatter_usage_admin('set',rev,'{"global_daily_cap":100}','Open.');
 perform sdi_test.check(r->>'error'='Only the owner can change Spatter limits.','non-owner admin cannot change limits');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"global_daily_cap":100,"user_per_minute_cap":3}','');
 perform sdi_test.check(r->>'error'='A reason is required.','reason required');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"bogus":1}','x');
 perform sdi_test.check(r->>'error'='Unknown limit.','unknown keys refused');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"free_prompts":5}','x');
 perform sdi_test.check(r->>'error'='Unknown limit.','retired free allowance is not settable');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"creator_period_prompts":15}','x');
 perform sdi_test.check(r->>'error'='Unknown limit.','retired fixed creator count is not settable');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"global_daily_cap":-1}','x');
 perform sdi_test.check(r->>'error'='A limit is outside its allowed range.','range enforced');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"prompt_cost_estimate_microusd":0}','x');
 perform sdi_test.check(r->>'error'='A limit is outside its allowed range.','zero cost estimate refused');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"creator_period_budget_microusd":4990001}','x');
 perform sdi_test.check(r->>'error'='A limit is outside its allowed range.','creator budget cannot exceed the USD 4.99 price');
 perform sdi_test.check((select revision from sdi_private.spatter_usage_controls)=rev,'refused changes leave the revision unchanged');
 r:=sdi_private.spatter_usage_admin('set',rev,'{"global_daily_cap":100,"user_per_minute_cap":3}','Open for local test.');
 perform sdi_test.check(r->>'status'='confirmed' and (r->>'revision')::bigint=rev+1,'owner set limits: '||r::text);
 r:=sdi_private.spatter_usage_admin('set',rev,'{"global_daily_cap":5}','Stale.');
 perform sdi_test.check(r->>'error' like 'Limits changed elsewhere%','stale revision refused');
 perform sdi_test.check(exists(select 1 from sdi_private.agent_audit where agent_key='spatter_advice' and actor=owner),'limit change audited');
 perform sdi_test.logout();

 -- Free (owner decision 2026-10-15): Spatter is visible but never served.
 -- Every Free request, suggested prompt or free text, is refused with
 -- upgrade_required before anything is counted or reserved.
 r:=sdi_private.spatter_usage_meter('reserve',free_user);
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='upgrade_required' and r->>'plan'='free' and r->>'upgrade'='creator_or_pro','free text refused on Free: '||r::text);
 r:=sdi_private.spatter_usage_meter('reserve',free_user,p_suggested_prompt=>'animation_tips');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='upgrade_required','suggested prompt refused on Free: '||r::text);
 r:=sdi_private.spatter_usage_meter('reserve',free_user,p_suggested_prompt=>'write my essay');
 perform sdi_test.check(r->>'code'='upgrade_required','unknown id on Free is still upgrade_required: '||r::text);
 perform sdi_test.check(not exists(select 1 from sdi_private.spatter_usage_counters where user_id=free_user)
  and not exists(select 1 from sdi_private.spatter_usage_reservations where user_id=free_user),'Free counts and reserves nothing');
 perform sdi_test.check((select coalesce(sum(used),0) from sdi_private.spatter_usage_global)=0,'Free spends nothing globally');
 perform sdi_test.check(sdi_private.spatter_suggested_prompt_ids()=array['animation_tips','scene_ideas','fight_choreography','style_advice'],'suggested prompt allowlist');
 -- A paid plan may send a suggested prompt or free text; unknown ids are refused.
 r:=sdi_private.spatter_usage_meter('reserve',creator,p_suggested_prompt=>'write my essay');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='unknown_suggested_prompt','unknown suggested prompt refused: '||r::text);
 -- Per-minute rate applies (cap 3).
 for i in 1..3 loop r:=sdi_private.spatter_usage_meter('reserve',creator,p_suggested_prompt=>'scene_ideas');
  perform sdi_test.check((r->>'allowed')::boolean and r->>'plan'='creator' and (r->>'remaining')::integer=174-i and r->>'period'='billing_period'
   and (r->>'resets_at')::timestamptz=paid,'creator reserve '||i||': '||r::text);
  perform sdi_private.spatter_usage_meter('settle',null,(r->>'reservation')::uuid,'commit',3);
 end loop;
 r:=sdi_private.spatter_usage_meter('reserve',creator,p_suggested_prompt=>'scene_ideas');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='rate_limited' and (r->>'retry_after_seconds')::integer between 1 and 60,'per-minute rate enforced: '||r::text);
 update sdi_private.spatter_usage_counters set used=0 where user_id=creator and bucket like 'minute:%';

 -- Release refunds every counter exactly once; a second settlement is refused.
 r:=sdi_private.spatter_usage_meter('reserve',creator);
 perform sdi_test.check((r->>'allowed')::boolean and r->>'plan'='creator' and (r->>'remaining')::integer=170 and r->>'period'='billing_period'
  and (r->>'resets_at')::timestamptz=paid,'creator has 174 per billing period by default: '||r::text);
 rid:=(r->>'reservation')::uuid;
 r:=sdi_private.spatter_usage_meter('settle',null,rid,'release');
 perform sdi_test.check(r->>'state'='released','release confirmed');
 r:=sdi_private.spatter_usage_meter('settle',null,rid,'commit',5);
 perform sdi_test.check(r->>'status'='refused','double settlement refused');
 perform sdi_test.check((select used from sdi_private.spatter_usage_counters where user_id=creator and bucket like 'period:%')=3,'release refunded the period bucket');
 perform sdi_test.check((select used from sdi_private.spatter_usage_global where day=(clock_timestamp() at time zone 'utc')::date)=3,'global counter equals committed prompts');
 -- The owner's cost model drives the Creator limit: floor(budget / estimate).
 perform sdi_test.login(owner,'aal2');
 rev:=(sdi_private.spatter_usage_admin('get')->'controls'->>'revision')::bigint;
 r:=sdi_private.spatter_usage_admin('set',rev,'{"prompt_cost_estimate_microusd":100000}','Provider got pricier.');
 perform sdi_test.check(r->>'status'='confirmed','owner set cost estimate: '||r::text);
 r:=sdi_private.spatter_usage_admin('get');
 perform sdi_test.check((r->>'creator_period_limit')::integer=34,'3490000/100000 rounds down to 34: '||r::text);
 perform sdi_test.check((sdi_private.spatter_usage_plan(creator)->>'limit')::integer=34 and (sdi_private.spatter_usage_plan(creator)->>'remaining')::integer=31,
  'creator limit follows the estimate: '||sdi_private.spatter_usage_plan(creator)::text);
 r:=sdi_private.spatter_usage_admin('set',(r->'controls'->>'revision')::bigint,'{"creator_period_budget_microusd":1000000}','Lower budget.');
 perform sdi_test.check(r->>'status'='confirmed','owner set budget: '||r::text);
 perform sdi_test.check((sdi_private.spatter_usage_admin('get')->>'creator_period_limit')::integer=10,'1000000/100000 = 10');
 perform sdi_test.check(exists(select 1 from sdi_private.agent_audit where agent_key='spatter_advice' and actor=owner and action like '%prompt_cost_estimate_microusd%')
  and exists(select 1 from sdi_private.agent_audit where agent_key='spatter_advice' and actor=owner and action like '%creator_period_budget_microusd%'),'cost model changes audited');
 perform sdi_test.logout();
 -- Creator period exhaustion; a renewal (new paid_through) opens a new period.
 update sdi_private.spatter_usage_counters set used=10 where user_id=creator and bucket like 'period:%';
 r:=sdi_private.spatter_usage_meter('reserve',creator);
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='plan_allowance_exhausted' and r->>'upgrade'='pro','creator period exhausted, upgrade to pro: '||r::text);
 update sdi_private.subscriptions set paid_through=paid+interval '1 month' where user_id=creator;
 r:=sdi_private.spatter_usage_meter('reserve',creator);
 perform sdi_test.check((r->>'allowed')::boolean and (r->>'remaining')::integer=9,'renewal starts a fresh period: '||r::text);

 -- Pro: no plan allowance, but the daily safety cap still applies.
 r:=sdi_private.spatter_usage_meter('reserve',pro);
 perform sdi_test.check((r->>'allowed')::boolean and r->>'plan'='pro' and r->'remaining'='null'::jsonb,'pro is unlimited by plan: '||r::text);
 insert into sdi_private.spatter_usage_counters(user_id,bucket,used) values(pro,'day:'||((clock_timestamp() at time zone 'utc')::date)::text,100)
  on conflict(user_id,bucket) do update set used=100;
 update sdi_private.spatter_usage_counters set used=0 where user_id=pro and bucket like 'minute:%';
 r:=sdi_private.spatter_usage_meter('reserve',pro);
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'code'='daily_safety_limit','pro still hits the daily safety cap: '||r::text);

 -- The free trial applies to both paid plans: a trialing subscription meters as its own tier.
 trial_c:=sdi_test.user('meter-trial-creator'); trial_p:=sdi_test.user('meter-trial-pro');
 insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,last_event_at)
  values(trial_c,'stripe','sub_meter_tc','meter.creator','trialing',paid,clock_timestamp()),(trial_p,'stripe','sub_meter_tp','meter.pro','trialing',paid,clock_timestamp());
 r:=sdi_private.spatter_usage_meter('reserve',trial_c);
 perform sdi_test.check((r->>'allowed')::boolean and r->>'plan'='creator' and (r->>'remaining')::integer=9,'creator trial meters as Creator with free text: '||r::text);
 r:=sdi_private.spatter_usage_meter('reserve',trial_p);
 perform sdi_test.check((r->>'allowed')::boolean and r->>'plan'='pro' and r->'remaining'='null'::jsonb,'pro trial meters as Pro: '||r::text);

 -- Restricted accounts and the emergency stop refuse before counting.
 r:=sdi_private.spatter_usage_meter('reserve',banned);
 perform sdi_test.check(r->>'code'='account_restricted','suspended account refused');
 r:=sdi_private.spatter_usage_meter('reserve',gen_random_uuid());
 perform sdi_test.check(r->>'code'='unauthorized','unknown account refused');
 update sdi_private.agent_global set emergency_stop=true,reason='Test stop.';
 r:=sdi_private.spatter_usage_meter('reserve',creator);
 perform sdi_test.check(r->>'code'='emergency_stop','emergency stop refuses Spatter advice');
 update sdi_private.agent_global set emergency_stop=false,reason='';

 -- Own allowance view for Settings; global numbers are not exposed to members.
 perform sdi_test.login(creator);
 r:=sdi_private.spatter_my_usage();
 perform sdi_test.check(r->>'plan'='creator' and (r->>'remaining')::integer=9 and (r->>'limit')::integer=10 and r->>'service'='metered' and not r ? 'bucket','own usage view: '||r::text);
 r:=sdi_private.spatter_usage_admin('get');
 perform sdi_test.check(r->>'error' like 'Current administrator%','members cannot read global usage');
 perform sdi_test.logout();
 perform sdi_test.login(free_user);
 r:=sdi_private.spatter_my_usage();
 perform sdi_test.check(r->>'plan'='free' and (r->>'limit')::integer=0 and (r->>'remaining')::integer=0 and (r->>'available')::boolean=false
  and r->>'upgrade'='creator_or_pro','free usage view says upgrade, never an allowance: '||r::text);
 perform sdi_test.logout();
 r:=sdi_private.spatter_my_usage();
 perform sdi_test.check(r->>'error' like 'Sign in%','anonymous caller sees no allowance');

 -- Stale reservations stay counted; client roles cannot meter.
 update sdi_private.spatter_usage_reservations set created_at=clock_timestamp()-interval '1 hour' where state='reserved';
 r:=sdi_private.spatter_usage_meter('sweep');
 perform sdi_test.check((r->>'touched')::integer>=1 and not exists(select 1 from sdi_private.spatter_usage_reservations where state='reserved'),'sweep settles stale reservations as committed');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_spatter_usage_meter(''reserve'',gen_random_uuid())'),'clients cannot reserve prompts');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_spatter_my_usage()'),'anon cannot read usage');
end $$;
rollback;
