-- Unapplied candidate. Install after publishing-withdrawal.sql.
begin;
create function sdi_private.creator_review(action text,review uuid default null,version bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; items jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select id,title,render_digest,render_reviews.version,state,consent_version,destinations,
    sdi_private.release_allowed(id,render_reviews.version,render_digest,'youtube') as can_publish
   from sdi_private.render_reviews where creator=auth.uid() order by created_at desc,id limit 100
  ) item;
  return jsonb_build_object('reviews',items);
 end if;
 if action is null or action not in('withdraw_consent','publish_youtube') or review is null or version is null then
  return jsonb_build_object('error','Select a current reviewed render.');end if;
 select * into r from sdi_private.render_reviews where id=review and creator=auth.uid() for update;
 if not found or r.version<>version then return jsonb_build_object('error','Render changed. Refresh before acting.');end if;
 if action='withdraw_consent' then
  update sdi_private.render_reviews set consent_version='',destinations=array[]::text[],state='pending' where id=r.id;
  -- Existing approval invalidation and withdrawal triggers handle version/jobs.
  return jsonb_build_object('status','consent_withdrawn');
 end if;
 if exists(select 1 from sdi_private.publish_jobs where review_id=r.id and review_version=r.version and destination='youtube') then
  return jsonb_build_object('error','This render already has a publishing job. Manage it in Publishing activity.');end if;
 return sdi_private.publish_action('enqueue',r.id,'youtube',null);
end $$;
revoke all on function sdi_private.creator_review(text,uuid,bigint) from public,anon;
grant execute on function sdi_private.creator_review(text,uuid,bigint) to authenticated;
create function public.sdi_creator_review(action text,review uuid default null,version bigint default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.creator_review(action,review,version)$$;
revoke all on function public.sdi_creator_review(text,uuid,bigint) from public,anon;
grant execute on function public.sdi_creator_review(text,uuid,bigint) to authenticated;
commit;
