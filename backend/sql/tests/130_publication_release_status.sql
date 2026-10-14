-- Local assertions for the post-publication release (#190), creator status (#245)
-- and failure-reason sanitizing blocks of upload-retention.sql/publishing-admin.sql.
begin;
create function sdi_test.release_review(creator uuid, digest text, destinations text[]) returns uuid language plpgsql as $$
declare review uuid;
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(creator,'Render '||left(digest,6),'rev1',digest,'https://intake.example.test/'||left(digest,6),clock_timestamp()+interval '1 day','terms-v1','Own work',true,destinations)
 returning id into review;
 return review;
end $$;
create function sdi_test.release_upload(creator uuid, review uuid, digest text) returns uuid language plpgsql as $$
declare upload uuid:=gen_random_uuid();
begin
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,upload::text||'.mp4',1024,'Render','',false,clock_timestamp()+interval '24 hours');
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key)
 values(upload,creator,review,jsonb_build_object('sha256',digest),upload::text||'.mp4');
 return upload;
end $$;
do $$
declare creator uuid; other uuid; reviewer uuid; review uuid; social uuid; third uuid; upload uuid; social_upload uuid; third_upload uuid;
 r jsonb; claimed jsonb; feed_job uuid; yt_job uuid; token uuid; media uuid; job jsonb;
 d1 text:=repeat('a',64); d2 text:=repeat('b',64); d3 text:=repeat('c',64);
