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

-- Rooms v2.1 (#232, #233). Server-side rebase of concurrent commands, undo
-- ownership, and bounded transfer of explicitly shared assets. Still no chat,
-- calls, camera, microphone, screen or background harvesting: an asset exists
-- here only because an editor chose that file, and it is a temporary transfer
-- copy. The sender's local original is never touched by anything below.
begin;
-- Optional entity a command edits ("frame:<id>", "layer:<id>", "audio:<id>").
-- Commands without a target are treated as touching the whole document.
alter table sdi_private.room_commands add column target text check(target is null or length(target) between 1 and 200);
alter table sdi_private.room_commands add column undoes uuid;
create unique index room_commands_one_undo on sdi_private.room_commands(room_id,undoes) where undoes is not null;

create or replace function sdi_private.room_command(action text,room uuid default null,op_id uuid default null,base_revision bigint default null,
 kind text default null,payload jsonb default null,after bigint default 0,page_size integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); target public.sdi_rooms; n integer; existing bigint; items jsonb; overlap jsonb;
 entity text; undone sdi_private.room_commands; undo_ref uuid;
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
   select revision,op_id,author,base_revision,kind,payload,target,undoes,created_at from sdi_private.room_commands
   where room_id=room and revision>coalesce(after,0) order by revision limit least(greatest(coalesce(page_size,200),1),500)
  ) item;
  return jsonb_build_object('commands',items,'head',(select command_revision from public.sdi_rooms where id=room));
 end if;
 if action<>'append' then return jsonb_build_object('error','Unsupported command operation.'); end if;
 if not sdi_private.room_can_edit(room) then return jsonb_build_object('error','You can view this project but not edit it.'); end if;
 if op_id is null or base_revision is null or base_revision<0 or kind is null or length(kind) not between 1 and 64 or payload is null
  or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>65536
  or (payload ? 'target' and (jsonb_typeof(payload->'target')<>'string' or length(payload->>'target') not between 1 and 200)) then
  return jsonb_build_object('error','A command id, base revision, kind and bounded payload are required.'); end if;
 select * into target from public.sdi_rooms where id=room and not closed for update;
 if not found then return jsonb_build_object('error','Room is unavailable.'); end if;
 select revision into existing from sdi_private.room_commands where room_id=target.id and op_id=room_command.op_id;
 if existing is not null then return jsonb_build_object('status','duplicate','revision',existing,'head',target.command_revision); end if;
 if base_revision>target.command_revision then return jsonb_build_object('error','Base revision is ahead of the room. Resynchronize.'); end if;
 entity:=payload->>'target';
 -- Undo ownership: a creator may undo only their own command, once.
 if kind='undo' then
  if coalesce(payload->>'undo_op','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
   return jsonb_build_object('error','Undo needs the operation id it reverses.'); end if;
  undo_ref:=(payload->>'undo_op')::uuid;
  select * into undone from sdi_private.room_commands c where c.room_id=target.id and c.op_id=undo_ref;
  if not found then return jsonb_build_object('error','That edit is not in this room.'); end if;
  if undone.author<>actor then return jsonb_build_object('error','You can undo only your own edits.'); end if;
  if undone.kind='undo' then return jsonb_build_object('error','Redo is a new edit, not an undo of an undo.'); end if;
  if exists(select 1 from sdi_private.room_commands c where c.room_id=target.id and c.undoes=undo_ref) then
   return jsonb_build_object('error','That edit was already undone.'); end if;
  entity:=undone.target;
 end if;
 if base_revision<target.command_revision then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select revision,op_id,author,base_revision,kind,payload,target,undoes,created_at from sdi_private.room_commands
   where room_id=target.id and revision>base_revision order by revision limit 200
  ) item;
  -- Rebase only when the edit names its entity, the gap is small enough to
  -- return in full, and no intervening command touched that entity (or the
  -- whole document). Anything else is an explicit conflict, never an overwrite.
  select coalesce(jsonb_agg(c.op_id order by c.revision),'[]'::jsonb) into overlap from sdi_private.room_commands c
   where c.room_id=target.id and c.revision>base_revision and (c.target is null or entity is null or c.target=entity);
  if entity is null or target.command_revision-base_revision>200 or jsonb_array_length(overlap)>0 then
   return jsonb_build_object('error','conflict','head',target.command_revision,'missing',items,'overlap',overlap);
  end if;
 end if;
 if target.command_revision>=100000 then return jsonb_build_object('error','This room reached its edit history limit. Start a new shared project.'); end if;
 insert into sdi_private.room_commands(room_id,revision,op_id,author,base_revision,kind,payload,target,undoes)
 values(target.id,target.command_revision+1,op_id,actor,base_revision,kind,payload,entity,case when kind='undo' then undo_ref end);
 update public.sdi_rooms set command_revision=command_revision+1 where id=target.id;
 if base_revision<target.command_revision then
  return jsonb_build_object('status','rebased','revision',target.command_revision+1,'head',target.command_revision+1,'missing',items);
 end if;
 return jsonb_build_object('status','applied','revision',target.command_revision+1);
