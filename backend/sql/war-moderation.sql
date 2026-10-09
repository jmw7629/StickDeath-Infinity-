-- Unapplied candidate. Install after war-finalization.sql and admin-users.sql.
begin;
create table sdi_private.war_reports (
 id uuid primary key default gen_random_uuid(), match_id uuid not null references sdi_private.war_matches(id),
 reporter uuid not null references auth.users(id), reason text not null check(length(reason) between 1 and 2000),
 state text not null default 'pending' check(state in('pending','dismissed','removed')),
 revision bigint not null default 1, created_at timestamptz not null default clock_timestamp(),
 unique(match_id,reporter)
);
create table sdi_private.war_moderation_audit (
 id uuid primary key default gen_random_uuid(), report_id uuid not null references sdi_private.war_reports(id),
 match_id uuid not null references sdi_private.war_matches(id), actor uuid not null references auth.users(id),
 decision text not null, previous_status text not null, reason text not null,
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.war_reports enable row level security;
alter table sdi_private.war_moderation_audit enable row level security;
revoke all on sdi_private.war_reports,sdi_private.war_moderation_audit from public,anon,authenticated;
create function sdi_private.war_report(match uuid,reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare m sdi_private.war_matches;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account required.');end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','Describe the issue in up to 2000 characters.');end if;
 select * into m from sdi_private.war_matches where id=match;
 if not found or not (m.status in('active','completed') or auth.uid() in(m.creator,m.opponent)) then
  return jsonb_build_object('error','Matchup unavailable.');end if;
 if exists(select 1 from sdi_private.war_reports where match_id=match and reporter=auth.uid()) then
  return jsonb_build_object('status','recorded');end if;
 if (select count(*) from sdi_private.war_reports where reporter=auth.uid() and created_at>clock_timestamp()-interval '1 day')>=10 then
  return jsonb_build_object('error','Daily report limit reached.');end if;
 insert into sdi_private.war_reports(match_id,reporter,reason) values(match,auth.uid(),trim(reason)) on conflict do nothing;
 return jsonb_build_object('status','recorded');
end $$;
create function sdi_private.war_moderate(action text,report uuid default null,revision bigint default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.war_reports; m sdi_private.war_matches; items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select r.id,r.match_id,r.reason,r.revision,r.created_at,w.status,
    l.title as left_title,v.title as right_title,l.url as left_url,v.url as right_url
   from sdi_private.war_reports r join sdi_private.war_matches w on w.id=r.match_id
   join public.sdi_watch_media l on l.id=w.left_media left join public.sdi_watch_media v on v.id=w.right_media
   where r.state='pending' order by r.created_at,r.id limit 50
  ) item;
  return jsonb_build_object('reports',items);
 end if;
 if action is null or action not in('dismiss','remove') or revision is null or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','A current report and decision reason are required.');end if;
 select * into r from sdi_private.war_reports where id=report for update;
 if not found or r.state<>'pending' or r.revision<>revision then return jsonb_build_object('error','Report changed. Refresh.');end if;
 select * into m from sdi_private.war_matches where id=r.match_id for update;
 if auth.uid() in(m.creator,m.opponent,r.reporter) then return jsonb_build_object('error','An uninvolved administrator must decide.');end if;
 if action='remove' then
  update sdi_private.war_matches set status='removed' where id=m.id;
  -- Keep votes and final snapshot for audit, but removed matches do not count
  -- toward profile records. This does not delete a creator's media or original.
 end if;
 update sdi_private.war_reports set state=case action when 'remove' then 'removed' else 'dismissed' end,
  revision=war_reports.revision+1 where id=r.id;
 insert into sdi_private.war_moderation_audit(report_id,match_id,actor,decision,previous_status,reason)
 values(r.id,m.id,auth.uid(),action,m.status,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.war_report(uuid,text),sdi_private.war_moderate(text,uuid,bigint,text) from public,anon;
grant execute on function sdi_private.war_report(uuid,text),sdi_private.war_moderate(text,uuid,bigint,text) to authenticated;
create function public.sdi_war_report(match uuid,reason text) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.war_report(match,reason)$$;
create function public.sdi_war_moderate(action text,report uuid default null,revision bigint default null,reason text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.war_moderate(action,report,revision,reason)$$;
revoke all on function public.sdi_war_report(uuid,text),public.sdi_war_moderate(text,uuid,bigint,text) from public,anon;
grant execute on function public.sdi_war_report(uuid,text),public.sdi_war_moderate(text,uuid,bigint,text) to authenticated;
commit;
