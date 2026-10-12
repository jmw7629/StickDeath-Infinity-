-- Unapplied candidate. Install after feed-publication.sql (needs room-invitations.sql,
-- moderation.sql and admin-users.sql). Rooms remain invitation-based collaboration on
-- an explicitly shared Studio project: no chat, calls, media streams or draft harvesting.
-- project_ref is an opaque identifier of the shared on-device project, never content.
begin;
alter table public.sdi_rooms add column project_ref text check(length(project_ref) between 1 and 200);
alter table public.sdi_rooms add column project_title text check(length(project_title) between 1 and 100);
alter table public.sdi_rooms add column permissions text[] not null default array['view']
 check(permissions <@ array['view','edit'] and 'view'=any(permissions));
alter table public.sdi_rooms add column project_revision bigint not null default 1;
alter table public.sdi_rooms add column command_revision bigint not null default 0;
alter table public.sdi_room_members add column role text not null default 'viewer' check(role in('editor','viewer'));
-- Editing requires the room to share edit permission AND an editor role (or ownership).
create function sdi_private.room_can_edit(r uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists (
  select 1 from public.sdi_rooms room where room.id=r and not room.closed and 'edit'=any(room.permissions)
  and (room.owner_id=auth.uid() or exists (
   select 1 from public.sdi_room_members m where m.room_id=r and m.user_id=auth.uid()
   and m.owner_approved and m.member_accepted and not m.revoked and m.role='editor')))
$$;
revoke all on function sdi_private.room_can_edit(uuid) from public,anon;
grant execute on function sdi_private.room_can_edit(uuid) to authenticated;

create table sdi_private.room_reports (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.sdi_rooms(id),
 reporter uuid not null references auth.users(id), reason text not null check(reason in('rights','abuse','unsafe','spam')),
 detail text not null default '' check(length(detail)<=2000),
 state text not null default 'pending' check(state in('pending','dismissed','closed')),
 revision bigint not null default 1, created_at timestamptz not null default clock_timestamp(), unique(room_id,reporter)
);
create table sdi_private.room_moderation_audit (
 id uuid primary key default gen_random_uuid(), report_id uuid not null references sdi_private.room_reports(id),
 room_id uuid not null, actor uuid not null references auth.users(id), decision text not null,
 reason text not null check(length(reason) between 1 and 2000), created_at timestamptz not null default clock_timestamp()
);
-- Versioned shared edits: one append per operation id, strictly increasing room
-- revision, explicit conflicts. Payloads are bounded Studio commands, not media.
create table sdi_private.room_commands (
 room_id uuid not null references public.sdi_rooms(id) on delete cascade, revision bigint not null,
 op_id uuid not null, author uuid not null references auth.users(id), base_revision bigint not null,
 kind text not null check(length(kind) between 1 and 64), payload jsonb not null check(octet_length(payload::text)<=65536),
 created_at timestamptz not null default clock_timestamp(), primary key(room_id,revision), unique(room_id,op_id)
);
create table sdi_private.room_command_budget (
 user_id uuid primary key references auth.users(id) on delete cascade, window_start timestamptz not null, attempts integer not null
);
alter table sdi_private.room_reports enable row level security;
alter table sdi_private.room_moderation_audit enable row level security;
alter table sdi_private.room_commands enable row level security;
alter table sdi_private.room_command_budget enable row level security;
revoke all on sdi_private.room_reports,sdi_private.room_moderation_audit,sdi_private.room_commands,sdi_private.room_command_budget from public,anon,authenticated;

create function sdi_private.room_manage(action text,room uuid default null,subject uuid default null,role text default null,
 project_ref text default null,project_title text default null,permissions text[] default null,revision bigint default null,
 reason text default null,detail text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); target public.sdi_rooms; n integer; items jsonb; my_role text;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.room_request_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when room_request_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else room_request_budget.attempts+1 end,
 window_start=case when room_request_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else room_request_budget.window_start end
 returning attempts into n;
 if n>30 then return jsonb_build_object('error','Too many requests. Wait a minute.'); end if;
 if action='my_requests' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select r.id as room_id,r.title,r.owner_id,m.request_expires_at from public.sdi_room_members m join public.sdi_rooms r on r.id=m.room_id
   where m.user_id=actor and m.member_accepted and not m.owner_approved and not m.revoked and m.request_expires_at>clock_timestamp() and not r.closed
   order by m.request_expires_at limit 100
  ) item;
  return jsonb_build_object('requests',items);
 end if;
 select * into target from public.sdi_rooms where id=room and not closed for update;
 if not found or not sdi_private.room_access(target.id) then return jsonb_build_object('error','Room is unavailable.'); end if;
 if action='summary' then
  select case when target.owner_id=actor then 'owner' else (select m.role from public.sdi_room_members m where m.room_id=target.id and m.user_id=actor) end into my_role;
  return jsonb_build_object('room_id',target.id,'title',target.title,'owner_id',target.owner_id,'project_ref',target.project_ref,'project_title',target.project_title,
   'permissions',to_jsonb(target.permissions),'project_revision',target.project_revision,'command_revision',target.command_revision,'my_role',my_role,
   'can_edit',sdi_private.room_can_edit(target.id),
   'members',(select count(*) from public.sdi_room_members m where m.room_id=target.id and m.owner_approved and m.member_accepted and not m.revoked));
 end if;
 if action='report' then
  if reason is null or reason not in('rights','abuse','unsafe','spam') or detail is null or length(detail)>2000 then
   return jsonb_build_object('error','Choose a report reason.'); end if;
  if target.owner_id=actor then return jsonb_build_object('error','Close your own room instead of reporting it.'); end if;
  if exists(select 1 from sdi_private.room_reports where room_id=target.id and reporter=actor) then return jsonb_build_object('status','recorded'); end if;
  if (select count(*) from sdi_private.room_reports where reporter=actor and created_at>clock_timestamp()-interval '1 day')>=10 then
   return jsonb_build_object('error','Daily report limit reached.'); end if;
  insert into sdi_private.room_reports(room_id,reporter,reason,detail) values(target.id,actor,room_manage.reason,trim(room_manage.detail)) on conflict do nothing;
  return jsonb_build_object('status','recorded');
 end if;
 if target.owner_id<>actor then return jsonb_build_object('error','Only the owner can perform this operation.'); end if;
 if action='set_project' then
  if project_ref is null or length(trim(project_ref)) not between 1 and 200 or project_title is null or length(trim(project_title)) not between 1 and 100
   or permissions is null or not permissions <@ array['view','edit'] or not 'view'=any(permissions) or revision is distinct from target.project_revision then
   return jsonb_build_object('error','Current project reference, title, permissions and revision are required.'); end if;
  update public.sdi_rooms set project_ref=trim(room_manage.project_ref),project_title=trim(room_manage.project_title),permissions=room_manage.permissions,
   project_revision=project_revision+1 where id=target.id;
  return jsonb_build_object('status','updated','project_revision',target.project_revision+1);
 elsif action='set_role' then
  if subject is null or subject=actor or role is null or role not in('editor','viewer') then return jsonb_build_object('error','Choose a member and a role.'); end if;
  if role='editor' and not 'edit'=any(target.permissions) then return jsonb_build_object('error','Share the project with edit permission before assigning editors.'); end if;
  update public.sdi_room_members set role=room_manage.role where room_id=target.id and user_id=subject and owner_approved and member_accepted and not revoked;
  if not found then return jsonb_build_object('error','That member is not an active participant.'); end if;
  return jsonb_build_object('status','updated');
 end if;
 return jsonb_build_object('error','Unsupported room operation.');
