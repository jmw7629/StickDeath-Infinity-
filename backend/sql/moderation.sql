-- Unapplied candidate. Install after admin-users.sql.
begin;
alter table sdi_private.feed_reports add column id uuid not null default gen_random_uuid() unique;
alter table sdi_private.feed_reports add column state text not null default 'pending' check(state in('pending','dismissed','removed'));
alter table sdi_private.feed_reports add column version bigint not null default 1;
create table sdi_private.moderation_audit (
 id uuid primary key default gen_random_uuid(), report_id uuid not null,
 actor uuid not null references auth.users(id), action text not null,
 reason text not null check(length(reason) between 1 and 2000),
 media_id uuid not null, render_digest text not null, created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.removal_jobs (
 id uuid primary key default gen_random_uuid(), media_id uuid not null references public.sdi_watch_media(id),
 render_digest text not null, state text not null default 'pending' check(state in('pending','running','complete','failed')),
 reason text not null, created_at timestamptz not null default clock_timestamp(),
 unique(media_id,render_digest)
);
create table sdi_private.moderation_appeals (
 id uuid primary key default gen_random_uuid(), media_id uuid not null references public.sdi_watch_media(id),
 creator uuid not null references auth.users(id), explanation text not null check(length(explanation) between 1 and 2000),
 state text not null default 'pending' check(state in('pending','accepted','rejected')),
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.moderation_audit enable row level security;
alter table sdi_private.removal_jobs enable row level security;
alter table sdi_private.moderation_appeals enable row level security;
revoke all on sdi_private.moderation_audit,sdi_private.removal_jobs,sdi_private.moderation_appeals from public,anon,authenticated;
create function sdi_private.report_revision() returns trigger language plpgsql set search_path='' as $$
begin
 if new.reason is distinct from old.reason then new.version=old.version+1;new.state='pending';end if;
 return new;
end $$;
revoke all on function sdi_private.report_revision() from public;
create trigger report_revision before update on sdi_private.feed_reports for each row execute function sdi_private.report_revision();
create function sdi_private.moderation_action(action text,report uuid default null,version bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; r sdi_private.feed_reports; p sdi_private.feed_posts; video public.sdi_watch_media;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA authorization required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select r.id,r.reason,r.version,r.created_at,p.caption,p.creator,m.title,m.url,m.render_digest
   from sdi_private.feed_reports r join sdi_private.feed_posts p on p.id=r.post
   join public.sdi_watch_media m on m.id=p.media_id where r.state='pending'
   order by r.created_at,r.id limit 50
  ) item;
  return jsonb_build_object('reports',result);
 end if;
 if action is null or action not in('dismiss','remove') or report is null or version is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','A current report and decision reason are required.');end if;
 select * into r from sdi_private.feed_reports where id=report for update;
 if not found or r.state<>'pending' or r.version<>version then return jsonb_build_object('error','Report changed. Refresh the queue.');end if;
 select * into p from sdi_private.feed_posts where id=r.post for update;
 if p.creator=auth.uid() or r.actor=auth.uid() then return jsonb_build_object('error','Another administrator must review this report.');end if;
 select * into video from public.sdi_watch_media where id=p.media_id for update;
 if action='remove' then
  update public.sdi_watch_media set approved=false where id=video.id;
  update sdi_private.feed_posts set visible=false where media_id=video.id;
  update sdi_private.war_matches set status='removed' where left_media=video.id or right_media=video.id;
  update sdi_private.render_reviews set state='pending',version=render_reviews.version+1 where render_digest=video.render_digest;
  insert into sdi_private.removal_jobs(media_id,render_digest,reason) values(video.id,video.render_digest,trim(note))
   on conflict(media_id,render_digest) do update set state='pending',reason=excluded.reason;
 end if;
 update sdi_private.feed_reports set state=case action when 'remove' then 'removed' else 'dismissed' end where id=r.id;
 insert into sdi_private.moderation_audit(report_id,actor,action,reason,media_id,render_digest)
 values(r.id,auth.uid(),action,trim(note),video.id,video.render_digest);
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.moderation_action(text,uuid,bigint,text) from public;
grant execute on function sdi_private.moderation_action(text,uuid,bigint,text) to authenticated;
create function public.sdi_moderation_action(action text,report uuid default null,version bigint default null,note text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.moderation_action(action,report,version,note)$$;
revoke all on function public.sdi_moderation_action(text,uuid,bigint,text) from public,anon;
grant execute on function public.sdi_moderation_action(text,uuid,bigint,text) to authenticated;
alter table sdi_private.feed_posts add column feature_revision bigint not null default 1;
create table sdi_private.feed_curation_audit (
 id uuid primary key default gen_random_uuid(), post uuid not null references sdi_private.feed_posts(id),
 actor uuid not null references auth.users(id), previous_featured boolean not null, featured boolean not null,
 revision bigint not null, reason text not null check(length(reason) between 1 and 2000),
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.feed_curation_audit enable row level security;
revoke all on sdi_private.feed_curation_audit from public,anon,authenticated;
-- Metadata inventory only: private preview URLs and reporter identities are
-- deliberately absent. Review/removal stays in the audited moderation workflow.
create function sdi_private.admin_content(page integer default 0,query text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current moderation permission and MFA required.');end if;
 if page is null or page<0 or page>199 or query is null or length(query)>100 then
  return jsonb_build_object('error','Invalid content query.');end if;
 select coalesce(jsonb_agg(row_to_json(entry)),'[]'::jsonb) into items from (
  select p.id,p.creator,p.creator_name,p.caption,p.published_at,p.visible,p.featured,p.feature_revision,p.allow_export,
   m.title,m.approved,m.expires_at,
   (select count(*) from sdi_private.feed_reports r where r.post=p.id) as report_count,
   (select count(*) from sdi_private.feed_reports r where r.post=p.id and r.state='pending') as pending_report_count
  from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
  where query='' or p.id::text=query or p.creator::text=query
   or position(lower(query) in lower(p.creator_name))>0 or position(lower(query) in lower(m.title))>0
  order by p.published_at desc,p.id limit 51 offset page*50
 ) entry;
 return jsonb_build_object('posts',(select coalesce(jsonb_agg(value),'[]'::jsonb)
  from (select value from jsonb_array_elements(items) with ordinality as v(value,n) where n<=50 order by n) bounded),
  'has_more',jsonb_array_length(items)>50);
end $$;
revoke all on function sdi_private.admin_content(integer,text) from public,anon;
grant execute on function sdi_private.admin_content(integer,text) to authenticated;
create function public.sdi_admin_content(page integer default 0,query text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.admin_content(page,query)$$;
revoke all on function public.sdi_admin_content(integer,text) from public,anon;
grant execute on function public.sdi_admin_content(integer,text) to authenticated;
create function sdi_private.feature_content(post uuid,revision bigint,featured boolean,reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item sdi_private.feed_posts; media public.sdi_watch_media;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current moderation permission and MFA required.');end if;
 if post is null or revision is null or featured is null or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','A current post and curation reason are required.');end if;
 select * into item from sdi_private.feed_posts where id=post for update;
 if not found or item.feature_revision<>revision then return jsonb_build_object('error','Content changed. Refresh before curating.');end if;
 if item.featured=featured then return jsonb_build_object('status','unchanged');end if;
 if featured then
  select * into media from public.sdi_watch_media where id=item.media_id for update;
  if not found or not item.visible or not media.approved or media.owner_id<>item.creator
   or media.render_digest is null or (media.expires_at is not null and media.expires_at<=clock_timestamp())
   or exists(select 1 from sdi_private.account_controls where user_id=item.creator and state<>'active') then
   return jsonb_build_object('error','Only currently visible, approved and eligible content can be featured.');end if;
 end if;
 update sdi_private.feed_posts set featured=feature_content.featured,feature_revision=feature_revision+1 where id=post;
 insert into sdi_private.feed_curation_audit(post,actor,previous_featured,featured,revision,reason)
 values(post,auth.uid(),item.featured,featured,item.feature_revision+1,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.feature_content(uuid,bigint,boolean,text) from public,anon;
grant execute on function sdi_private.feature_content(uuid,bigint,boolean,text) to authenticated;
create function public.sdi_feature_content(post uuid,revision bigint,featured boolean,reason text) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.feature_content(post,revision,featured,reason)$$;
revoke all on function public.sdi_feature_content(uuid,bigint,boolean,text) from public,anon;
grant execute on function public.sdi_feature_content(uuid,bigint,boolean,text) to authenticated;
commit;
