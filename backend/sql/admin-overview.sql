-- Unapplied candidate; install after feed, publishing, moderation and War Room candidates.
begin;
create function sdi_private.admin_overview() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not sdi_private.admin_can('overview') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current administrator MFA session required.');end if;
 return jsonb_build_object(
  'users',(select count(*) from auth.users where not is_anonymous),
  'signed_in_today',(select count(*) from auth.users where not is_anonymous and last_sign_in_at>=date_trunc('day',clock_timestamp() at time zone 'UTC') at time zone 'UTC'),
  'pending_renders',(select count(*) from sdi_private.render_reviews where state='pending'),
  'publishing_jobs',(select count(*) from sdi_private.publish_jobs where state in('queued','leased','cancel_requested')),
  'publishing_attention',(select count(*) from sdi_private.publish_jobs where state in('failed','reconcile','removal_pending')),
  'feed_reports',(select count(*) from sdi_private.feed_reports where state='pending'),
  'war_reports',(select count(*) from sdi_private.war_reports where state='pending'),
  'war_appeals',(select count(*) from sdi_private.war_appeals where state='pending'),
  'measured_at',clock_timestamp());
end $$;
revoke all on function sdi_private.admin_overview() from public,anon;
grant execute on function sdi_private.admin_overview() to authenticated;
create function public.sdi_admin_overview() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.admin_overview()$$;
revoke all on function public.sdi_admin_overview() from public,anon;
grant execute on function public.sdi_admin_overview() to authenticated;
commit;
