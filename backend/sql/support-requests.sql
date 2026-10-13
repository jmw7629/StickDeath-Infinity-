-- Unapplied candidate. Install after admin-hardening.sql (needs admin-users.sql and
-- pgcrypto in extensions). Customer support intake for #272: authenticated members
-- file bounded requests with a server receipt, idempotency key and five-per-day limit;
-- administrators with the users capability and MFA work the queue. This is support,
-- not messaging: no member-to-member delivery, no attachments in this candidate and
-- private projects are never uploaded. Bounded retention is recorded per request.
begin;
create table sdi_private.support_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 category text not null check(category in('account','billing','studio','publishing','rights','safety','bug','other')),
 platform text not null check(platform in('ios','android','web','other')), app_version text not null default '' check(length(app_version)<=50),
 subject text not null check(length(subject) between 1 and 120), body text not null check(length(body) between 1 and 2000),
 status text not null default 'open' check(status in('open','in_progress','waiting_on_member','resolved','withdrawn','deleted')),
 receipt text not null unique check(receipt ~ '^SDI-[A-Z0-9]{10}$'), idempotency_key uuid not null,
 admin_note text not null default '' check(length(admin_note)<=2000), revision bigint not null default 1,
 retention_until timestamptz not null, created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 unique(user_id,idempotency_key)
);
create table sdi_private.support_audit (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references sdi_private.support_requests(id) on delete cascade,
 actor uuid references auth.users(id) on delete set null, action text not null, previous_status text not null,
 note text not null default '' check(length(note)<=2000), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.support_requests enable row level security;
alter table sdi_private.support_audit enable row level security;
revoke all on sdi_private.support_requests,sdi_private.support_audit from public,anon,authenticated;
create index support_requests_queue on sdi_private.support_requests(status,created_at,id);
create function sdi_private.support_action(action text,request uuid default null,category text default null,platform text default null,
 app_version text default '',subject text default null,body text default null,idempotency uuid default null,status text default null,
 note text default '',page integer default 0,revision bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); existing sdi_private.support_requests; items jsonb; denial jsonb; code text;
begin
 if action in('create','list_mine','withdraw','delete') then
  if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
   return jsonb_build_object('error','Sign in with a full account to contact support.'); end if;
  if action='create' then
   if idempotency is null or category is null or category not in('account','billing','studio','publishing','rights','safety','bug','other')
    or platform is null or platform not in('ios','android','web','other') or app_version is null or length(app_version)>50
    or subject is null or length(trim(subject)) not between 1 and 120 or body is null or length(trim(body)) not between 1 and 2000 then
    return jsonb_build_object('error','Choose a category and platform, then describe the issue in up to 2000 characters.'); end if;
   select * into existing from sdi_private.support_requests s where s.user_id=actor and s.idempotency_key=idempotency;
   if found then return jsonb_build_object('status','duplicate','request_id',existing.id,'receipt',existing.receipt,'request_status',existing.status); end if;
   if (select count(*) from sdi_private.support_requests s where s.user_id=actor and s.created_at>clock_timestamp()-interval '1 day')>=5 then
    return jsonb_build_object('error','Daily support request limit reached. Existing requests remain open.'); end if;
   code:='SDI-'||upper(left(translate(encode(extensions.gen_random_bytes(8),'base64'),'+/=01IO','ABCDEFG'),10));
   insert into sdi_private.support_requests(user_id,category,platform,app_version,subject,body,receipt,idempotency_key,retention_until)
   values(actor,category,platform,app_version,trim(subject),trim(body),code,idempotency,clock_timestamp()+interval '180 days') returning * into existing;
   insert into sdi_private.support_audit(request_id,actor,action,previous_status) values(existing.id,actor,'create','open');
   return jsonb_build_object('status','created','request_id',existing.id,'receipt',existing.receipt,'request_status','open');
  elsif action='list_mine' then
   select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
    select s.id,s.receipt,s.category,s.platform,s.app_version,s.subject,s.body,s.status,s.revision,s.created_at,s.updated_at
    from sdi_private.support_requests s where s.user_id=actor and s.status<>'deleted' order by s.created_at desc,s.id limit 50) item;
   return jsonb_build_object('requests',items);
  end if;
  select * into existing from sdi_private.support_requests s where s.id=request and s.user_id=actor for update;
  if not found or existing.status='deleted' then return jsonb_build_object('error','Request unavailable.'); end if;
  if action='withdraw' then
   if existing.status not in('open','in_progress','waiting_on_member') then return jsonb_build_object('error','This request is already closed.'); end if;
   update sdi_private.support_requests set status='withdrawn',revision=revision+1,updated_at=clock_timestamp(),retention_until=clock_timestamp()+interval '30 days' where id=existing.id;
  else
   -- Member deletion scrubs content immediately; the stub row keeps the daily
   -- rate accounting and receipt until its short retention passes.
   update sdi_private.support_requests set status='deleted',subject='[deleted by member]',body='[deleted by member]',app_version='',admin_note='',
    revision=revision+1,updated_at=clock_timestamp(),retention_until=clock_timestamp()+interval '30 days' where id=existing.id;
  end if;
  insert into sdi_private.support_audit(request_id,actor,action,previous_status) values(existing.id,actor,action,existing.status);
  return jsonb_build_object('status','confirmed');
 end if;
 denial:=sdi_private.admin_gate('support_action.'||coalesce(action,'?'),'users',false,120);
 if denial is not null then return denial; end if;
 if action='list' then
  if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid page.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select s.id,s.user_id,s.receipt,s.category,s.platform,s.app_version,s.subject,s.body,s.status,s.admin_note,s.revision,s.created_at,s.updated_at
   from sdi_private.support_requests s where s.status<>'deleted' and (support_action.status is null or s.status=support_action.status)
   order by case s.status when 'open' then 0 when 'waiting_on_member' then 1 when 'in_progress' then 2 else 3 end,s.created_at,s.id limit 50 offset page*50) item;
  return jsonb_build_object('requests',items,'has_more',jsonb_array_length(items)=50);
 elsif action='update_status' then
  if request is null or revision is null or status is null or status not in('open','in_progress','waiting_on_member','resolved')
   or note is null or length(trim(note)) not between 1 and 2000 then return jsonb_build_object('error','Select a request, new status and note.'); end if;
  select * into existing from sdi_private.support_requests s where s.id=request for update;
  if not found or existing.status in('deleted','withdrawn') or existing.revision<>revision then return jsonb_build_object('error','Request changed or closed. Refresh the queue.'); end if;
  update sdi_private.support_requests set status=support_action.status,admin_note=trim(note),revision=revision+1,updated_at=clock_timestamp(),
   retention_until=case when support_action.status='resolved' then clock_timestamp()+interval '90 days' else retention_until end where id=existing.id;
  insert into sdi_private.support_audit(request_id,actor,action,previous_status,note) values(existing.id,actor,'status:'||status,existing.status,trim(note));
  insert into sdi_private.admin_access_audit(actor,operation,allowed,detail) values(actor,'support_action.update_status',true,existing.receipt);
  return jsonb_build_object('status','confirmed','revision',existing.revision+1);
 end if;
 return jsonb_build_object('error','Unsupported support operation.');