end $$;

-- Bounded asset transfer (#233). Files move in 32 KiB chunks through this
-- operation boundary; the server recomputes the SHA-256 of the whole file
-- before anyone can download it, and every copy expires. Quotas: 8 MiB per
-- file, 64 MiB and 100 files live per room, 30 files per sender per day,
-- 600 transfer calls per minute per account.
create table sdi_private.room_assets (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.sdi_rooms(id) on delete cascade,
 uploader uuid not null references auth.users(id) on delete cascade,
 project_ref text not null,
 name text not null check(length(name) between 1 and 120),
 mime text not null check(mime in('image/png','image/jpeg','audio/mp4','audio/mpeg','audio/wav','audio/x-caf')),
 byte_size integer not null check(byte_size between 1 and 8388608),
 chunk_count integer not null check(chunk_count between 1 and 256),
 sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'),
 license text not null check(license in('own-work','cc0','cc-by','licensed-library')),
 attribution text not null default '' check(length(attribution)<=500),
 state text not null default 'receiving' check(state in('receiving','available','deleted')),
 end_reason text check(end_reason in('rejected','withdrawn','expired','room_closed','membership_ended')),
 problem text check(length(problem)<=500),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 deleted_at timestamptz,
 delete_verified boolean not null default false,
 check((state='deleted')=(end_reason is not null)),
 check(license<>'cc-by' or length(trim(attribution))>0)
);
create unique index room_assets_one_live_copy on sdi_private.room_assets(room_id,sha256) where state<>'deleted';
create table sdi_private.room_asset_chunks (
 asset_id uuid not null references sdi_private.room_assets(id) on delete cascade,
 idx integer not null check(idx between 0 and 255),
 data bytea not null check(octet_length(data) between 1 and 32768),
 primary key(asset_id,idx)
);
create table sdi_private.room_asset_budget (
 user_id uuid primary key references auth.users(id) on delete cascade, window_start timestamptz not null, attempts integer not null
);
-- Cleanup evidence: how many chunks were removed and whether none remain.
create table sdi_private.room_asset_cleanup_audit (
 id uuid primary key default gen_random_uuid(), asset_id uuid not null, room_id uuid not null,
 reason text not null, chunks_removed integer not null, verified boolean not null,
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.room_assets enable row level security;
alter table sdi_private.room_asset_chunks enable row level security;
alter table sdi_private.room_asset_budget enable row level security;
alter table sdi_private.room_asset_cleanup_audit enable row level security;
revoke all on sdi_private.room_assets,sdi_private.room_asset_chunks,sdi_private.room_asset_budget,sdi_private.room_asset_cleanup_audit
 from public,anon,authenticated;

-- Whether a given user (not necessarily the caller) still belongs to an open room.
create function sdi_private.room_member_active(r uuid,u uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.sdi_rooms room where room.id=r and not room.closed and (room.owner_id=u or exists(
  select 1 from public.sdi_room_members m where m.room_id=r and m.user_id=u and m.owner_approved and m.member_accepted and not m.revoked)))
$$;
revoke all on function sdi_private.room_member_active(uuid,uuid) from public,anon,authenticated;

-- Delete a transfer copy's bytes and record verified evidence. Never touches
-- anything on a device.
create function sdi_private.room_asset_discard(asset uuid,reason text,note text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare removed integer; remaining boolean; a sdi_private.room_assets;
begin
 select * into a from sdi_private.room_assets where id=asset for update;
 if not found or a.state='deleted' then return false; end if;
 delete from sdi_private.room_asset_chunks where asset_id=asset;
 get diagnostics removed=row_count;
 remaining:=exists(select 1 from sdi_private.room_asset_chunks where asset_id=asset);
 update sdi_private.room_assets set state='deleted',end_reason=reason,problem=coalesce(note,problem),deleted_at=clock_timestamp(),
  delete_verified=not remaining where id=asset;
 insert into sdi_private.room_asset_cleanup_audit(asset_id,room_id,reason,chunks_removed,verified) values(asset,a.room_id,reason,removed,not remaining);
 return not remaining;
end $$;
revoke all on function sdi_private.room_asset_discard(uuid,text,text) from public,anon,authenticated;

create function sdi_private.room_asset(action text,room uuid default null,asset uuid default null,name text default null,
 mime text default null,byte_size bigint default null,sha256 text default null,license text default null,attribution text default '',
 chunk_index integer default null,data text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); target public.sdi_rooms; a sdi_private.room_assets; n integer; items jsonb; raw bytea;
 expected integer; chunk_size constant integer:=32768; created uuid; whole bytea; chunks integer;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.room_asset_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when room_asset_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else room_asset_budget.attempts+1 end,
 window_start=case when room_asset_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else room_asset_budget.window_start end
 returning attempts into n;
 if n>600 then return jsonb_build_object('error','Too many transfer requests. Wait a minute.'); end if;
 if room is null or not sdi_private.room_access(room) then return jsonb_build_object('error','Room is unavailable.'); end if;
 select * into target from public.sdi_rooms where id=room and not closed;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select x.id as asset_id,x.name,x.mime,x.byte_size,x.chunk_count,x.sha256,x.license,x.attribution,x.state,x.expires_at,x.created_at,
    x.uploader=actor as mine,(select count(*) from sdi_private.room_asset_chunks c where c.asset_id=x.id) as received
   from sdi_private.room_assets x where x.room_id=target.id and x.expires_at>clock_timestamp()
    and (x.state='available' or (x.state='receiving' and x.uploader=actor))
    and sdi_private.room_member_active(target.id,x.uploader)
   order by x.created_at desc,x.id limit 100
  ) item;
  return jsonb_build_object('assets',items,'chunk_size',chunk_size);
 end if;
 if action='declare' then
  if target.project_ref is null then return jsonb_build_object('error','Share a project in this room before sending assets.'); end if;
  if not sdi_private.room_can_edit(target.id) then return jsonb_build_object('error','Only editors can share assets in this room.'); end if;
  if name is null or length(trim(name)) not between 1 and 120 or mime is null
   or mime not in('image/png','image/jpeg','audio/mp4','audio/mpeg','audio/wav','audio/x-caf')
   or byte_size is null or byte_size not between 1 and 8388608 or sha256 is null or sha256 !~ '^[a-f0-9]{64}$'
   or license is null or license not in('own-work','cc0','cc-by','licensed-library') or attribution is null or length(attribution)>500
   or (license='cc-by' and length(trim(attribution))=0) then
   return jsonb_build_object('error','A named PNG, JPEG or audio file up to 8 MB, its SHA-256 and its licence are required.'); end if;
  select * into a from sdi_private.room_assets x where x.room_id=target.id and x.sha256=room_asset.sha256 and x.state<>'deleted' for update;
  if found then
   if a.expires_at>clock_timestamp() and sdi_private.room_member_active(target.id,a.uploader) then
    if a.state='receiving' and a.uploader<>actor then return jsonb_build_object('error','Another member is already sending this file.'); end if;
    return jsonb_build_object('status','existing','asset_id',a.id,'state',a.state,'chunk_size',chunk_size,'chunk_count',a.chunk_count,'expires_at',a.expires_at);
   end if;
   perform sdi_private.room_asset_discard(a.id,case when sdi_private.room_member_active(target.id,a.uploader) then 'expired' else 'membership_ended' end);
  end if;
  if (select count(*) from sdi_private.room_assets x where x.uploader=actor and x.created_at>clock_timestamp()-interval '1 day')>=30 then
   return jsonb_build_object('error','Daily asset transfer limit reached.'); end if;
  if (select count(*) from sdi_private.room_assets x where x.room_id=target.id and x.state<>'deleted')>=100
   or (select coalesce(sum(x.byte_size),0) from sdi_private.room_assets x where x.room_id=target.id and x.state<>'deleted')+byte_size>67108864 then
   return jsonb_build_object('error','This room reached its transfer quota. Withdraw older assets first.'); end if;
  chunks:=((byte_size+chunk_size-1)/chunk_size)::integer;
  insert into sdi_private.room_assets(room_id,uploader,project_ref,name,mime,byte_size,chunk_count,sha256,license,attribution,expires_at)
  values(target.id,actor,target.project_ref,trim(name),mime,byte_size,chunks,sha256,license,trim(attribution),clock_timestamp()+interval '1 hour')
  returning id into created;
  return jsonb_build_object('status','declared','asset_id',created,'state','receiving','chunk_size',chunk_size,'chunk_count',chunks,
   'expires_at',(select expires_at from sdi_private.room_assets where id=created));
 end if;
 select * into a from sdi_private.room_assets x where x.id=asset and x.room_id=target.id for update;
 if not found or a.state='deleted' or a.expires_at<=clock_timestamp() then return jsonb_build_object('error','Asset is unavailable.'); end if;
 if action='status' then
  if a.uploader<>actor and a.state<>'available' then return jsonb_build_object('error','Asset is unavailable.'); end if;
  return jsonb_build_object('asset_id',a.id,'state',a.state,'chunk_count',a.chunk_count,'expires_at',a.expires_at,
   'received',(select coalesce(jsonb_agg(c.idx order by c.idx),'[]'::jsonb) from sdi_private.room_asset_chunks c where c.asset_id=a.id));
 elsif action='put' then
  if a.uploader<>actor or a.state<>'receiving' then return jsonb_build_object('error','Asset is unavailable.'); end if;
  if not sdi_private.room_can_edit(target.id) then return jsonb_build_object('error','Only editors can share assets in this room.'); end if;
  if chunk_index is null or chunk_index<0 or chunk_index>=a.chunk_count or data is null or length(data)>45000 then
   return jsonb_build_object('error','Chunk index or size is invalid.'); end if;
  begin raw:=decode(data,'base64'); exception when others then return jsonb_build_object('error','Chunk is not valid base64.'); end;
  expected:=case when chunk_index=a.chunk_count-1 then a.byte_size-chunk_index*chunk_size else chunk_size end;
  if octet_length(raw)<>expected then return jsonb_build_object('error','Chunk length does not match the declared file size.'); end if;
  insert into sdi_private.room_asset_chunks(asset_id,idx,data) values(a.id,chunk_index,raw)
  on conflict(asset_id,idx) do update set data=excluded.data;
  return jsonb_build_object('status','stored','received',(select count(*) from sdi_private.room_asset_chunks c where c.asset_id=a.id));
 elsif action='finalize' then
  if a.uploader<>actor or a.state<>'receiving' then return jsonb_build_object('error','Asset is unavailable.'); end if;
  if (select count(*) from sdi_private.room_asset_chunks c where c.asset_id=a.id)<>a.chunk_count then
   return jsonb_build_object('error','incomplete','received',(select coalesce(jsonb_agg(c.idx order by c.idx),'[]'::jsonb) from sdi_private.room_asset_chunks c where c.asset_id=a.id));
  end if;
  select string_agg(c.data,''::bytea order by c.idx) into whole from sdi_private.room_asset_chunks c where c.asset_id=a.id;
  if octet_length(whole)<>a.byte_size or encode(extensions.digest(whole,'sha256'),'hex')<>a.sha256 then
   perform sdi_private.room_asset_discard(a.id,'rejected','Received bytes did not match the declared SHA-256; the copy was discarded.');
   return jsonb_build_object('error','The transferred file was corrupt and has been discarded. Send it again.');
  end if;
  update sdi_private.room_assets set state='available',expires_at=clock_timestamp()+interval '72 hours' where id=a.id;
  return jsonb_build_object('status','available','asset_id',a.id,'expires_at',(select expires_at from sdi_private.room_assets where id=a.id));
 elsif action='get' then
  if a.state<>'available' or not sdi_private.room_member_active(target.id,a.uploader) then return jsonb_build_object('error','Asset is unavailable.'); end if;
  if chunk_index is null or chunk_index<0 or chunk_index>=a.chunk_count then return jsonb_build_object('error','Chunk index is invalid.'); end if;
  return jsonb_build_object('asset_id',a.id,'chunk_index',chunk_index,'chunk_count',a.chunk_count,'sha256',a.sha256,
   'data',(select encode(c.data,'base64') from sdi_private.room_asset_chunks c where c.asset_id=a.id and c.idx=chunk_index));
 elsif action='withdraw' then
  if a.uploader<>actor and target.owner_id<>actor then return jsonb_build_object('error','Only the sender or the room owner can withdraw an asset.'); end if;
  return jsonb_build_object('status','withdrawn','verified',sdi_private.room_asset_discard(a.id,'withdrawn'));
 end if;
 return jsonb_build_object('error','Unsupported asset operation.');
end $$;
revoke all on function sdi_private.room_asset(text,uuid,uuid,text,text,bigint,text,text,text,integer,text) from public,anon;
grant execute on function sdi_private.room_asset(text,uuid,uuid,text,text,bigint,text,text,text,integer,text) to authenticated;
create function public.sdi_room_asset(action text,room uuid default null,asset uuid default null,name text default null,
 mime text default null,byte_size bigint default null,sha256 text default null,license text default null,attribution text default '',
 chunk_index integer default null,data text default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.room_asset(action,room,asset,name,mime,byte_size,sha256,license,attribution,chunk_index,data)$$;
revoke all on function public.sdi_room_asset(text,uuid,uuid,text,text,bigint,text,text,text,integer,text) from public,anon;
grant execute on function public.sdi_room_asset(text,uuid,uuid,text,text,bigint,text,text,text,integer,text) to authenticated;

-- Scheduled cleanup (service role only): expired copies, closed rooms and
-- senders whose membership ended. Returns verified counts for the run log.
create function sdi_private.room_asset_sweep(max_items integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item record; done integer:=0; verified integer:=0;
begin
 for item in
  select x.id,case when room.closed then 'room_closed'
   when not sdi_private.room_member_active(x.room_id,x.uploader) then 'membership_ended' else 'expired' end as reason
  from sdi_private.room_assets x join public.sdi_rooms room on room.id=x.room_id
  where x.state<>'deleted' and (x.expires_at<=clock_timestamp() or room.closed or not sdi_private.room_member_active(x.room_id,x.uploader))
  order by x.expires_at limit least(greatest(coalesce(max_items,200),1),1000)
 loop
  done:=done+1;
  if sdi_private.room_asset_discard(item.id,item.reason) then verified:=verified+1; end if;
 end loop;
 return jsonb_build_object('discarded',done,'verified',verified,
  'unverified_total',(select count(*) from sdi_private.room_assets where state='deleted' and not delete_verified));
end $$;
revoke all on function sdi_private.room_asset_sweep(integer) from public,anon,authenticated;
grant execute on function sdi_private.room_asset_sweep(integer) to service_role;
create function public.sdi_room_asset_sweep(max_items integer default 200) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.room_asset_sweep(max_items)$$;
revoke all on function public.sdi_room_asset_sweep(integer) from public,anon,authenticated;
grant execute on function public.sdi_room_asset_sweep(integer) to service_role;
commit;

-- Rooms v2.2 (#234, owner decision 2026-10-18). Owner-approved project handoff:
-- the room owner may send the shared project, as the portable .sdiproject
-- backup bytes, to approved members through temporary server storage that is
-- deleted afterwards. One live snapshot per room; the server recomputes its
-- SHA-256; only approved, non-revoked members of that room (never the owner,
-- outsiders or anonymous callers) may download it; each member records a
-- receipt after verifying and importing it as a new device project. The copy is
-- deleted once every current member holds a receipt, on revocation, when it is
-- replaced, when the shared project changes, when the room closes, or after 72
-- hours. The owner's device project is only read; nothing here edits, replaces
-- or deletes any device project, and a member's import never overwrites one.
-- Bounds: 32 MiB per snapshot in 256 KiB chunks (max 128), 20 offers per owner
-- per day, 600 handoff calls per minute per account.
begin;
create table sdi_private.room_project_snapshots (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.sdi_rooms(id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 project_ref text not null check(length(project_ref) between 1 and 200),
 project_revision bigint not null,
 title text not null check(length(title) between 1 and 100),
 byte_size integer not null check(byte_size between 1 and 33554432),
 chunk_count integer not null check(chunk_count between 1 and 128),
 sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'),
 state text not null default 'receiving' check(state in('receiving','available','deleted')),
 end_reason text check(end_reason in('rejected','revoked','replaced','expired','room_closed','project_changed','delivered')),
 created_at timestamptz not null default clock_timestamp(),
 offered_at timestamptz,
 expires_at timestamptz not null,
 deleted_at timestamptz,
 delete_verified boolean not null default false,
 check((state='deleted')=(end_reason is not null))
);
create unique index room_project_snapshots_one_live on sdi_private.room_project_snapshots(room_id) where state<>'deleted';
create table sdi_private.room_project_snapshot_chunks (
 snapshot_id uuid not null references sdi_private.room_project_snapshots(id) on delete cascade,
 idx integer not null check(idx between 0 and 127),
 data bytea not null check(octet_length(data) between 1 and 262144),
 primary key(snapshot_id,idx)
);
-- One receipt per member per snapshot: the member verified the SHA-256 and
-- imported the project as a new device project.
create table sdi_private.room_project_snapshot_receipts (
 snapshot_id uuid not null references sdi_private.room_project_snapshots(id) on delete cascade,
 member uuid not null references auth.users(id) on delete cascade,
 received_at timestamptz not null default clock_timestamp(),
 primary key(snapshot_id,member)
);
create table sdi_private.room_snapshot_budget (
 user_id uuid primary key references auth.users(id) on delete cascade, window_start timestamptz not null, attempts integer not null
);
-- Append-only evidence (guarded by security-audit-integrity.sql): offers,
-- downloads and every deletion with its verified chunk count.
create table sdi_private.room_snapshot_audit (
 id uuid primary key default gen_random_uuid(), snapshot_id uuid not null, room_id uuid not null, actor uuid,
 event text not null check(event in('offered','downloaded','rejected','revoked','replaced','expired','room_closed','project_changed','delivered')),
 chunks_removed integer, verified boolean, created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.room_project_snapshots enable row level security;
alter table sdi_private.room_project_snapshot_chunks enable row level security;
alter table sdi_private.room_project_snapshot_receipts enable row level security;
alter table sdi_private.room_snapshot_budget enable row level security;
alter table sdi_private.room_snapshot_audit enable row level security;
revoke all on sdi_private.room_project_snapshots,sdi_private.room_project_snapshot_chunks,sdi_private.room_project_snapshot_receipts,
 sdi_private.room_snapshot_budget,sdi_private.room_snapshot_audit from public,anon,authenticated;

-- Approved, non-revoked members other than the owner who hold no receipt yet.
create function sdi_private.room_snapshot_awaiting(s uuid) returns integer
language sql stable security definer set search_path='' as $$
 select count(*)::integer from sdi_private.room_project_snapshots x join public.sdi_rooms room on room.id=x.room_id
  join public.sdi_room_members m on m.room_id=x.room_id and m.user_id<>room.owner_id
  where x.id=s and m.owner_approved and m.member_accepted and not m.revoked
  and not exists(select 1 from sdi_private.room_project_snapshot_receipts r where r.snapshot_id=x.id and r.member=m.user_id)
$$;
revoke all on function sdi_private.room_snapshot_awaiting(uuid) from public,anon,authenticated;
-- Receipts held by members who are still active in the room.
create function sdi_private.room_snapshot_delivered(s uuid) returns integer
language sql stable security definer set search_path='' as $$
 select count(*)::integer from sdi_private.room_project_snapshot_receipts r join sdi_private.room_project_snapshots x on x.id=r.snapshot_id
  where r.snapshot_id=s and sdi_private.room_member_active(x.room_id,r.member)
$$;
revoke all on function sdi_private.room_snapshot_delivered(uuid) from public,anon,authenticated;

-- Delete a snapshot's bytes and record verified evidence. Never touches a device.
create function sdi_private.room_snapshot_discard(snapshot uuid,reason text,actor uuid default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare removed integer; remaining boolean; s sdi_private.room_project_snapshots;
begin
 select * into s from sdi_private.room_project_snapshots where id=snapshot for update;
 if not found or s.state='deleted' then return false; end if;
 delete from sdi_private.room_project_snapshot_chunks where snapshot_id=snapshot;
 get diagnostics removed=row_count;
 remaining:=exists(select 1 from sdi_private.room_project_snapshot_chunks where snapshot_id=snapshot);
 update sdi_private.room_project_snapshots set state='deleted',end_reason=reason,deleted_at=clock_timestamp(),delete_verified=not remaining where id=snapshot;
 insert into sdi_private.room_snapshot_audit(snapshot_id,room_id,actor,event,chunks_removed,verified) values(snapshot,s.room_id,actor,reason,removed,not remaining);
 return not remaining;
end $$;
revoke all on function sdi_private.room_snapshot_discard(uuid,text,uuid) from public,anon,authenticated;

create function sdi_private.room_snapshot(action text,room uuid default null,snapshot uuid default null,byte_size bigint default null,
 sha256 text default null,chunk_index integer default null,data text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); target public.sdi_rooms; s sdi_private.room_project_snapshots; n integer; raw bytea; whole bytea;
 expected integer; chunk_size constant integer:=262144; chunks integer; created uuid; is_owner boolean; verified boolean;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.room_snapshot_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when room_snapshot_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else room_snapshot_budget.attempts+1 end,
 window_start=case when room_snapshot_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else room_snapshot_budget.window_start end
 returning attempts into n;
 if n>600 then return jsonb_build_object('error','Too many handoff requests. Wait a minute.'); end if;
 if room is null or not sdi_private.room_access(room) then return jsonb_build_object('error','Room is unavailable.'); end if;
 select * into target from public.sdi_rooms where id=room and not closed;
 if not found then return jsonb_build_object('error','Room is unavailable.'); end if;
 is_owner:=target.owner_id=actor;
 -- The live snapshot of this room only; another room's snapshot id never resolves here.
 select * into s from sdi_private.room_project_snapshots x where x.room_id=target.id and x.state<>'deleted'
  and (snapshot is null or x.id=snapshot) for update;
 if found and (s.expires_at<=clock_timestamp() or s.project_ref is distinct from target.project_ref) then
  perform sdi_private.room_snapshot_discard(s.id,case when s.expires_at<=clock_timestamp() then 'expired' else 'project_changed' end);
  s:=null;
 end if;
 if action='current' then
  if s.id is null or (s.state<>'available' and not is_owner) then return jsonb_build_object('snapshot',null,'chunk_size',chunk_size); end if;
  return jsonb_build_object('chunk_size',chunk_size,'snapshot',jsonb_build_object('snapshot_id',s.id,'title',s.title,'project_ref',s.project_ref,
   'project_revision',s.project_revision,'byte_size',s.byte_size,'chunk_count',s.chunk_count,'sha256',s.sha256,'state',s.state,
   'offered_at',s.offered_at,'expires_at',s.expires_at,'mine',is_owner,
   'received_by_me',exists(select 1 from sdi_private.room_project_snapshot_receipts r where r.snapshot_id=s.id and r.member=actor),
   'received',case when is_owner then (select coalesce(jsonb_agg(c.idx order by c.idx),'[]'::jsonb) from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id) end,
   'delivered',case when is_owner then sdi_private.room_snapshot_delivered(s.id) end,
   'awaiting',case when is_owner then sdi_private.room_snapshot_awaiting(s.id) end));
 end if;
 if action='offer' then
  if not is_owner then return jsonb_build_object('error','Only the room owner can send the shared project.'); end if;
  if target.project_ref is null or target.project_title is null then return jsonb_build_object('error','Share a project in this room before sending it.'); end if;
  if byte_size is null or byte_size not between 1 and 33554432 or sha256 is null or sha256 !~ '^[a-f0-9]{64}$' then
   return jsonb_build_object('error','A project backup up to 32 MB and its SHA-256 are required.'); end if;
  if s.id is not null then
   if s.sha256=room_snapshot.sha256 and s.byte_size=room_snapshot.byte_size and s.project_revision=target.project_revision then
    return jsonb_build_object('status','existing','snapshot_id',s.id,'state',s.state,'chunk_size',chunk_size,'chunk_count',s.chunk_count,'expires_at',s.expires_at,
     'received',(select coalesce(jsonb_agg(c.idx order by c.idx),'[]'::jsonb) from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id));
   end if;
   perform sdi_private.room_snapshot_discard(s.id,'replaced',actor);
  end if;
  if (select count(*) from sdi_private.room_project_snapshots x where x.owner_id=actor and x.created_at>clock_timestamp()-interval '1 day')>=20 then
   return jsonb_build_object('error','Daily project handoff limit reached.'); end if;
  chunks:=((byte_size+chunk_size-1)/chunk_size)::integer;
  insert into sdi_private.room_project_snapshots(room_id,owner_id,project_ref,project_revision,title,byte_size,chunk_count,sha256,expires_at)
  values(target.id,actor,target.project_ref,target.project_revision,target.project_title,byte_size,chunks,sha256,clock_timestamp()+interval '1 hour')
  returning id into created;
  return jsonb_build_object('status','declared','snapshot_id',created,'state','receiving','chunk_size',chunk_size,'chunk_count',chunks,
   'expires_at',(select expires_at from sdi_private.room_project_snapshots where id=created));
 end if;
 if s.id is null then return jsonb_build_object('error','No shared project is waiting in this room.'); end if;
 if action='put' then
  if not is_owner or s.state<>'receiving' then return jsonb_build_object('error','No shared project is waiting in this room.'); end if;
  if chunk_index is null or chunk_index<0 or chunk_index>=s.chunk_count or data is null or length(data)>360000 then
   return jsonb_build_object('error','Chunk index or size is invalid.'); end if;
  begin raw:=decode(data,'base64'); exception when others then return jsonb_build_object('error','Chunk is not valid base64.'); end;
  expected:=case when chunk_index=s.chunk_count-1 then s.byte_size-chunk_index*chunk_size else chunk_size end;
  if octet_length(raw)<>expected then return jsonb_build_object('error','Chunk length does not match the declared size.'); end if;
  insert into sdi_private.room_project_snapshot_chunks(snapshot_id,idx,data) values(s.id,chunk_index,raw)
  on conflict(snapshot_id,idx) do update set data=excluded.data;
  return jsonb_build_object('status','stored','received',(select count(*) from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id));
 elsif action='finalize' then
  if not is_owner or s.state<>'receiving' then return jsonb_build_object('error','No shared project is waiting in this room.'); end if;
  if (select count(*) from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id)<>s.chunk_count then
   return jsonb_build_object('error','incomplete','received',(select coalesce(jsonb_agg(c.idx order by c.idx),'[]'::jsonb) from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id));
  end if;
  select string_agg(c.data,''::bytea order by c.idx) into whole from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id;
  if octet_length(whole)<>s.byte_size or encode(extensions.digest(whole,'sha256'),'hex')<>s.sha256 then
   perform sdi_private.room_snapshot_discard(s.id,'rejected',actor);
   return jsonb_build_object('error','The sent project was corrupt and has been discarded. Send it again.');
  end if;
  update sdi_private.room_project_snapshots set state='available',offered_at=clock_timestamp(),expires_at=clock_timestamp()+interval '72 hours' where id=s.id;
  insert into sdi_private.room_snapshot_audit(snapshot_id,room_id,actor,event) values(s.id,target.id,actor,'offered');
  return jsonb_build_object('status','available','snapshot_id',s.id,'awaiting',sdi_private.room_snapshot_awaiting(s.id),
   'expires_at',(select expires_at from sdi_private.room_project_snapshots where id=s.id));
 elsif action='get' then
  if is_owner or s.state<>'available' or not sdi_private.room_member_active(target.id,actor) then
   return jsonb_build_object('error','No shared project is waiting in this room.'); end if;
  if chunk_index is null or chunk_index<0 or chunk_index>=s.chunk_count then return jsonb_build_object('error','Chunk index is invalid.'); end if;
  return jsonb_build_object('snapshot_id',s.id,'chunk_index',chunk_index,'chunk_count',s.chunk_count,'sha256',s.sha256,
   'data',(select encode(c.data,'base64') from sdi_private.room_project_snapshot_chunks c where c.snapshot_id=s.id and c.idx=chunk_index));
 elsif action='receipt' then
  -- The member verified the SHA-256 and imported a new device project.
  if is_owner or s.state<>'available' or not sdi_private.room_member_active(target.id,actor) then
   return jsonb_build_object('error','No shared project is waiting in this room.'); end if;
  if sha256 is distinct from s.sha256 then return jsonb_build_object('error','The receipt does not match the shared project.'); end if;
  insert into sdi_private.room_project_snapshot_receipts(snapshot_id,member) values(s.id,actor) on conflict do nothing;
  if found then insert into sdi_private.room_snapshot_audit(snapshot_id,room_id,actor,event) values(s.id,target.id,actor,'downloaded'); end if;
  if sdi_private.room_snapshot_awaiting(s.id)=0 then
   verified:=sdi_private.room_snapshot_discard(s.id,'delivered',actor);
   return jsonb_build_object('status','recorded','server_copy','deleted','verified',verified);
  end if;
  return jsonb_build_object('status','recorded','server_copy','retained');
 elsif action='revoke' then
  if not is_owner then return jsonb_build_object('error','Only the room owner can withdraw the shared project.'); end if;
  return jsonb_build_object('status','revoked','verified',sdi_private.room_snapshot_discard(s.id,'revoked',actor));
 end if;
 return jsonb_build_object('error','Unsupported handoff operation.');
end $$;
revoke all on function sdi_private.room_snapshot(text,uuid,uuid,bigint,text,integer,text) from public,anon;
grant execute on function sdi_private.room_snapshot(text,uuid,uuid,bigint,text,integer,text) to authenticated;
create function public.sdi_room_snapshot(action text,room uuid default null,snapshot uuid default null,byte_size bigint default null,
 sha256 text default null,chunk_index integer default null,data text default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.room_snapshot(action,room,snapshot,byte_size,sha256,chunk_index,data)$$;
revoke all on function public.sdi_room_snapshot(text,uuid,uuid,bigint,text,integer,text) from public,anon;
grant execute on function public.sdi_room_snapshot(text,uuid,uuid,bigint,text,integer,text) to authenticated;

-- The service sweep now also deletes project snapshots that expired, whose room
-- closed, whose shared project changed, or that every current member received.
create or replace function sdi_private.room_asset_sweep(max_items integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item record; done integer:=0; verified integer:=0; snap_done integer:=0; snap_verified integer:=0; cap integer;
begin
 cap:=least(greatest(coalesce(max_items,200),1),1000);
 for item in
  select x.id,case when room.closed then 'room_closed'
   when not sdi_private.room_member_active(x.room_id,x.uploader) then 'membership_ended' else 'expired' end as reason
  from sdi_private.room_assets x join public.sdi_rooms room on room.id=x.room_id
  where x.state<>'deleted' and (x.expires_at<=clock_timestamp() or room.closed or not sdi_private.room_member_active(x.room_id,x.uploader))
  order by x.expires_at limit cap
 loop
  done:=done+1;
  if sdi_private.room_asset_discard(item.id,item.reason) then verified:=verified+1; end if;
 end loop;
 for item in
  select x.id,case when room.closed then 'room_closed' when x.expires_at<=clock_timestamp() then 'expired'
   when x.project_ref is distinct from room.project_ref or room.owner_id<>x.owner_id then 'project_changed' else 'delivered' end as reason
  from sdi_private.room_project_snapshots x join public.sdi_rooms room on room.id=x.room_id
  where x.state<>'deleted' and (room.closed or x.expires_at<=clock_timestamp() or x.project_ref is distinct from room.project_ref
   or room.owner_id<>x.owner_id
   or (x.state='available' and sdi_private.room_snapshot_delivered(x.id)>0 and sdi_private.room_snapshot_awaiting(x.id)=0))
  order by x.expires_at limit cap
 loop
  snap_done:=snap_done+1;
  if sdi_private.room_snapshot_discard(item.id,item.reason) then snap_verified:=snap_verified+1; end if;
 end loop;
 return jsonb_build_object('discarded',done,'verified',verified,
  'unverified_total',(select count(*) from sdi_private.room_assets where state='deleted' and not delete_verified),
  'snapshots_discarded',snap_done,'snapshots_verified',snap_verified,
  'snapshots_unverified_total',(select count(*) from sdi_private.room_project_snapshots where state='deleted' and not delete_verified));
end $$;
commit;
