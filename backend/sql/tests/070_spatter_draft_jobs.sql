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
rollback;
