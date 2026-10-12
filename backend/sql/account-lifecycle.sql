-- Unapplied candidate. Install last (after support-requests.sql). Member data export,
-- deletion requests with a cooling-off period, the service worker contract that
-- prepares and later purges an account, and member notices. On-device projects and
-- originals are never stored server-side, so they are neither exported nor deleted
-- here; the export says so. Provider subscriptions are not cancelled by this code:
-- the member cancels through the App Store or the Stripe portal and the notice says so.
begin;
create table sdi_private.member_notices (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 kind text not null check(kind ~ '^[a-z_]{1,40}$'), message text not null check(length(message) between 1 and 500),
 created_at timestamptz not null default clock_timestamp(), read_at timestamptz
);
create table sdi_private.account_export_log (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.deletion_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid unique references auth.users(id) on delete set null,
 state text not null default 'pending' check(state in('pending','processing','blocked','completed','cancelled')),
 requested_at timestamptz not null default clock_timestamp(), scheduled_for timestamptz not null,
 purge_after timestamptz, blocked_reason text not null default '' check(length(blocked_reason)<=500),
 completed_at timestamptz, revision bigint not null default 1
);
alter table sdi_private.member_notices enable row level security;
alter table sdi_private.account_export_log enable row level security;
alter table sdi_private.deletion_requests enable row level security;
revoke all on sdi_private.member_notices,sdi_private.account_export_log,sdi_private.deletion_requests from public,anon,authenticated;
create index member_notices_inbox on sdi_private.member_notices(user_id,read_at,created_at desc);
-- Retained moderation evidence must survive the deletion of the member who filed
-- it: these references become nullable and clear on delete instead of blocking.
alter table sdi_private.war_reports drop constraint war_reports_reporter_fkey, alter column reporter drop not null,
 add constraint war_reports_reporter_fkey foreign key(reporter) references auth.users(id) on delete set null;
alter table sdi_private.war_appeals drop constraint war_appeals_appellant_fkey, alter column appellant drop not null,
 add constraint war_appeals_appellant_fkey foreign key(appellant) references auth.users(id) on delete set null;
alter table sdi_private.moderation_appeals drop constraint moderation_appeals_creator_fkey, alter column creator drop not null,
 add constraint moderation_appeals_creator_fkey foreign key(creator) references auth.users(id) on delete set null;
alter table sdi_private.room_reports drop constraint room_reports_reporter_fkey, alter column reporter drop not null,
 add constraint room_reports_reporter_fkey foreign key(reporter) references auth.users(id) on delete set null;
alter table sdi_private.room_commands drop constraint room_commands_author_fkey, alter column author drop not null,
 add constraint room_commands_author_fkey foreign key(author) references auth.users(id) on delete set null;
alter table sdi_private.challenge_results drop constraint challenge_results_winner_entry_fkey,
 add constraint challenge_results_winner_entry_fkey foreign key(winner_entry) references sdi_private.challenge_entries(id) on delete set null;

create function sdi_private.notify_member(subject uuid,kind text,message text) returns void language sql security definer set search_path='' as $$
 insert into sdi_private.member_notices(user_id,kind,message) select subject,kind,left(message,500) where subject is not null
$$;
revoke all on function sdi_private.notify_member(uuid,text,text) from public,anon,authenticated;
grant execute on function sdi_private.notify_member(uuid,text,text) to service_role;
create function sdi_private.member_notices(action text,notice uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); items jsonb;
begin
 if actor is null or not exists(select 1 from auth.sessions where user_id=actor and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.'); end if;
 if action='mark_read' then update sdi_private.member_notices set read_at=coalesce(read_at,clock_timestamp()) where id=notice and user_id=actor;
 elsif action='mark_all_read' then update sdi_private.member_notices set read_at=clock_timestamp() where user_id=actor and read_at is null;
 elsif action<>'list' then return jsonb_build_object('error','Unsupported notice operation.'); end if;
 select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
  select id,kind,message,created_at,read_at from sdi_private.member_notices where user_id=actor order by read_at is not null,created_at desc,id limit 50) item;
 return jsonb_build_object('notices',items,'unread',(select count(*) from sdi_private.member_notices where user_id=actor and read_at is null));
