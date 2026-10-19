-- Local assertions for #214 in admin-approval.sql: the owner's review list returns
-- the storyboard, source-project digest and quality report a render was submitted
-- with (null when not supplied), intake binds the declared project digest to the
-- registered review, and a changed digest invalidates an earlier approval.
begin;
do $$
declare creator uuid; owner uuid; viewer uuid; review uuid; upload uuid:=gen_random_uuid(); r jsonb; item jsonb; rev bigint;
 sha text:=repeat('1a',32); digest text:=repeat('2b',32); changed text:=repeat('3c',32);
 meta jsonb;
begin
 creator:=sdi_test.user('digest-creator'); owner:=sdi_test.admin('digest-owner',true,array[]::text[]);
 viewer:=sdi_test.admin('digest-viewer',false,array['reviews']);
 meta:=jsonb_build_object('size',2048,'sha256',sha,'title','Digest render','source_revision','Studio project p, revision 4',
  'destinations',jsonb_build_array('feed'),'rights_summary','Own work','consent_version','terms-v1','made_for_kids',false,
  'source_project_digest',digest);
 r:=sdi_private.register_upload(upload,creator,meta,upload::text||'.mp4','https://intake.example.test/preview',
  clock_timestamp()+interval '1 hour',clock_timestamp()+interval '12 hours');
 perform sdi_test.check(r ? 'review_id','upload registered: '||r::text);
 review:=(r->>'review_id')::uuid;

 -- Before binding the list honestly reports no storyboard and no project digest.
 perform sdi_test.login(owner,'aal2');
 item:=(select x from jsonb_array_elements(sdi_private.review_action('list')->'reviews') x where (x->>'id')::uuid=review);
 perform sdi_test.check(item ? 'storyboard' and item->'storyboard'='null'::jsonb and item->'source_project_digest'='null'::jsonb
  and item->'quality_report'='null'::jsonb,'unbound review lists null storyboard, digest and quality: '||coalesce(item::text,'missing'));
 perform sdi_test.logout();

 -- Only the digest declared in the upload metadata can be bound, by the service.
 r:=sdi_private.review_bind_source_digest(upload,review,changed);
 perform sdi_test.check(r->>'error' like 'Source digest does not match%','undeclared digest refused: '||r::text);
 r:=sdi_private.review_bind_source_digest(upload,review,'not-a-digest');
 perform sdi_test.check(r->>'error'='Invalid source digest binding.','malformed digest refused');
 r:=sdi_private.review_bind_source_digest(gen_random_uuid(),review,digest);
 perform sdi_test.check(r->>'error'='Upload registration not found.','unknown upload refused');
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_review_bind_source_digest(uuid,uuid,text)','execute'),'clients cannot bind digests');
 r:=sdi_private.review_bind_source_digest(upload,review,digest);
 perform sdi_test.check(r->>'status'='confirmed' and (r->>'changed')::boolean and (r->>'version')::bigint=2,'declared digest bound: '||r::text);
 perform sdi_test.check((select source_project_digest=digest and state='pending' and version=2 from sdi_private.render_reviews where id=review),'digest stored on the review');
 perform sdi_test.check(exists(select 1 from sdi_private.render_artifacts where review_id=review and version=2 and render_digest=sha),'same retained bytes carried to the new version');
 r:=sdi_private.review_bind_source_digest(upload,review,digest);
 perform sdi_test.check(r->>'status'='confirmed' and not (r->>'changed')::boolean and (r->>'version')::bigint=2,'rebinding the same digest is idempotent');

 -- The list returns the bound digest and a storyboard when one is attached.
 update sdi_private.render_reviews set storyboard='{"schema":"spatter_storyboard","version":1,"brief":"A red stick figure walks.","frameCount":12}' where id=review;
 select version into rev from sdi_private.render_reviews where id=review;
 perform sdi_test.check(rev=3,'storyboard attachment is a new version');
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
  select review_id,3,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at from sdi_private.render_artifacts where review_id=review and version=2;
 perform sdi_test.login(owner,'aal2');
 item:=(select x from jsonb_array_elements(sdi_private.review_action('list')->'reviews') x where (x->>'id')::uuid=review);
 perform sdi_test.check(item->>'source_project_digest'=digest and item->'storyboard'->>'brief'='A red stick figure walks.' and (item->>'version')::bigint=3,
  'list returns the real storyboard and digest: '||coalesce(item::text,'missing'));

 -- Rights cleared and approved at the exact digest and version.
 r:=sdi_private.review_rights(review,sha,3,true,'Original work; reviewed with audio.');
 perform sdi_test.check(r->>'status'='confirmed','rights recorded: '||r::text);
 select version into rev from sdi_private.render_reviews where id=review;
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Exact render approved.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.render_reviews where id=review)='approved','owner approved: '||r::text);

 -- A changed project digest (the editable source was revised) invalidates that approval.
 update sdi_private.render_reviews set source_project_digest=changed where id=review;
 perform sdi_test.check((select state='pending' and version=rev+1 from sdi_private.render_reviews where id=review),'changed digest returned the review to pending under a new version');
 r:=sdi_private.review_action('decide',review,sha,rev,'approved','Stale approval.');
 perform sdi_test.check(r->>'error' like 'This render changed%','approval at the old version is refused');
 perform sdi_test.check(not sdi_private.release_allowed(review,rev,sha,'feed'),'old approval no longer allows release');

 -- Reviewers without the owner role still see the list fields (owner-only approval for Spatter stays enforced).
 perform sdi_test.login(viewer,'aal2');
 item:=(select x from jsonb_array_elements(sdi_private.review_action('list')->'reviews') x where (x->>'id')::uuid=review);
 perform sdi_test.check(item->>'source_project_digest'=changed,'reviewer sees the current digest');
 perform sdi_test.logout();
end $$;
rollback;
