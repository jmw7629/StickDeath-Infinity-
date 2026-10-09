-- Unapplied candidate. Install after war-moderation.sql.
begin;
create table sdi_private.war_appeals (
 id uuid primary key default gen_random_uuid(), decision_id uuid not null references sdi_private.war_moderation_audit(id),
 appellant uuid not null references auth.users(id), explanation text not null check(length(explanation) between 1 and 2000),
 state text not null default 'pending' check(state in('pending','accepted','rejected')),
 reviewer uuid references auth.users(id), review_note text, revision bigint not null default 1,
 created_at timestamptz not null default clock_timestamp(), decided_at timestamptz,
 unique(decision_id,appellant)
);
alter table sdi_private.war_appeals enable row level security;
revoke all on sdi_private.war_appeals from public,anon,authenticated;
create function sdi_private.war_notices(action text,decision uuid default null,explanation text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare d sdi_private.war_moderation_audit; m sdi_private.war_matches; items jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select d.id,d.match_id,d.created_at,'Matchup removed after administrator review.' as message,
    a.state as appeal_state,d.created_at+interval '30 days' as appeal_deadline
   from sdi_private.war_moderation_audit d join sdi_private.war_matches w on w.id=d.match_id
   left join sdi_private.war_appeals a on a.decision_id=d.id and a.appellant=auth.uid()
   where d.decision='remove' and auth.uid() in(w.creator,w.opponent)
   order by d.created_at desc,d.id limit 100
  ) item;
  return jsonb_build_object('notices',items);
 end if;
 if action is null or action<>'appeal' or decision is null or explanation is null or length(trim(explanation)) not between 1 and 2000 then
  return jsonb_build_object('error','Select a decision and explain your appeal.');end if;
 select * into d from sdi_private.war_moderation_audit where id=war_notices.decision and war_moderation_audit.decision='remove';
 if not found or d.created_at<clock_timestamp()-interval '30 days' then return jsonb_build_object('error','Decision unavailable for appeal.');end if;
 select * into m from sdi_private.war_matches where id=d.match_id for update;
 if auth.uid() not in(m.creator,m.opponent) then return jsonb_build_object('error','Only participants may appeal.');end if;
 insert into sdi_private.war_appeals(decision_id,appellant,explanation) values(d.id,auth.uid(),trim(explanation)) on conflict do nothing;
 return jsonb_build_object('status','recorded');
end $$;
create function sdi_private.war_appeal_admin(action text,appeal uuid default null,revision bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare a sdi_private.war_appeals; d sdi_private.war_moderation_audit; m sdi_private.war_matches; items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select a.id,a.explanation,a.revision,a.created_at,d.match_id,d.reason as decision_reason,d.previous_status,
    w.left_digest,w.right_digest,l.title as left_title,r.title as right_title,l.url as left_url,r.url as right_url
   from sdi_private.war_appeals a join sdi_private.war_moderation_audit d on d.id=a.decision_id
   join sdi_private.war_matches w on w.id=d.match_id
   join public.sdi_watch_media l on l.id=w.left_media left join public.sdi_watch_media r on r.id=w.right_media
   where a.state='pending' order by a.created_at,a.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if action is null or action not in('accept','reject') or revision is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','A current appeal and reason are required.');end if;
 select * into a from sdi_private.war_appeals where id=appeal for update;
 if not found or a.state<>'pending' or a.revision<>revision then return jsonb_build_object('error','Appeal changed. Refresh.');end if;
 select * into d from sdi_private.war_moderation_audit where id=a.decision_id;
 select * into m from sdi_private.war_matches where id=d.match_id for update;
 if auth.uid() in(a.appellant,d.actor,m.creator,m.opponent) or exists(select 1 from sdi_private.war_reports where id=d.report_id and reporter=auth.uid()) then
  return jsonb_build_object('error','Another uninvolved administrator must review this appeal.');end if;
 if action='accept' then
  if m.status<>'removed' or exists(select 1 from sdi_private.war_moderation_audit where match_id=m.id and created_at>d.created_at and decision='remove')
   or d.previous_status not in('pending','active','completed') then return jsonb_build_object('error','A newer restriction requires separate review.');end if;
  if not exists(select 1 from public.sdi_watch_media where id=m.left_media and approved and render_digest=m.left_digest
   and (expires_at is null or expires_at>clock_timestamp()))
   or (d.previous_status<>'pending' and not exists(select 1 from public.sdi_watch_media where id=m.right_media and approved
   and render_digest=m.right_digest and (expires_at is null or expires_at>clock_timestamp()))) then
   return jsonb_build_object('error','The exact submitted media must remain approved and available.');end if;
  update sdi_private.war_matches set status=d.previous_status where id=m.id;
 end if;
 update sdi_private.war_appeals set state=case action when 'accept' then 'accepted' else 'rejected' end,
 reviewer=auth.uid(),review_note=trim(note),revision=war_appeals.revision+1,decided_at=clock_timestamp() where id=a.id;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.war_notices(text,uuid,text),sdi_private.war_appeal_admin(text,uuid,bigint,text) from public,anon;
grant execute on function sdi_private.war_notices(text,uuid,text),sdi_private.war_appeal_admin(text,uuid,bigint,text) to authenticated;
create function public.sdi_war_notices(action text,decision uuid default null,explanation text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.war_notices(action,decision,explanation)$$;
create function public.sdi_war_appeal_admin(action text,appeal uuid default null,revision bigint default null,note text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.war_appeal_admin(action,appeal,revision,note)$$;
revoke all on function public.sdi_war_notices(text,uuid,text),public.sdi_war_appeal_admin(text,uuid,bigint,text) from public,anon;
grant execute on function public.sdi_war_notices(text,uuid,text),public.sdi_war_appeal_admin(text,uuid,bigint,text) to authenticated;
commit;