end $$;
revoke all on function sdi_private.room_manage(text,uuid,uuid,text,text,text,text[],bigint,text,text) from public,anon;
grant execute on function sdi_private.room_manage(text,uuid,uuid,text,text,text,text[],bigint,text,text) to authenticated;
create function public.sdi_room_manage(action text,room uuid default null,subject uuid default null,role text default null,
 project_ref text default null,project_title text default null,permissions text[] default null,revision bigint default null,
 reason text default null,detail text default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.room_manage(action,room,subject,role,project_ref,project_title,permissions,revision,reason,detail)$$;
revoke all on function public.sdi_room_manage(text,uuid,uuid,text,text,text,text[],bigint,text,text) from public,anon;
grant execute on function public.sdi_room_manage(text,uuid,uuid,text,text,text,text[],bigint,text,text) to authenticated;

create function sdi_private.room_command(action text,room uuid default null,op_id uuid default null,base_revision bigint default null,
 kind text default null,payload jsonb default null,after bigint default 0,page_size integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); target public.sdi_rooms; n integer; existing bigint; items jsonb;
begin
 if actor is null or not sdi_private.account_active() then return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.room_command_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when room_command_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else room_command_budget.attempts+1 end,
 window_start=case when room_command_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else room_command_budget.window_start end
 returning attempts into n;
 if n>300 then return jsonb_build_object('error','Too many edits per minute. Pause and resynchronize.'); end if;
 if action='since' then
  if not sdi_private.room_access(room) then return jsonb_build_object('error','Room is unavailable.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select revision,op_id,author,base_revision,kind,payload,created_at from sdi_private.room_commands
   where room_id=room and revision>coalesce(after,0) order by revision limit least(greatest(coalesce(page_size,200),1),500)
  ) item;
  return jsonb_build_object('commands',items,'head',(select command_revision from public.sdi_rooms where id=room));
 end if;
 if action<>'append' then return jsonb_build_object('error','Unsupported command operation.'); end if;
 if not sdi_private.room_can_edit(room) then return jsonb_build_object('error','You can view this project but not edit it.'); end if;
 if op_id is null or base_revision is null or kind is null or length(kind) not between 1 and 64 or payload is null or jsonb_typeof(payload)<>'object'
  or octet_length(payload::text)>65536 then return jsonb_build_object('error','A command id, base revision, kind and bounded payload are required.'); end if;
 select * into target from public.sdi_rooms where id=room and not closed for update;
 if not found then return jsonb_build_object('error','Room is unavailable.'); end if;
 select revision into existing from sdi_private.room_commands where room_id=target.id and op_id=room_command.op_id;
 if existing is not null then return jsonb_build_object('status','duplicate','revision',existing,'head',target.command_revision); end if;
 if base_revision<>target.command_revision then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select revision,op_id,author,base_revision,kind,payload,created_at from sdi_private.room_commands
   where room_id=target.id and revision>base_revision order by revision limit 200
  ) item;
  return jsonb_build_object('error','conflict','head',target.command_revision,'missing',items);
 end if;
 if target.command_revision>=100000 then return jsonb_build_object('error','This room reached its edit history limit. Start a new shared project.'); end if;
 insert into sdi_private.room_commands(room_id,revision,op_id,author,base_revision,kind,payload)
 values(target.id,target.command_revision+1,op_id,actor,base_revision,kind,payload);
 update public.sdi_rooms set command_revision=command_revision+1 where id=target.id;
 return jsonb_build_object('status','applied','revision',target.command_revision+1);