begin
 creator:=sdi_test.user('release-creator'); other:=sdi_test.user('release-other');
 reviewer:=sdi_test.admin('release-reviewer',false,array['reviews','publishing']);
 review:=sdi_test.release_review(creator,d1,array['feed','youtube']);
 upload:=sdi_test.release_upload(creator,review,d1);

 -- Nothing is releasable before approval and verified publication.
 perform sdi_test.check(not sdi_private.publication_releasable(upload),'not releasable before approval');
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',review,d1,1,'approved','Fine.');
 perform sdi_test.check(r->>'status'='confirmed','approved: '||r::text);
 perform sdi_test.check(not sdi_private.publication_releasable(upload),'approved but unpublished is not releasable');
 perform sdi_test.check(jsonb_array_length(sdi_private.publication_release_candidates(25))=0,'no candidates before publication');
 perform sdi_test.check(not sdi_private.release_published_upload(upload,review),'release refused before publication');

 perform sdi_test.login(creator);
 perform sdi_test.check(sdi_private.publish_action('enqueue',review,'feed')->>'status'='queued','feed queued');
 perform sdi_test.check(sdi_private.publish_action('enqueue',review,'youtube')->>'status'='queued','youtube queued');
 r:=sdi_private.publish_status();
 perform sdi_test.check(r->'reviews'->0->>'review_state'='approved' and r->'reviews'->0->>'server_copy'='retained','status shows approval and retained copy: '||r::text);
 perform sdi_test.check((select bool_and(j->>'stage'='queued') from jsonb_array_elements(r->'reviews'->0->'jobs') j),'both jobs queued');

 -- Feed publishes; YouTube completes only the private upload.
 claimed:=sdi_private.feed_publish_claim(); feed_job:=(claimed->>'job')::uuid;
 perform sdi_test.check(sdi_private.feed_publish_finish(feed_job,(claimed->>'lease')::uuid,'https://media.example.test/'||d1||'.mp4',12),'feed published');
 claimed:=sdi_private.publish_claim(); yt_job:=(claimed->>'job')::uuid; token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(claimed->>'destination'='youtube','youtube claimed: '||claimed::text);
 perform sdi_test.check(sdi_private.publish_progress(yt_job,token,'abcdefghijk',true),'private upload recorded');
 perform sdi_test.check(not sdi_private.publication_releasable(upload),'processing upload keeps the server copy');
 perform sdi_test.check(not sdi_private.release_published_upload(upload,review),'release refused while provider processing');
 r:=sdi_private.publish_status();
 perform sdi_test.check((select j->>'stage' from jsonb_array_elements(r->'reviews'->0->'jobs') j where j->>'destination'='youtube')='provider_processing','youtube shows provider processing');
 job:=(select j from jsonb_array_elements(r->'reviews'->0->'jobs') j where j->>'destination'='feed');
 perform sdi_test.check(job->>'stage'='published' and job->>'result_url' like 'https://media.example.test/%','feed shows confirmed link');

 -- Provider confirms release; a fresh lease still blocks for the grace interval.
 update sdi_private.publish_jobs set next_attempt=clock_timestamp() where id=yt_job;
 claimed:=sdi_private.publish_claim(); token:=(claimed->>'lease')::uuid;
 perform sdi_test.check((claimed->>'job')::uuid=yt_job and claimed->>'phase'='processing','processing job reclaimed');
 perform sdi_test.check(sdi_private.publish_finish(yt_job,token,'abcdefghijk','https://www.youtube.com/watch?v=abcdefghijk'),'youtube published');
 perform sdi_test.check(not sdi_private.publication_releasable(upload),'recent lease blocks release');
 update sdi_private.publish_jobs set lease_expires=clock_timestamp()-interval '5 minutes' where review_id=review;

 -- A pending appeal on the feed copy blocks release until it is decided.
 media:=(select id from public.sdi_watch_media where review_id=review);
 insert into sdi_private.moderation_appeals(media_id,creator,explanation) values(media,creator,'Please restore.');
 perform sdi_test.check(not sdi_private.publication_releasable(upload),'pending appeal blocks release');
 update sdi_private.moderation_appeals set state='rejected' where media_id=media;
 perform sdi_test.check(sdi_private.publication_releasable(upload),'verified publication on every destination is releasable');

 -- Only the service role reaches the release operations.
 perform sdi_test.check(sdi_test.denied('authenticated',format('select public.sdi_release_published_upload(%L,%L)',upload,review)),'authenticated cannot release');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_publication_release_candidates(5)'),'anon cannot list candidates');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_publish_status(0)'),'anon cannot read status');
 execute 'set local role service_role';
 r:=public.sdi_publication_release_candidates(5);
 reset role;
 perform sdi_test.check(r @> jsonb_build_array(jsonb_build_object('upload',upload,'review',review)),'candidate listed: '||r::text);
 perform sdi_test.check(not sdi_private.release_published_upload(upload,gen_random_uuid()),'mismatched review refused');
 perform sdi_test.check(sdi_private.release_published_upload(upload,review),'release authorized');
 perform sdi_test.check(sdi_private.release_published_upload(upload,review),'release is idempotent');
 perform sdi_test.check(not sdi_private.release_allowed(review,1,d1,'feed'),'released artifact fences new leases');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=feed_job)='published'
  and (select state from sdi_private.publish_jobs where id=yt_job)='published','published jobs untouched');
 perform sdi_test.check(sdi_private.publication_release_candidates(5) @> jsonb_build_array(jsonb_build_object('upload',upload,'review',review)),'authorized release repeats for crash recovery');
 perform sdi_test.check(sdi_private.retire_upload(upload,review),'expiry retirement agrees after release');
 perform sdi_test.login(creator);
 r:=sdi_private.publish_status();
 perform sdi_test.check(r->'reviews'->0->>'server_copy'='deleted' and r->'reviews'->0->'server_copy_expires_at'='null'::jsonb,'status reports deleted server copy: '||r::text);

 -- Social reuse keeps the copy for marketing; failed jobs keep it for retry.
 social:=sdi_test.release_review(creator,d2,array['feed','social']);
 social_upload:=sdi_test.release_upload(creator,social,d2);
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',social,d2,1,'approved','Fine.');
 perform sdi_test.login(creator);
 perform sdi_private.publish_action('enqueue',social,'feed');
 update sdi_private.publish_jobs set state='failed',last_error='Upload failed at https://upload.example.test/s?upload_id=1&sig=SECRETSIG with Bearer SECRETTOKEN and access_token=SECRETACCESS'
 where review_id=social;
 perform sdi_test.check(not sdi_private.publication_releasable(social_upload),'social destination or failed job keeps the copy');
 job:=(select j from jsonb_array_elements(sdi_private.publish_status()->'reviews') rv, jsonb_array_elements(rv->'jobs') j where (rv->>'review_id')::uuid=social);
 perform sdi_test.check(job->>'stage'='failed' and (job->>'can_retry')::boolean,'failed job offers retry: '||job::text);
 perform sdi_test.check(job->>'last_error' not like '%SECRET%' and job->>'last_error' not like '%https://%','failure reason stored without secrets: '||(job->>'last_error'));
 perform sdi_test.check(job->>'result_url' is null,'no link for unpublished job');

 -- Rights withdrawn after publication: the published copy enters removal, the
 -- status says so and the staging copy is kept for the removal workers.
 third:=sdi_test.release_review(creator,d3,array['feed']);
 third_upload:=sdi_test.release_upload(creator,third,d3);
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',third,d3,1,'approved','Fine.');
 perform sdi_test.login(creator);
 perform sdi_private.publish_action('enqueue',third,'feed');
 claimed:=sdi_private.feed_publish_claim();
 perform sdi_test.check(sdi_private.feed_publish_finish((claimed->>'job')::uuid,(claimed->>'lease')::uuid,'https://media.example.test/'||d3||'.mp4',9),'third render published');
 update sdi_private.publish_jobs set lease_expires=clock_timestamp()-interval '5 minutes' where review_id=third;
 perform sdi_test.check(sdi_private.publication_releasable(third_upload),'third render releasable before the rights change');
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_rights(third,d3,1,false,'Rights dispute received.');
 perform sdi_test.check(r->>'status'='confirmed','rights withdrawn: '||r::text);
 perform sdi_test.check(not sdi_private.publication_releasable(third_upload),'changed rights keep the copy until removal is confirmed');
 perform sdi_test.login(creator);
 job:=(select j from jsonb_array_elements(sdi_private.publish_status()->'reviews') rv, jsonb_array_elements(rv->'jobs') j where (rv->>'review_id')::uuid=third);
 perform sdi_test.check(job->>'stage'='removal_in_progress' and job->>'result_url' is null,'status tracks the removal request: '||job::text);

 -- Another member sees none of this creator's status.
 perform sdi_test.login(other);
 perform sdi_test.check(jsonb_array_length(sdi_private.publish_status()->'reviews')=0,'status is private to the creator');
 perform sdi_test.logout();
 perform sdi_test.check(sdi_private.publish_status()->>'error' is not null,'signed-out status refused');
end $$;
rollback;
