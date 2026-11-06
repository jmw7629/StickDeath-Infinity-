-- Owner review path for Spatter daily drafts (#212): a retained draft copy is
-- recorded with the review, the owner alone renews its preview and may approve it
-- with no destinations ("approved, not scheduled"), and nothing can be released.
begin;
do $$
declare owner uuid; viewer uuid; r jsonb; unavailable jsonb; rev bigint; job uuid; review uuid; bare uuid; permit uuid;
 ordinary uuid; absent uuid:=gen_random_uuid(); choice text; today date:=(clock_timestamp() at time zone 'utc')::date;
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

 -- An ordinary submission stays visible and actionable for delegated reviewers.
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(owner,'Ordinary upload','rev1',repeat('34',32),'https://intake.example.test/ordinary',clock_timestamp()+interval '1 day','terms-v1','Own work',true,array['feed']) returning id into ordinary;
 perform sdi_test.login(viewer,'aal2');
 r:=public.sdi_review_action('list');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'reviews') item where item->>'id'=ordinary::text
  and item->>'preview_url'='https://intake.example.test/ordinary'),'delegated reviewer still receives the ordinary upload preview');
 perform sdi_test.check(not exists(select 1 from jsonb_array_elements(r->'reviews') item where item->>'id'=review::text)
  and position((base->>'preview_url') in r::text)=0,'delegated queue omits the daily row and its signed link');
 r:=public.sdi_review_action('decide',ordinary,repeat('34',32),1,'approved','Ordinary upload is eligible.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.render_reviews where id=ordinary)='approved',
  'delegated reviewer can still approve a normal upload');

 -- Direct probes must reveal no more about a daily draft than an absent ID.
 r:=public.sdi_preview_permit(review,sha,rev);
 unavailable:=public.sdi_preview_permit(absent,sha,rev);
 perform sdi_test.check(r=unavailable and r->>'error'='This review changed or is unavailable.',
  'a non-owner cannot obtain a permit or distinguish a private draft from an absent review');
 foreach choice in array array['approved','rejected','changes'] loop
  r:=public.sdi_review_action('decide',review,sha,rev,choice,'Delegated moderator probe.');
  unavailable:=public.sdi_review_action('decide',absent,sha,rev,choice,'Delegated moderator probe.');
  perform sdi_test.check(r=unavailable and r ? 'error','all private draft decisions have the same response as an absent review');
 end loop;
 perform sdi_test.check((select state from sdi_private.render_reviews where id=review)='pending'
  and not exists(select 1 from sdi_private.render_decisions d where d.review_id=review),'delegated decisions make no change');
 r:=public.sdi_review_rights(review,sha,rev,false,'Delegated rights probe.');
 unavailable:=public.sdi_review_rights(absent,sha,rev,false,'Delegated rights probe.');
 perform sdi_test.check(r=unavailable and r ? 'error','daily draft rights decisions reveal no review existence');

 -- Expiry changes playback eligibility, not the durable privacy boundary.
 update sdi_private.render_artifacts set expires_at=clock_timestamp()-interval '1 second' where review_id=review;
 perform sdi_test.check(not sdi_private.review_spatter_draft_retained(review),'fixture expired the retained copy');
 r:=public.sdi_review_action('list');
 perform sdi_test.check(not exists(select 1 from jsonb_array_elements(r->'reviews') item where item->>'id'=review::text),
  'daily draft stays private after retention expires');
 update sdi_private.render_artifacts set expires_at=clock_timestamp()+interval '7 days' where review_id=review;

 perform sdi_test.login(owner,null);
 perform sdi_test.check(public.sdi_review_action('list') ? 'error' and public.sdi_preview_permit(review,sha,rev) ? 'error',
  'owner with a live session and missing MFA claim receives neither list nor permit');
 perform sdi_test.check(public.sdi_review_action('decide',review,sha,rev,'changes','Missing MFA.') ? 'error',
  'a missing MFA claim cannot change the daily draft');
 perform sdi_test.login(owner,'aal2');
 r:=public.sdi_review_action('list');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'reviews') item where item->>'id'=review::text
  and item->>'preview_url'=base->>'preview_url'),'MFA owner receives the exact draft and its signed link');
 r:=public.sdi_preview_permit(review,null,rev);
 perform sdi_test.check(r ? 'error','permit requires a non-null exact digest');
 r:=sdi_private.preview_permit(review,repeat('ee',32),rev);
 perform sdi_test.check(r ? 'error','permit needs the exact digest');
 r:=sdi_private.preview_permit(review,sha,rev);
 perform sdi_test.check((r->>'upload')::uuid=upload and (r->>'creator')::uuid=owner and (r->>'byte_count')::bigint=5120 and r->>'digest'=sha,'owner permit names the draft copy: '||r::text);
 permit:=(r->>'permit')::uuid;
 update sdi_private.admin_roles set owner=false,permissions=array['reviews'] where user_id=(auth.uid());
 r:=sdi_private.preview_renew(permit,'https://intake.example.test/v1/render-previews/renewed',clock_timestamp()+interval '10 minutes');
 perform sdi_test.check(r->>'error'='Render authorization or retention changed.'
  and (select preview_url from sdi_private.render_reviews where id=review)=base->>'preview_url',
  'an outstanding permit cannot renew the draft after the actor loses owner status');
 update sdi_private.admin_roles set owner=true,permissions=array[]::text[] where user_id=(auth.uid());
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
 r:=public.sdi_review_history(0);
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'decisions') item where item->>'review_id'=review::text),
  'MFA owner can read the draft decision history');
 perform sdi_test.login(viewer,'aal2');
 r:=public.sdi_review_history(0);
 perform sdi_test.check(not exists(select 1 from jsonb_array_elements(r->'decisions') item where item->>'review_id'=review::text)
  and exists(select 1 from jsonb_array_elements(r->'decisions') item where item->>'review_id'=ordinary::text),
  'delegated history omits the draft while retaining ordinary moderation');
 perform sdi_test.login(owner,'aal2');
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
 perform sdi_test.login(viewer,'aal2');
 r:=public.sdi_review_action('list');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'reviews') item where item->>'id'=bare::text),
  'Spatter-tagged creator uploads remain visible to delegated reviewers');
 r:=public.sdi_review_action('decide',bare,repeat('12',32),rev,'changes','Needs ordinary moderation follow-up.');
 perform sdi_test.check(r->>'status'='confirmed','delegated reviewer retains non-approval moderation of a Spatter-tagged creator upload');
 perform sdi_test.check(sdi_test.denied('authenticated','select sdi_private.review_is_daily_spatter_draft(gen_random_uuid())'),
  'clients cannot call the private draft identity helper');
 perform sdi_test.check(sdi_test.denied('authenticated','select sdi_private.review_spatter_draft_retained(gen_random_uuid())'),'clients cannot call the draft helper');
end $$;
rollback;