end $$;
revoke all on function sdi_private.room_command(text,uuid,uuid,bigint,text,jsonb,bigint,integer) from public,anon;
grant execute on function sdi_private.room_command(text,uuid,uuid,bigint,text,jsonb,bigint,integer) to authenticated;
create function public.sdi_room_command(action text,room uuid default null,op_id uuid default null,base_revision bigint default null,
 kind text default null,payload jsonb default null,after bigint default 0,page_size integer default 200) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.room_command(action,room,op_id,base_revision,kind,payload,after,page_size)$$;
revoke all on function public.sdi_room_command(text,uuid,uuid,bigint,text,jsonb,bigint,integer) from public,anon;
grant execute on function public.sdi_room_command(text,uuid,uuid,bigint,text,jsonb,bigint,integer) to authenticated;

-- Admin queue for room reports. Closing a room ends access for everyone; it never
-- deletes anyone's on-device project. Reporter identity is not returned.
create function sdi_private.room_moderate(action text,report uuid default null,revision bigint default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.room_reports; target public.sdi_rooms; items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select rp.id,rp.room_id,rp.reason,rp.detail,rp.revision,rp.created_at,room.title,room.owner_id,room.closed,
    (select count(*) from public.sdi_room_members m where m.room_id=room.id and m.owner_approved and not m.revoked) as members,
    (select count(*) from sdi_private.room_reports o where o.room_id=room.id) as report_count
   from sdi_private.room_reports rp join public.sdi_rooms room on room.id=rp.room_id where rp.state='pending' order by rp.created_at,rp.id limit 50
  ) item;
  return jsonb_build_object('reports',items);
 end if;
 if action is null or action not in('dismiss','close') or report is null or revision is null or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','A current report and decision reason are required.');end if;
 select * into r from sdi_private.room_reports where id=report for update;
 if not found or r.state<>'pending' or r.revision<>revision then return jsonb_build_object('error','Report changed. Refresh the queue.');end if;
 select * into target from public.sdi_rooms where id=r.room_id for update;
 if auth.uid() in(target.owner_id,r.reporter) then return jsonb_build_object('error','An uninvolved administrator must decide.');end if;
 if action='close' then
  update public.sdi_rooms set closed=true where id=target.id;
  update sdi_private.room_invites set revoked=true where room_id=target.id;
  update sdi_private.room_reports set state='closed',revision=room_reports.revision+1 where room_id=target.id and state='pending';
 else
  update sdi_private.room_reports set state='dismissed',revision=room_reports.revision+1 where id=r.id;
 end if;
 insert into sdi_private.room_moderation_audit(report_id,room_id,actor,decision,reason) values(r.id,target.id,auth.uid(),action,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.room_moderate(text,uuid,bigint,text) from public,anon;
grant execute on function sdi_private.room_moderate(text,uuid,bigint,text) to authenticated;
create function public.sdi_room_moderate(action text,report uuid default null,revision bigint default null,reason text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.room_moderate(action,report,revision,reason)$$;
revoke all on function public.sdi_room_moderate(text,uuid,bigint,text) from public,anon;
grant execute on function public.sdi_room_moderate(text,uuid,bigint,text) to authenticated;

-- Problem 9: creators can appeal a feed removal; an uninvolved administrator decides.
-- Acceptance restores the exact removed digest only while its hosted copy still
-- exists; once removed, the creator resubmits through the normal review path.
alter table sdi_private.moderation_appeals add column render_digest text;
alter table sdi_private.moderation_appeals add column reviewer uuid references auth.users(id);
alter table sdi_private.moderation_appeals add column reply text check(length(reply)<=2000);
alter table sdi_private.moderation_appeals add column decided_at timestamptz;
alter table sdi_private.moderation_appeals add column revision bigint not null default 1;
create unique index moderation_appeals_one_pending on sdi_private.moderation_appeals(media_id) where state='pending';
alter table sdi_private.removal_jobs drop constraint removal_jobs_state_check;
alter table sdi_private.removal_jobs add constraint removal_jobs_state_check check(state in('pending','running','complete','failed','withdrawn'));
create function sdi_private.moderation_appeal(action text,media uuid default null,explanation text default '',appeal uuid default null,
 revision bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); m public.sdi_watch_media; a sdi_private.moderation_appeals; removal sdi_private.moderation_audit; items jsonb;
begin
 if actor_id is null or not exists(select 1 from auth.users where id=actor_id and not is_anonymous)
 or not exists(select 1 from auth.sessions where user_id=actor_id and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.');end if;
 if action in('mine','submit') then
  if action='submit' then
   if media is null or explanation is null or length(trim(explanation)) not between 1 and 2000 then
    return jsonb_build_object('error','Select your removed video and explain your appeal.');end if;
   select * into m from public.sdi_watch_media where id=media and owner_id=actor_id for update;
   select d.* into removal from sdi_private.moderation_audit d where d.media_id=media and d.action='remove' order by d.created_at desc limit 1;
   if not found or m.id is null or m.approved or removal.created_at<clock_timestamp()-interval '30 days' then
    return jsonb_build_object('error','No removal of your video is open for appeal.');end if;
   if exists(select 1 from sdi_private.moderation_appeals where media_id=media and state='pending') then return jsonb_build_object('status','recorded');end if;
   if (select count(*) from sdi_private.moderation_appeals where creator=actor_id and created_at>clock_timestamp()-interval '1 day')>=3 then
    return jsonb_build_object('error','Daily appeal limit reached.');end if;
   insert into sdi_private.moderation_appeals(media_id,creator,explanation,render_digest) values(media,actor_id,trim(explanation),removal.render_digest);
  end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select ap.id,ap.media_id,v.title,ap.explanation,ap.state,ap.reply,ap.created_at,ap.decided_at from sdi_private.moderation_appeals ap
   join public.sdi_watch_media v on v.id=ap.media_id where ap.creator=actor_id order by ap.created_at desc,ap.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='queue' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select ap.id,ap.media_id,ap.creator,ap.explanation,ap.render_digest,ap.revision,ap.created_at,v.title,v.url,
    (select d.reason from sdi_private.moderation_audit d where d.media_id=ap.media_id and d.action='remove' order by d.created_at desc limit 1) as removal_reason,
    (select j.state from sdi_private.removal_jobs j where j.media_id=ap.media_id and j.render_digest=ap.render_digest) as removal_state
   from sdi_private.moderation_appeals ap join public.sdi_watch_media v on v.id=ap.media_id where ap.state='pending' order by ap.created_at,ap.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if action is null or action not in('accept','reject') or appeal is null or revision is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','Select an appeal and provide a member-visible decision reason.');end if;
 select * into a from sdi_private.moderation_appeals where id=appeal for update;
 if not found or a.state<>'pending' or a.revision<>revision then return jsonb_build_object('error','Appeal changed. Refresh the queue.');end if;
 select * into m from public.sdi_watch_media where id=a.media_id for update;
 if actor_id=a.creator or exists(select 1 from sdi_private.moderation_audit d where d.media_id=a.media_id and d.actor=actor_id) then
  return jsonb_build_object('error','Another uninvolved administrator must review this appeal.');end if;
 if action='accept' then
  if m.render_digest is distinct from a.render_digest or m.approved then return jsonb_build_object('error','The removed render changed; nothing to restore.');end if;
  if not exists(select 1 from sdi_private.removal_jobs where media_id=m.id and render_digest=a.render_digest and state in('pending','failed')) then
   return jsonb_build_object('error','The hosted copy is already removed. The creator can resubmit the render for review.');end if;
  update sdi_private.removal_jobs set state='withdrawn' where media_id=m.id and render_digest=a.render_digest and state in('pending','failed');
  update public.sdi_watch_media set approved=true where id=m.id;
  update sdi_private.feed_posts set visible=true where media_id=m.id;
 end if;
 update sdi_private.moderation_appeals set state=case action when 'accept' then 'accepted' else 'rejected' end,reviewer=actor_id,
  reply=trim(note),decided_at=clock_timestamp(),revision=moderation_appeals.revision+1 where id=a.id;
 insert into sdi_private.moderation_audit(report_id,actor,action,reason,media_id,render_digest)
 values(a.id,actor_id,'appeal_'||action,trim(note),m.id,coalesce(a.render_digest,m.render_digest,''));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.moderation_appeal(text,uuid,text,uuid,bigint,text) from public,anon;
grant execute on function sdi_private.moderation_appeal(text,uuid,text,uuid,bigint,text) to authenticated;
create function public.sdi_moderation_appeal(action text,media uuid default null,explanation text default '',appeal uuid default null,
 revision bigint default null,note text default '') returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.moderation_appeal(action,media,explanation,appeal,revision,note)$$;
revoke all on function public.sdi_moderation_appeal(text,uuid,text,uuid,bigint,text) from public,anon;
grant execute on function public.sdi_moderation_appeal(text,uuid,text,uuid,bigint,text) to authenticated;
commit;