end $$;
revoke all on function sdi_private.member_notices(text,uuid) from public,anon;
grant execute on function sdi_private.member_notices(text,uuid) to authenticated;
create function public.sdi_member_notices(action text,notice uuid default null) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.member_notices(action,notice)$$;
revoke all on function public.sdi_member_notices(text,uuid) from public,anon;
grant execute on function public.sdi_member_notices(text,uuid) to authenticated;

-- Export of the member's own server records. Internal reasons, reporter identities
-- and other members' data are excluded. Three exports per day.
create function sdi_private.account_export() returns jsonb language plpgsql security definer set search_path='' as $$
declare me uuid:=auth.uid(); support jsonb:='[]'::jsonb;
begin
 if me is null or not exists(select 1 from auth.users where id=me and not is_anonymous)
 or not exists(select 1 from auth.sessions where user_id=me and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.'); end if;
 if (select count(*) from sdi_private.account_export_log where user_id=me and created_at>clock_timestamp()-interval '1 day')>=3 then
  return jsonb_build_object('error','Three exports per day. Try again later.'); end if;
 insert into sdi_private.account_export_log(user_id) values(me);
 if to_regclass('sdi_private.support_requests') is not null then
  execute 'select coalesce(jsonb_agg(row_to_json(s)),''[]''::jsonb) from (select receipt,category,platform,subject,body,status,created_at from sdi_private.support_requests where user_id=$1 order by created_at) s' into support using me;
 end if;
 return jsonb_build_object(
  'generated_at',clock_timestamp(),
  'note','Editable projects and originals stay on your device and are not stored or exported by the service. Internal moderation reasons and other members'' identities are not included.',
  'account',(select jsonb_build_object('id',u.id,'email',u.email,'username',u.raw_user_meta_data->>'username','created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
    'sign_in_methods',(select coalesce(jsonb_agg(distinct i.provider),'[]'::jsonb) from auth.identities i where i.user_id=u.id)) from auth.users u where u.id=me),
  'account_state',coalesce((select jsonb_build_object('state',c.state,'since',c.updated_at) from sdi_private.account_controls c where c.user_id=me),'{"state":"active"}'::jsonb),
  'account_appeals',(select coalesce(jsonb_agg(row_to_json(a)),'[]'::jsonb) from (select explanation,state,reply,created_at,decided_at from sdi_private.account_appeals where subject=me order by created_at) a),
  'feed_posts',(select coalesce(jsonb_agg(row_to_json(p)),'[]'::jsonb) from (select p.id,p.caption,p.published_at,p.visible,p.featured,p.allow_export,m.title,m.url,m.render_digest,m.approved
    from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id where p.creator=me order by p.published_at) p),
  'feed_likes',(select coalesce(jsonb_agg(row_to_json(l)),'[]'::jsonb) from (select post,created_at from sdi_private.feed_likes where feed_likes.actor=me order by created_at) l),
  'feed_follows',(select coalesce(jsonb_agg(f.creator),'[]'::jsonb) from sdi_private.feed_follows f where f.actor=me),
  'feed_blocks',(select coalesce(jsonb_agg(b.creator),'[]'::jsonb) from sdi_private.feed_blocks b where b.actor=me),
  'feed_reports',(select coalesce(jsonb_agg(row_to_json(r)),'[]'::jsonb) from (select post,reason,state,created_at from sdi_private.feed_reports where feed_reports.actor=me order by created_at) r),
  'war_matches',(select coalesce(jsonb_agg(row_to_json(w)),'[]'::jsonb) from (select w.id,case when w.creator=me then 'creator' else 'opponent' end as role,w.status,w.created_at,w.ends_at,res.outcome,res.left_votes,res.right_votes
    from sdi_private.war_matches w left join sdi_private.war_results res on res.match_id=w.id where me in(w.creator,w.opponent) order by w.created_at) w),
  'war_votes',(select coalesce(jsonb_agg(row_to_json(v)),'[]'::jsonb) from (select match_id,choice from sdi_private.war_votes where voter=me) v),
  'challenge_entries',(select coalesce(jsonb_agg(row_to_json(e)),'[]'::jsonb) from (select challenge_id,media_id,render_digest,withdrawn,created_at from sdi_private.challenge_entries where creator=me) e),
  'challenge_votes',(select coalesce(jsonb_agg(row_to_json(v)),'[]'::jsonb) from (select challenge_id,entry_id,created_at from sdi_private.challenge_votes where voter=me) v),
  'rooms_owned',(select coalesce(jsonb_agg(row_to_json(r)),'[]'::jsonb) from (select id,title,closed,project_ref,project_title,permissions,created_at from public.sdi_rooms where owner_id=me) r),
  'room_memberships',(select coalesce(jsonb_agg(row_to_json(m)),'[]'::jsonb) from (select room_id,role,owner_approved,member_accepted,revoked from public.sdi_room_members where user_id=me) m),
  'render_reviews',(select coalesce(jsonb_agg(row_to_json(r)),'[]'::jsonb) from (select id,title,render_digest,state,version,consent_version,destinations,allow_export,created_at from sdi_private.render_reviews where creator=me order by created_at) r),
  'publish_jobs',(select coalesce(jsonb_agg(row_to_json(j)),'[]'::jsonb) from (select id,review_id,destination,state,result_url,created_at,updated_at from sdi_private.publish_jobs where creator=me order by created_at) j),
  'subscriptions',(select coalesce(jsonb_agg(row_to_json(s)),'[]'::jsonb) from (select provider,product_id,status,paid_through,cancel_at_period_end from sdi_private.subscriptions where user_id=me) s),
  'badges',(select coalesce(jsonb_agg(row_to_json(b)),'[]'::jsonb) from (select badge_key,title,earned_at,revoked from sdi_private.earned_badges where user_id=me) b),
  'record_preferences',(select row_to_json(p) from (select show_records,show_badges from sdi_private.record_preferences where user_id=me) p),
  'support_requests',support,
  'notices',(select coalesce(jsonb_agg(row_to_json(n)),'[]'::jsonb) from (select kind,message,created_at,read_at from sdi_private.member_notices where user_id=me order by created_at) n),
  'deletion_request',(select row_to_json(d) from (select state,requested_at,scheduled_for,completed_at from sdi_private.deletion_requests where user_id=me) d));
end $$;
revoke all on function sdi_private.account_export() from public,anon;
grant execute on function sdi_private.account_export() to authenticated;

create function sdi_private.account_lifecycle(action text,revision bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); d sdi_private.deletion_requests;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not is_anonymous)
 or not exists(select 1 from auth.sessions where user_id=actor and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.'); end if;
 if action='export' then return sdi_private.account_export(); end if;
 select * into d from sdi_private.deletion_requests where user_id=actor for update;
 if action='status' then
  return jsonb_build_object('deletion',case when d.id is null then null else jsonb_build_object('state',d.state,'requested_at',d.requested_at,'scheduled_for',d.scheduled_for,'revision',d.revision) end,
   'exports_remaining_today',3-(select count(*) from sdi_private.account_export_log where user_id=actor and created_at>clock_timestamp()-interval '1 day'),
   'note','Deletion removes server records after a seven-day cooling-off period. Projects on your devices are untouched. Cancel any subscription through the App Store or billing portal; deletion does not cancel it.');
 elsif action='request_deletion' then
  if exists(select 1 from sdi_private.admin_roles where user_id=actor and enabled) then return jsonb_build_object('error','Administrator accounts use the separate owner procedure.'); end if;
  if d.id is not null and d.state in('pending','processing','blocked') then return jsonb_build_object('status',d.state,'scheduled_for',d.scheduled_for); end if;
  if d.id is null then
   insert into sdi_private.deletion_requests(user_id,scheduled_for) values(actor,clock_timestamp()+interval '7 days') returning * into d;
  else
   update sdi_private.deletion_requests set state='pending',requested_at=clock_timestamp(),scheduled_for=clock_timestamp()+interval '7 days',purge_after=null,
    blocked_reason='',completed_at=null,revision=deletion_requests.revision+1 where id=d.id returning * into d;
  end if;
  perform sdi_private.notify_member(actor,'deletion_requested','Account deletion is scheduled for '||to_char(d.scheduled_for,'YYYY-MM-DD HH24:MI')||' UTC. Sign in and cancel before then to keep the account. Subscriptions must be cancelled with the store or billing portal.');
  return jsonb_build_object('status','pending','scheduled_for',d.scheduled_for,'revision',d.revision);
 elsif action='cancel_deletion' then
  if d.id is null or d.state<>'pending' then return jsonb_build_object('error','No pending deletion request can be cancelled.'); end if;
  if revision is distinct from d.revision then return jsonb_build_object('error','Request changed. Refresh before cancelling.'); end if;
  update sdi_private.deletion_requests set state='cancelled',revision=deletion_requests.revision+1 where id=d.id;
  perform sdi_private.notify_member(actor,'deletion_cancelled','Account deletion was cancelled. Nothing was removed.');
  return jsonb_build_object('status','cancelled');
 end if;
 return jsonb_build_object('error','Unsupported account operation.');
end $$;
revoke all on function sdi_private.account_lifecycle(text,bigint) from public,anon;
grant execute on function sdi_private.account_lifecycle(text,bigint) to authenticated;
create function public.sdi_account_lifecycle(action text,revision bigint default null) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.account_lifecycle(action,revision)$$;
revoke all on function public.sdi_account_lifecycle(text,bigint) from public,anon;
grant execute on function public.sdi_account_lifecycle(text,bigint) to authenticated;

-- Worker contract (service role, call periodically): processes at most one request.
-- Phase 1 'prepared': end sessions, suspend, withdraw publishing consent, unapprove
-- media and queue removals, hide posts, withdraw matches/entries, close rooms, scrub
-- support text; the request waits purge_after (30 days) for removals and intake
-- retirement. Phase 2 'purged': once nothing external remains, delete server rows in
-- dependency order and the auth user. Blockers never cause a partial purge.
create function sdi_private.account_deletion_run() returns jsonb language plpgsql security definer set search_path='' as $$
declare d sdi_private.deletion_requests; u uuid; blockers text[]:='{}';
begin
 select * into d from sdi_private.deletion_requests where state='pending' and scheduled_for<=clock_timestamp() and user_id is not null
  order by scheduled_for for update skip locked limit 1;
 if found then
  u:=d.user_id;
  delete from auth.sessions where user_id=u;
  insert into sdi_private.account_controls(user_id,state,reason) values(u,'suspended','Account deletion in progress.')
  on conflict(user_id) do update set state='suspended',reason='Account deletion in progress.',updated_at=clock_timestamp();
  update sdi_private.render_reviews set consent_version='',destinations='{}',state='pending' where creator=u;
  insert into sdi_private.removal_jobs(media_id,render_digest,reason) select id,render_digest,'Account deletion.' from public.sdi_watch_media where owner_id=u and render_digest is not null and approved
  on conflict(media_id,render_digest) do nothing;
  update public.sdi_watch_media set approved=false where owner_id=u;
  update sdi_private.feed_posts set visible=false,featured=false where creator=u;
  update sdi_private.war_matches set status='withdrawn' where u in(creator,opponent) and status in('pending','active');
  update sdi_private.challenge_entries set withdrawn=true where creator=u;
  delete from sdi_private.challenge_votes where voter=u or entry_id in(select id from sdi_private.challenge_entries where creator=u);
  update public.sdi_rooms set closed=true where owner_id=u;
  update sdi_private.room_invites set revoked=true where room_id in(select id from public.sdi_rooms where owner_id=u);
  update public.sdi_room_members set revoked=true,owner_approved=false,member_accepted=false where user_id=u;
  if to_regclass('sdi_private.support_requests') is not null then
   execute 'update sdi_private.support_requests set status=''deleted'',subject=''[deleted by member]'',body=''[deleted by member]'',app_version='''',admin_note='''',retention_until=clock_timestamp()+interval ''30 days'' where user_id=$1' using u;
  end if;
  update sdi_private.deletion_requests set state='processing',purge_after=clock_timestamp()+interval '30 days',revision=deletion_requests.revision+1 where id=d.id;
  return jsonb_build_object('action','prepared','request',d.id,'purge_after',clock_timestamp()+interval '30 days');
 end if;
 select * into d from sdi_private.deletion_requests where state='processing' and purge_after<=clock_timestamp() and user_id is not null
  order by purge_after for update skip locked limit 1;
 if not found then return jsonb_build_object('action','idle'); end if;
 u:=d.user_id;
 if exists(select 1 from sdi_private.publish_jobs where creator=u and state in('queued','leased','cancel_requested','reconcile','removal_pending')) then blockers:=array_append(blockers,'publishing jobs not settled'); end if;
 if exists(select 1 from sdi_private.removal_jobs r join public.sdi_watch_media m on m.id=r.media_id where m.owner_id=u and r.state in('pending','running','failed')) then blockers:=array_append(blockers,'hosted copies not yet removed'); end if;
 if exists(select 1 from sdi_private.upload_registrations ur join sdi_private.render_reviews rr on rr.id=ur.review_id where rr.creator=u and ur.retirement_authorized_at is null) then blockers:=array_append(blockers,'intake renders not yet retired'); end if;
 if cardinality(blockers)>0 then
  -- Keep waiting for 30 more days, then surface the request for an administrator.
  update sdi_private.deletion_requests set state=case when purge_after<clock_timestamp()-interval '30 days' then 'blocked' else state end,
   blocked_reason=left(array_to_string(blockers,'; '),500),revision=deletion_requests.revision+1 where id=d.id;
  return jsonb_build_object('action',case when d.purge_after<clock_timestamp()-interval '30 days' then 'blocked' else 'waiting' end,'request',d.id,'reasons',to_jsonb(blockers));
 end if;
 -- Expire remaining private artifacts; the intake host deletes files after retire.
 update sdi_private.render_artifacts a set expires_at=least(a.expires_at,clock_timestamp()) from sdi_private.render_reviews r where r.id=a.review_id and r.creator=u;
 -- Dependency-ordered purge. Public renditions are anonymised, not deleted, because
 -- completed matchups and evidence reference them; their hosted copies are gone.
 delete from sdi_private.feed_curation_audit where post in(select id from sdi_private.feed_posts where creator=u);
 delete from sdi_private.publishing_audit where job_id in(select id from sdi_private.publish_jobs where creator=u);
 delete from sdi_private.publish_jobs where creator=u;
 delete from sdi_private.preview_permits where review_id in(select id from sdi_private.render_reviews where creator=u);
 delete from sdi_private.upload_registrations where review_id in(select id from sdi_private.render_reviews where creator=u);
 delete from sdi_private.render_artifacts where review_id in(select id from sdi_private.render_reviews where creator=u);
 delete from sdi_private.render_decisions where review_id in(select id from sdi_private.render_reviews where creator=u);
 update public.sdi_watch_media set owner_id=null,approved=false,review_id=null,title='Removed',url='https://removed.invalid/'||id::text where owner_id=u;
 delete from sdi_private.war_appeals where decision_id in(select a.id from sdi_private.war_moderation_audit a join sdi_private.war_matches w on w.id=a.match_id where u in(w.creator,w.opponent));
 delete from sdi_private.war_moderation_audit where match_id in(select id from sdi_private.war_matches where u in(creator,opponent));
 delete from sdi_private.war_reports where match_id in(select id from sdi_private.war_matches where u in(creator,opponent));
 delete from sdi_private.war_results where match_id in(select id from sdi_private.war_matches where u in(creator,opponent));
 delete from sdi_private.room_moderation_audit where room_id in(select id from public.sdi_rooms where owner_id=u);
 delete from sdi_private.room_reports where room_id in(select id from public.sdi_rooms where owner_id=u);
 delete from auth.users where id=u;
 update sdi_private.deletion_requests set state='completed',completed_at=clock_timestamp(),revision=deletion_requests.revision+1 where id=d.id;
 return jsonb_build_object('action','purged','request',d.id);
end $$;
revoke all on function sdi_private.account_deletion_run() from public,anon,authenticated;
grant execute on function sdi_private.account_deletion_run() to service_role;
create function public.sdi_account_deletion_run() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.account_deletion_run()$$;
revoke all on function public.sdi_account_deletion_run() from public,anon,authenticated;
grant execute on function public.sdi_account_deletion_run() to service_role;
commit;
