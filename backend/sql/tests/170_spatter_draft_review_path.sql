-- Owner review path for Spatter daily drafts (#212): a retained draft copy is
-- recorded with the review, the owner alone renews its preview and may approve it
-- with no destinations ("approved, not scheduled"), and nothing can be released.
begin;
do $$
declare owner uuid; viewer uuid; r jsonb; rev bigint; job uuid; review uuid; bare uuid; permit uuid; today date:=(clock_timestamp() at time zone 'utc')::date;
 sha text:=repeat('ab',32); digest text:=repeat('cd',32); upload uuid:='3f1c2b9a-6d4e-4f7a-8b2c-1d0e9f8a7b6c';
 brief jsonb:='{"text":"A red stick figure walks left to right, then falls; 3 seconds; seed 11."}';
 story jsonb:='{"schema":"spatter_storyboard","version":1,"frameCount":40}'; quality jsonb:='{"passes":true,"findings":[]}';
 base jsonb;
begin
 owner:=sdi_test.admin('draft-path-owner',true,array[]::text[]); viewer:=sdi_test.admin('draft-path-viewer',false,array['reviews']);
 perform sdi_test.login(owner,'aal2');
 select revision into rev from sdi_private.agents where key='spatter_daily_video';
 r:=sdi_private.agent_admin('publish_instructions','spatter_daily_video',rev,'{"body":"One private draft per day. Never publish."}','Initial.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('set_caps','spatter_daily_video',rev,'{"daily_run_cap":"3","per_run_item_cap":"1","monthly_cost_cap_minor":"100"}','Caps.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('resume','spatter_daily_video',rev,'{}','Enable drafts.');
 perform sdi_test.check(r->>'status'='confirmed','agent resumed');

 r:=sdi_private.spatter_draft_claim(today,'worker-a',11,'briefs.v3',brief); job:=(r->>'job')::uuid;
 perform sdi_test.check((r->>'claimed')::boolean,'claimed: '||r::text);
 r:=sdi_private.spatter_draft_progress(job,'worker-a','rendering',story);
 base:=jsonb_build_object('creator',owner,'preview_url','https://intake.example.test/v1/render-previews/x','source_project_digest',digest,
  'preview_expires_at',(clock_timestamp()+interval '10 minutes')::text);
 -- A malformed or over-long retained copy is refused before any review row exists.
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,quality,sha,'',base||jsonb_build_object('object_key','../x.mp4','byte_count',10,'artifact_expires_at',(clock_timestamp()+interval '1 day')::text));
 perform sdi_test.check(r->>'status'='refused','bad object key refused: '||r::text);
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,quality,sha,'',base||jsonb_build_object('object_key',upload::text||'.mp4','byte_count',10,'artifact_expires_at',(clock_timestamp()+interval '30 days')::text));
 perform sdi_test.check(r->>'status'='refused' and r->>'reason' like '%14 days%','retention beyond 14 days refused');
 r:=sdi_private.spatter_draft_progress(job,'worker-a','review_pending',story,quality,sha,'',base||jsonb_build_object('object_key',upload::text||'.mp4','byte_count',5120,'artifact_expires_at',(clock_timestamp()+interval '7 days')::text));
 perform sdi_test.check(r->>'status'='confirmed','draft submitted with its retained copy: '||r::text);
 review:=(r->>'review')::uuid;
 perform sdi_test.check((select a.object_key=upload::text||'.mp4' and a.byte_count=5120 and a.version=1 and a.render_digest=sha and not a.made_for_kids
  from sdi_private.render_artifacts a where a.review_id=review),'retained-render record binds the exact digest and copy');
 perform sdi_test.check((select preview_expires_at<=clock_timestamp()+interval '11 minutes' and cardinality(destinations)=0 and rights_cleared
  from sdi_private.render_reviews where id=review),'review carries the short link expiry, no destinations and the owner''s rights record');
 perform sdi_test.check(sdi_private.review_spatter_draft_retained(review),'helper recognizes a retained draft');
 select version into rev from sdi_private.render_reviews where id=review;

 -- Preview renewal: owner only, through the existing permit → host signer → renew path.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.preview_permit(review,sha,rev);
 perform sdi_test.check(r->>'error'='Owner review is required for this render.','a non-owner reviewer cannot renew a draft preview: '||r::text);
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Not mine to approve.');
 perform sdi_test.check(r ? 'error' and (select state from sdi_private.render_reviews where id=review)='pending','a non-owner reviewer cannot approve a draft');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.preview_permit(review,repeat('ee',32),rev);
 perform sdi_test.check(r ? 'error','permit needs the exact digest');
 r:=sdi_private.preview_permit(review,sha,rev);
 perform sdi_test.check((r->>'upload')::uuid=upload and (r->>'creator')::uuid=owner and (r->>'byte_count')::bigint=5120 and r->>'digest'=sha,'owner permit names the draft copy: '||r::text);
 permit:=(r->>'permit')::uuid;
 r:=sdi_private.preview_renew(permit,'https://intake.example.test/v1/render-previews/renewed',clock_timestamp()+interval '30 minutes');
 perform sdi_test.check(r->>'error'='Preview permission expired.','renewal beyond 15 minutes refused');
 r:=sdi_private.preview_renew(permit,'https://intake.example.test/v1/render-previews/renewed',clock_timestamp()+interval '10 minutes');
 perform sdi_test.check(r->>'preview_url'='https://intake.example.test/v1/render-previews/renewed'
  and (select preview_url from sdi_private.render_reviews where id=review)=r->>'preview_url','host signer installs the renewed owner link');
 perform sdi_test.check((select version from sdi_private.render_reviews where id=review)=rev,'a preview renewal does not change the reviewed version');

 -- Approval: owner, exact digest and version, unexpired preview; zero destinations = approved, not scheduled.
 r:=sdi_private.review_action('decide',review,repeat('ee',32),rev,'approved','Wrong bytes.');
 perform sdi_test.check(r ? 'error','approval needs the exact digest');
 update sdi_private.render_reviews set preview_expires_at=clock_timestamp()-interval '1 second' where id=review;
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Expired preview.');
 perform sdi_test.check(r ? 'error','approval needs an unexpired preview');
 update sdi_private.render_reviews set preview_expires_at=clock_timestamp()+interval '10 minutes' where id=review;
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Approved; not scheduled anywhere.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.render_reviews where id=review)='approved','owner approves the exact draft with no destinations: '||r::text);
 perform sdi_test.check((select d.destinations='{}' and d.owner_at_decision and d.render_digest=sha from sdi_private.render_decisions d where d.review_id=review and d.decision='approved'),'decision records the empty destination list');
 perform sdi_test.check(not sdi_private.release_allowed(review,rev,sha,'feed') and not sdi_private.release_allowed(review,rev,sha,'youtube')
  and not sdi_private.release_allowed(review,rev,sha,'social'),'an approved, unscheduled draft cannot be released anywhere');
 -- Choosing a destination later is a new version that needs a fresh owner approval.
 update sdi_private.render_reviews set destinations=array['youtube'] where id=review;
 perform sdi_test.check((select state='pending' and version=rev+1 from sdi_private.render_reviews where id=review),'adding a destination returns the draft to pending');
 perform sdi_test.check(not sdi_private.release_allowed(review,rev+1,sha,'youtube'),'no release before re-approval');

 -- A review that is not a retained Spatter draft still needs destinations.
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations,spatter_generated)
 values(owner,'Upload','rev1',repeat('12',32),'https://intake.example.test/u',clock_timestamp()+interval '1 day','terms-v1','Own work',true,'{}',true) returning id into bare;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,made_for_kids,expires_at)
 values(bare,1,repeat('12',32),'4a1c2b9a-6d4e-4f7a-8b2c-1d0e9f8a7b6c.mp4',1024,'Upload',false,clock_timestamp()+interval '1 day');
 select version into rev from sdi_private.render_reviews where id=bare;
 perform sdi_test.check(not sdi_private.review_spatter_draft_retained(bare),'an ordinary Spatter-flagged upload is not a draft');
 r:=sdi_private.review_action('decide',bare,repeat('12',32),rev,'approved','No destinations.');
 perform sdi_test.check(r ? 'error','non-draft approval with no destinations is still refused');
 perform sdi_test.check(sdi_test.denied('authenticated','select sdi_private.review_spatter_draft_retained(gen_random_uuid())'),'clients cannot call the draft helper');
end $$;
rollback;
