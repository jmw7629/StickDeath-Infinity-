-- Unapplied candidate. Requires admin-approval.sql and current feature candidates.
begin;
create table sdi_private.account_controls (
 user_id uuid primary key references auth.users(id) on delete cascade,
 state text not null check(state in('active','suspended','banned')),
 reason text not null, updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.admin_user_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id),
 subject uuid not null, action text not null, reason text not null check(length(reason) between 1 and 2000),
 previous_state text, created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.account_controls enable row level security;
alter table sdi_private.admin_user_audit enable row level security;
create index admin_user_audit_subject_history on sdi_private.admin_user_audit(subject,created_at desc,id desc);
revoke all on sdi_private.account_controls,sdi_private.admin_user_audit from public,anon,authenticated;
create function sdi_private.account_active() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from auth.users where id=auth.uid())
 and not exists(select 1 from sdi_private.account_controls where user_id=auth.uid() and state<>'active')
 and exists(select 1 from auth.sessions where user_id=auth.uid() and id::text=auth.jwt()->>'session_id')
$$;
revoke all on function sdi_private.account_active() from public;
grant execute on function sdi_private.account_active() to authenticated;
create function sdi_private.users_action(action text,subject uuid default null,query text default '',page integer default 0,reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; before_state text;
begin
 if not sdi_private.admin_can('users') or not sdi_private.account_active() then return jsonb_build_object('error','Administrator MFA authorization required.'); end if;
 if action='history' then
  if subject is null or page is null or page<0 or page>199 then return jsonb_build_object('error','Select an account and valid history page.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select a.id,a.actor,a.subject,a.action,a.reason,a.previous_state,a.created_at
   from sdi_private.admin_user_audit a where a.subject=users_action.subject
   order by a.created_at desc,a.id desc limit 50 offset page*50
  ) item;
  return jsonb_build_object('events',result,'has_more',exists(
   select 1 from sdi_private.admin_user_audit a where a.subject=users_action.subject
   order by a.created_at desc,a.id desc limit 1 offset (page+1)*50));
 end if;
 if action='list' then
  if page is null or page<0 or page>199 or query is null or length(query)>100 then return jsonb_build_object('error','Invalid directory query.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select u.id, coalesce(u.raw_user_meta_data->>'username','Member') as username,
    case when u.email is null then null else left(u.email,1)||'***@'||split_part(u.email,'@',2) end as masked_email,
    u.created_at,u.last_sign_in_at,coalesce(c.state,'active') as state,
    (select count(*) from sdi_private.feed_posts p where p.creator=u.id) as content_count,
    (select coalesce(jsonb_agg(method.provider order by method.provider),'[]'::jsonb)
     from (select distinct i.provider from auth.identities i where i.user_id=u.id) method) as sign_in_methods,
    case when sdi_private.admin_can('moderation') then
     (select count(*) from sdi_private.feed_reports r join sdi_private.feed_posts p on p.id=r.post where p.creator=u.id)
     else null end as feed_report_count
   from auth.users u left join sdi_private.account_controls c on c.user_id=u.id
   where query='' or position(lower(query) in lower(coalesce(u.raw_user_meta_data->>'username','')))>0 or u.id::text=query
   order by u.created_at desc,u.id limit 50 offset page*50
  ) item;
  return jsonb_build_object('users',result,'has_more',jsonb_array_length(result)=50);
 end if;
 if subject is null or subject=auth.uid() or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','Select another account and provide a reason.'); end if;
 if exists(select 1 from sdi_private.admin_roles where user_id=subject and enabled) then
  return jsonb_build_object('error','Administrator accounts require the separate owner recovery procedure.'); end if;
 perform 1 from auth.users where id=subject for update;
 if not found then return jsonb_build_object('error','Account unavailable.'); end if;
 select state into before_state from sdi_private.account_controls where user_id=subject;
 if action in('suspend','ban','restore') then
  insert into sdi_private.account_controls(user_id,state,reason) values(subject,
   case action when 'suspend' then 'suspended' when 'ban' then 'banned' else 'active' end,trim(reason))
  on conflict(user_id) do update set state=excluded.state,reason=excluded.reason,updated_at=clock_timestamp();
 elsif action not in('signout','note') then return jsonb_build_object('error','Unsupported account action.'); end if;
 if action in('suspend','ban','signout') then delete from auth.sessions where user_id=subject; end if;
 insert into sdi_private.admin_user_audit(actor,subject,action,reason,previous_state) values(auth.uid(),subject,action,trim(reason),coalesce(before_state,'active'));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.users_action(text,uuid,text,integer,text) from public;
grant execute on function sdi_private.users_action(text,uuid,text,integer,text) to authenticated;
create function public.sdi_users_action(action text,subject uuid default null,query text default '',page integer default 0,reason text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.users_action(action,subject,query,page,reason)$$;
revoke all on function public.sdi_users_action(text,uuid,text,integer,text) from public,anon;
grant execute on function public.sdi_users_action(text,uuid,text,integer,text) to authenticated;

-- Restrictive policies apply session/suspension checks alongside membership.
create policy active_account_rooms on public.sdi_rooms as restrictive for all to authenticated
 using(sdi_private.account_active()) with check(sdi_private.account_active());
create policy active_account_members on public.sdi_room_members as restrictive for all to authenticated
 using(sdi_private.account_active()) with check(sdi_private.account_active());
create policy active_account_watch on public.sdi_watch_sessions as restrictive for all to authenticated
 using(sdi_private.account_active()) with check(sdi_private.account_active());
create policy active_account_media on public.sdi_watch_media as restrictive for all to authenticated
 using(sdi_private.account_active()) with check(sdi_private.account_active());

-- A restricted member may authenticate afresh solely to read/appeal their own
-- restriction. This does not relax account_active() on any product endpoint.
create table sdi_private.account_appeals (
 id uuid primary key default gen_random_uuid(),
 subject uuid not null references auth.users(id) on delete cascade,
 restriction_at timestamptz not null,
 explanation text not null check(length(explanation) between 1 and 2000),
 state text not null default 'pending' check(state in('pending','accepted','rejected','superseded')),
 reply text check(length(reply)<=2000), reviewer uuid references auth.users(id),
 created_at timestamptz not null default clock_timestamp(), decided_at timestamptz,
 unique(subject,restriction_at)
);
alter table sdi_private.account_appeals enable row level security;
revoke all on sdi_private.account_appeals from public,anon,authenticated;
create index account_appeals_queue on sdi_private.account_appeals(state,created_at,id);
create function sdi_private.account_appeal_action(action text,appeal uuid default null,
 explanation text default '',reply text default '',restriction text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); control sdi_private.account_controls;
 item sdi_private.account_appeals; target uuid; items jsonb; outcome jsonb;
begin
 if actor_id is null or not exists(select 1 from auth.users where id=actor_id and not is_anonymous)
 or not exists(select 1 from auth.sessions where user_id=actor_id and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.');end if;
 if action in('mine','submit') then
  -- Use the same lock order as account actions: user, control, appeal.
  perform 1 from auth.users where id=actor_id for update;
  select * into control from sdi_private.account_controls where user_id=actor_id for update;
  if action='submit' then
   if control.user_id is null or control.state='active' then return jsonb_build_object('error','No current account restriction to appeal.');end if;
   if restriction is distinct from control.updated_at::text then return jsonb_build_object('error','Account restriction changed. Refresh before submitting.');end if;
   if explanation is null or length(trim(explanation)) not between 1 and 2000 then
    return jsonb_build_object('error','Explain your request in 1–2000 characters.');end if;
   if not exists(select 1 from sdi_private.account_appeals where subject=actor_id and restriction_at=control.updated_at) then
    if (select count(*) from sdi_private.account_appeals where subject=actor_id and created_at>clock_timestamp()-interval '1 day')>=3 then
     return jsonb_build_object('error','Daily appeal limit reached.');end if;
    insert into sdi_private.account_appeals(subject,restriction_at,explanation)
    values(actor_id,control.updated_at,trim(explanation));
   end if;
  end if;
  select coalesce(jsonb_agg(row_to_json(entry)),'[]'::jsonb) into items from (
   select id,explanation,state,reply,created_at,decided_at from sdi_private.account_appeals
   where subject=actor_id order by created_at desc,id desc limit 20
  ) entry;
  return jsonb_build_object('account_state',coalesce(control.state,'active'),'restriction',control.updated_at::text,'appeals',items,
   'can_appeal',coalesce(control.state<>'active',false) and not exists(
    select 1 from sdi_private.account_appeals where subject=actor_id and restriction_at=control.updated_at));
 end if;
 if not sdi_private.admin_can('users') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current administrator MFA authorization required.');end if;
 if action='queue' then
  select coalesce(jsonb_agg(row_to_json(entry)),'[]'::jsonb) into items from (
   select a.id,a.subject,a.explanation,a.state,a.created_at,c.state as account_state
   from sdi_private.account_appeals a left join sdi_private.account_controls c on c.user_id=a.subject
   where a.state='pending' order by a.created_at,a.id limit 50
  ) entry;
  return jsonb_build_object('appeals',items);
 end if;
 if action is null or action not in('accept','reject') or appeal is null
 or reply is null or length(trim(reply)) not between 1 and 2000 then
  return jsonb_build_object('error','Select an appeal and provide a member-visible decision reason.');end if;
 select subject into target from sdi_private.account_appeals where id=appeal;
 if target is null or target=actor_id then return jsonb_build_object('error','Appeal unavailable for review.');end if;
 perform 1 from auth.users where id=target for update;
 select * into control from sdi_private.account_controls where user_id=target for update;
 select * into item from sdi_private.account_appeals where id=appeal for update;
 if item.state<>'pending' then return jsonb_build_object('error','This appeal was already decided. Refresh the queue.');end if;
 if control.user_id is null or control.state='active' or control.updated_at<>item.restriction_at then
  update sdi_private.account_appeals set state='superseded',reviewer=actor_id,decided_at=clock_timestamp(),
   reply='The account restriction changed. Check your current account status.' where id=appeal;
  return jsonb_build_object('status','superseded');end if;
 if action='accept' then
  outcome=sdi_private.users_action('restore',target,'',0,'Appeal '||appeal::text||': '||left(trim(reply),1900));
  if outcome->>'status' is distinct from 'confirmed' then return outcome;end if;
 else
  insert into sdi_private.admin_user_audit(actor,subject,action,reason,previous_state)
  values(actor_id,target,'appeal_rejected','Appeal '||appeal::text||': '||left(trim(reply),1900),control.state);
 end if;
 update sdi_private.account_appeals set state=case action when 'accept' then 'accepted' else 'rejected' end,
  reply=trim(reply),reviewer=actor_id,decided_at=clock_timestamp() where id=appeal;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.account_appeal_action(text,uuid,text,text,text) from public,anon;
grant execute on function sdi_private.account_appeal_action(text,uuid,text,text,text) to authenticated;
create function public.sdi_account_appeal_action(action text,appeal uuid default null,
 explanation text default '',reply text default '',restriction text default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.account_appeal_action(action,appeal,explanation,reply,restriction)$$;
revoke all on function public.sdi_account_appeal_action(text,uuid,text,text,text) from public,anon;
grant execute on function public.sdi_account_appeal_action(text,uuid,text,text,text) to authenticated;

commit;