end $$;
revoke all on function sdi_private.support_action(text,uuid,text,text,text,text,text,uuid,text,text,integer,bigint) from public,anon;
grant execute on function sdi_private.support_action(text,uuid,text,text,text,text,text,uuid,text,text,integer,bigint) to authenticated;
create function public.sdi_support_action(action text,request uuid default null,category text default null,platform text default null,
 app_version text default '',subject text default null,body text default null,idempotency uuid default null,status text default null,
 note text default '',page integer default 0,revision bigint default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.support_action(action,request,category,platform,app_version,subject,body,idempotency,status,note,page,revision)$$;
revoke all on function public.sdi_support_action(text,uuid,text,text,text,text,text,uuid,text,text,integer,bigint) from public,anon;
grant execute on function public.sdi_support_action(text,uuid,text,text,text,text,text,uuid,text,text,integer,bigint) to authenticated;
-- Retention sweep for the service scheduler: hard-delete expired rows.
create function sdi_private.support_retention() returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 delete from sdi_private.support_requests where retention_until<=clock_timestamp() and status in('resolved','withdrawn','deleted');
 get diagnostics n=row_count; return n;
end $$;
revoke all on function sdi_private.support_retention() from public,anon,authenticated;
grant execute on function sdi_private.support_retention() to service_role;
create function public.sdi_support_retention() returns integer language sql security invoker set search_path='' as $$select sdi_private.support_retention()$$;
revoke all on function public.sdi_support_retention() from public,anon,authenticated;
grant execute on function public.sdi_support_retention() to service_role;
commit;
