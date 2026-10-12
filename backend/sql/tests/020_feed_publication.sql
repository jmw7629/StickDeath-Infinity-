-- Local assertions for feed-publication.sql: the release gate and the feed path.
begin;
create function sdi_test.review(creator uuid, digest text, spatter boolean default false) returns uuid language plpgsql as $$
declare review uuid;
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations,spatter_generated)
 values(creator,'Render '||left(digest,6),'rev1',digest,'https://intake.example.test/'||left(digest,6),clock_timestamp()+interval '1 day','terms-v1','Own work',true,array['feed','youtube'],spatter)
 returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,left(digest,6)||'.mp4',1024,'Render '||left(digest,6),'A caption.',false,clock_timestamp()+interval '24 hours');
 return review;
end $$;
do $$
declare creator uuid; viewer uuid; reviewer uuid; owner uuid; review uuid; review2 uuid; spatter uuid;
 r jsonb; claimed jsonb; job uuid; token uuid; digest1 text:=repeat('1',64); digest2 text:=repeat('2',64); digest3 text:=repeat('3',64);
begin
 creator:=sdi_test.user('creator'); viewer:=sdi_test.user('viewer');
 reviewer:=sdi_test.admin('reviewer',false,array['reviews']); owner:=sdi_test.admin('owner',true,array[]::text[]);
 review:=sdi_test.review(creator,digest1);

 -- Without an approval decision nothing can be queued for the feed.
 perform sdi_test.login(creator);
 perform sdi_test.check(not sdi_private.release_allowed(review,1,digest1,'feed'),'release gate closed before approval');
 r:=sdi_private.publish_action('enqueue',review,'feed');
 perform sdi_test.check(r->>'error' is not null,'enqueue refused before approval: '||r::text);
 r:=sdi_private.creator_review('publish_feed',review,1);
 perform sdi_test.check(r->>'error' is not null,'creator publish_feed refused before approval');

 -- Approval of the exact digest by a reviewer with MFA opens the gate.
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',review,digest1,1,'approved','Looks fine.');
 perform sdi_test.check(r->>'status'='confirmed','reviewer approves: '||r::text);
 perform sdi_test.login(creator);
 perform sdi_test.check(sdi_private.release_allowed(review,1,digest1,'feed'),'release gate open after approval');
 r:=sdi_private.creator_review('publish_feed',review,1);
 perform sdi_test.check(r->>'status'='queued','feed job queued: '||r::text);
 r:=sdi_private.creator_review('list');
 perform sdi_test.check((r->'reviews'->0->>'can_publish_feed')::boolean,'creator list reports feed eligibility');

 -- Only the service role may run the worker operations.
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_feed_publish_claim()'),'authenticated cannot claim feed jobs');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_feed_publish_claim()'),'anon cannot claim feed jobs');
 execute 'set local role service_role';
 claimed:=public.sdi_feed_publish_claim();
 reset role;
 perform sdi_test.check(claimed->>'digest'=digest1 and claimed->>'object_key'='111111.mp4' and (claimed->>'allow_export')::boolean=false,'service claims the feed job: '||claimed::text);
 job:=(claimed->>'job')::uuid; token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,'http://insecure.example.test/a.mp4',10)=false,'insecure URL refused');
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,'https://media.example.test/'||digest1||'.mp4',10),'finish records the hosted copy');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=job)='published','job published');
 perform sdi_test.check((select count(*) from public.sdi_watch_media where render_digest=digest1 and approved and owner_id=creator)=1,'approved media row inserted with owner and digest');
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,'https://media.example.test/'||digest1||'.mp4',10),'finish is idempotent');

 -- Viewers see the post; export stays off until the creator explicitly allows it.
 perform sdi_test.login(viewer);
 r:=sdi_private.feed_action('list');
 perform sdi_test.check(jsonb_array_length(r->'posts')=1 and (r->'posts'->0->>'allow_export')::boolean=false,'post visible, export off: '||r::text);
 perform sdi_test.login(creator);
 r:=sdi_private.export_consent(review,1,true);
 perform sdi_test.check(r->>'status'='confirmed','creator grants export');
 perform sdi_test.check((select state from sdi_private.render_reviews where id=review)='approved','export consent does not invalidate approval');
 perform sdi_test.login(viewer);
 r:=sdi_private.feed_action('list');
 perform sdi_test.check((r->'posts'->0->>'allow_export')::boolean,'export permission reflected in feed');

 -- Approval revoked after claim: the hosted copy must be removed, never shown.
 review2:=sdi_test.review(creator,digest2);
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',review2,digest2,1,'approved','Fine.');
 perform sdi_test.login(creator);
 r:=sdi_private.publish_action('enqueue',review2,'feed');
 perform sdi_test.check(r->>'status'='queued','second job queued');
 claimed:=sdi_private.feed_publish_claim();
 job:=(claimed->>'job')::uuid; token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(claimed->>'digest'=digest2,'second job claimed');
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_rights(review2,digest2,1,false,'Rights dispute received.');
 perform sdi_test.check(r->>'status'='confirmed','rights revoked: '||r::text);
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,'https://media.example.test/'||digest2||'.mp4',10),'finish accepted for cleanup');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=job)='removal_pending','copy flagged for removal, not published');
 perform sdi_test.check(not exists(select 1 from public.sdi_watch_media where render_digest=digest2),'no media row for unapproved render');
 claimed:=sdi_private.feed_removal_claim();
 perform sdi_test.check(claimed->>'source'='publish_job' and claimed->>'digest'=digest2,'removal worker receives the hosted copy: '||claimed::text);
 perform sdi_test.check(sdi_private.feed_removal_finish('publish_job',(claimed->>'job')::uuid,(claimed->>'lease')::uuid,true),'removal confirmed');
 perform sdi_test.check((select state||'/'||coalesce(result_url,'-') from sdi_private.publish_jobs where id=job)='cancelled/-','removed copy recorded');

 -- Spatter renders need the owner; a reviewer alone cannot approve them.
 spatter:=sdi_test.review(creator,digest3,true);
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',spatter,digest3,1,'approved','Trying.');
 perform sdi_test.check(r->>'error' like 'Approval requires%','reviewer cannot approve Spatter render');
 perform sdi_test.check(not sdi_private.release_allowed(spatter,1,digest3,'feed'),'Spatter gate stays closed');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.review_action('decide',spatter,digest3,1,'approved','Owner approved exact render.');
 perform sdi_test.check(r->>'status'='confirmed','owner approves Spatter render');
 perform sdi_test.check(sdi_private.release_allowed(spatter,1,digest3,'feed'),'Spatter gate opens only with owner decision');

 -- A queued job whose approval lapsed before claim is cancelled, never leased.
 perform sdi_test.login(creator);
 r:=sdi_private.publish_action('enqueue',spatter,'feed');
 perform sdi_test.check(r->>'status'='queued','spatter job queued');
 r:=sdi_private.creator_review('withdraw_consent',spatter,1);
 perform sdi_test.check(r->>'status'='consent_withdrawn','consent withdrawn');
 claimed:=sdi_private.feed_publish_claim();
 perform sdi_test.check((claimed->>'empty')::boolean,'no feed job claimable after withdrawal');
 perform sdi_test.check(not exists(select 1 from sdi_private.publish_jobs where review_id=spatter and state in('queued','leased','published')),'withdrawn job not publishable');
end $$;
rollback;
