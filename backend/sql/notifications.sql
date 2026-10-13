-- Unapplied candidate. Install after consent-versions.sql (needs admin-hardening.sql,
-- billing.sql for the subscriber audience and pgcrypto in extensions).
-- Notification preferences, device registrations, admin-composed announcements and
-- email suppression for #290 and #276. Transactional (account/service) notices are
-- always allowed; product and marketing notices are off until the member opts in,
-- with a per-member daily cap. Administrators with the users capability compose,
-- schedule and cancel; the service fans out deliveries and reports results. No push
-- or email transport lives here: the service worker takes the claimed batch to the
-- configured APNs/FCM/SMTP adapter, and during development to a sink only.
begin;
create table sdi_private.notification_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 push_product boolean not null default false, push_marketing boolean not null default false,
 email_product boolean not null default false, email_marketing boolean not null default false,
 daily_cap integer not null default 2 check(daily_cap between 0 and 10), updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.device_tokens (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 platform text not null check(platform in('ios','android')), environment text not null check(environment in('sandbox','production')),
 device_token text not null check(length(device_token) between 32 and 4096), created_at timestamptz not null default clock_timestamp(),
 last_seen_at timestamptz not null default clock_timestamp(), revoked_at timestamptz, unique(device_token)
);
create table sdi_private.announcements (
 id uuid primary key default gen_random_uuid(), title text not null check(length(title) between 1 and 120), body text not null check(length(body) between 1 and 1000),
 category text not null check(category in('transactional','product','marketing')), audience text not null check(audience in('all','subscribers')),
 channels text[] not null check(channels<>'{}' and channels <@ array['push','in_app']), scheduled_for timestamptz,
 state text not null default 'draft' check(state in('draft','scheduled','sending','sent','cancelled')),
 created_by uuid not null references auth.users(id), revision bigint not null default 1,
 queued_count integer not null default 0, sent_count integer not null default 0, failed_count integer not null default 0, suppressed_count integer not null default 0,
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.announcement_deliveries (
 id uuid primary key default gen_random_uuid(), announcement_id uuid not null references sdi_private.announcements(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade, channel text not null check(channel in('push','in_app')),
 device_id uuid references sdi_private.device_tokens(id) on delete set null,
 state text not null default 'queued' check(state in('queued','sent','failed','suppressed','read')), reason text not null default '' check(length(reason)<=200),
 claimed_at timestamptz, created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 unique nulls not distinct (announcement_id,user_id,channel,device_id)
);
create table sdi_private.announcement_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id), announcement_id uuid, action text not null,
 reason text not null check(length(reason) between 1 and 2000), created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.email_suppressions (
 email_hash text primary key check(email_hash ~ '^[a-f0-9]{64}$'), reason text not null check(reason in('unsubscribe','bounce','complaint','manual')),
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.notification_preferences enable row level security;
alter table sdi_private.device_tokens enable row level security;
alter table sdi_private.announcements enable row level security;
alter table sdi_private.announcement_deliveries enable row level security;
alter table sdi_private.announcement_audit enable row level security;
alter table sdi_private.email_suppressions enable row level security;
revoke all on sdi_private.notification_preferences,sdi_private.device_tokens,sdi_private.announcements,sdi_private.announcement_deliveries,
 sdi_private.announcement_audit,sdi_private.email_suppressions from public,anon,authenticated;
create index announcement_deliveries_user on sdi_private.announcement_deliveries(user_id,channel,created_at desc);
create index announcement_deliveries_claim on sdi_private.announcement_deliveries(announcement_id,state) where state='queued';

create function sdi_private.email_hash(address text) returns text language sql immutable security definer set search_path='' as $$
 select encode(extensions.digest(lower(trim(address)),'sha256'),'hex')
$$;
revoke all on function sdi_private.email_hash(text) from public,anon,authenticated;

-- Member surface: preferences, devices, in-app inbox.
create function sdi_private.notify_action(action text,payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); prefs sdi_private.notification_preferences; items jsonb; device uuid;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 if payload is null or jsonb_typeof(payload)<>'object' then return jsonb_build_object('error','Invalid request.'); end if;
 insert into sdi_private.notification_preferences(user_id) values(actor) on conflict do nothing;
 select * into prefs from sdi_private.notification_preferences where user_id=actor;
 if action='preferences' then
  select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'platform',d.platform,'environment',d.environment,'created_at',d.created_at,'last_seen_at',d.last_seen_at) order by d.created_at),'[]'::jsonb)
   into items from sdi_private.device_tokens d where d.user_id=actor and d.revoked_at is null;
  return jsonb_build_object('push_product',prefs.push_product,'push_marketing',prefs.push_marketing,'email_product',prefs.email_product,'email_marketing',prefs.email_marketing,
   'daily_cap',prefs.daily_cap,'transactional','always on for account and service notices','devices',items);
 elsif action='set_preferences' then
  if (payload ? 'daily_cap') and (payload->>'daily_cap') !~ '^(10|[0-9])$' then return jsonb_build_object('error','Daily cap must be 0 to 10.'); end if;
  update sdi_private.notification_preferences set
   push_product=coalesce((payload->>'push_product')::boolean,push_product),push_marketing=coalesce((payload->>'push_marketing')::boolean,push_marketing),
   email_product=coalesce((payload->>'email_product')::boolean,email_product),email_marketing=coalesce((payload->>'email_marketing')::boolean,email_marketing),
   daily_cap=coalesce((payload->>'daily_cap')::integer,daily_cap),updated_at=clock_timestamp() where user_id=actor;
  return jsonb_build_object('status','confirmed');
 elsif action='register_device' then
  if coalesce(payload->>'platform','') not in('ios','android') or coalesce(payload->>'environment','') not in('sandbox','production')
   or length(coalesce(payload->>'token','')) not between 32 and 4096 then return jsonb_build_object('error','Platform, environment and device token required.'); end if;
  if (select count(*) from sdi_private.device_tokens d where d.user_id=actor and d.revoked_at is null and d.device_token<>payload->>'token')>=5 then
   return jsonb_build_object('error','Five devices are already registered. Remove one first.'); end if;
  insert into sdi_private.device_tokens(user_id,platform,environment,device_token) values(actor,payload->>'platform',payload->>'environment',payload->>'token')
  on conflict(device_token) do update set user_id=excluded.user_id,platform=excluded.platform,environment=excluded.environment,last_seen_at=clock_timestamp(),revoked_at=null
  returning id into device;
  return jsonb_build_object('status','confirmed','device',device);
 elsif action='revoke_device' then
  update sdi_private.device_tokens set revoked_at=clock_timestamp() where id=(payload->>'device')::uuid and user_id=actor and revoked_at is null;
  if not found then return jsonb_build_object('error','Device unavailable.'); end if;
  return jsonb_build_object('status','confirmed');
 elsif action='inbox' then
  select coalesce(jsonb_agg(jsonb_build_object('delivery',d.id,'title',a.title,'body',a.body,'category',a.category,'state',d.state,'delivered_at',d.updated_at) order by d.updated_at desc),'[]'::jsonb)
   into items from sdi_private.announcement_deliveries d join sdi_private.announcements a on a.id=d.announcement_id
   where d.user_id=actor and d.channel='in_app' and d.state in('sent','read') and a.state<>'cancelled' limit 50;
  return jsonb_build_object('notices',items,'unread',(select count(*) from sdi_private.announcement_deliveries d where d.user_id=actor and d.channel='in_app' and d.state='sent'));
 elsif action='mark_read' then
  update sdi_private.announcement_deliveries set state='read',updated_at=clock_timestamp() where id=(payload->>'delivery')::uuid and user_id=actor and channel='in_app' and state='sent';
  return jsonb_build_object('status',case when found then 'confirmed' else 'unchanged' end);
 end if;
 return jsonb_build_object('error','Unsupported notification operation.');
exception when invalid_text_representation then
 return jsonb_build_object('error','Invalid request.');
end $$;
revoke all on function sdi_private.notify_action(text,jsonb) from public,anon;
grant execute on function sdi_private.notify_action(text,jsonb) to authenticated;
create function public.sdi_notify_action(action text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.notify_action(action,payload)$$;
revoke all on function public.sdi_notify_action(text,jsonb) from public,anon;
grant execute on function public.sdi_notify_action(text,jsonb) to authenticated;

-- Administrator surface: compose, schedule, cancel, results. Scheduling and
-- cancelling are sensitive (step-up); every change is audited with a reason.
create function sdi_private.announce_admin(action text,announcement uuid default null,revision bigint default null,payload jsonb default '{}',reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare denial jsonb; a sdi_private.announcements; items jsonb; channel_list text[]; when_at timestamptz;
begin
 denial:=sdi_private.admin_gate('announce_admin.'||coalesce(action,'?'),'users',action in('schedule','cancel'),60);
 if denial is not null then return denial; end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc),'[]'::jsonb) into items from (select * from sdi_private.announcements order by created_at desc limit 100) x;
  return jsonb_build_object('announcements',items);
 elsif action='results' then
  select coalesce(jsonb_agg(jsonb_build_object('state',t.state,'channel',t.channel,'count',t.n,'reasons',t.reasons)),'[]'::jsonb) into items from (
   select d.state,d.channel,count(*) as n,jsonb_agg(distinct d.reason) filter(where d.reason<>'') as reasons from sdi_private.announcement_deliveries d where d.announcement_id=announcement group by d.state,d.channel) t;
  return jsonb_build_object('results',items);
 end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
 if action='compose' then
  select coalesce(array_agg(v order by v),'{}') into channel_list from jsonb_array_elements_text(coalesce(payload->'channels','[]'::jsonb)) v;
  if length(coalesce(payload->>'title','')) not between 1 and 120 or length(coalesce(payload->>'body','')) not between 1 and 1000
   or coalesce(payload->>'category','') not in('transactional','product','marketing') or coalesce(payload->>'audience','') not in('all','subscribers')
   or channel_list='{}' or not channel_list <@ array['push','in_app'] then
   return jsonb_build_object('error','Title (120), body (1000), category, audience and channels required.'); end if;
  insert into sdi_private.announcements(title,body,category,audience,channels,created_by) values(payload->>'title',payload->>'body',payload->>'category',payload->>'audience',channel_list,auth.uid()) returning * into a;
  insert into sdi_private.announcement_audit(actor,announcement_id,action,reason) values(auth.uid(),a.id,'compose',trim(reason));
  return jsonb_build_object('status','draft','announcement',a.id,'revision',a.revision);
 end if;
 select * into a from sdi_private.announcements where id=announcement for update;
 if not found or revision is distinct from a.revision then return jsonb_build_object('error','Announcement changed. Refresh before saving.'); end if;
 if action='schedule' then
  if a.state<>'draft' then return jsonb_build_object('error','Only drafts can be scheduled.'); end if;
  when_at:=coalesce((payload->>'scheduled_for')::timestamptz,clock_timestamp());
  if when_at<clock_timestamp()-interval '1 minute' or when_at>clock_timestamp()+interval '90 days' then return jsonb_build_object('error','Schedule within the next 90 days.'); end if;
  update sdi_private.announcements set state='scheduled',scheduled_for=when_at,revision=revision+1,updated_at=clock_timestamp() where id=a.id;
 elsif action='cancel' then
  if a.state not in('scheduled','sending') then return jsonb_build_object('error','Only scheduled or sending announcements can be cancelled.'); end if;
  update sdi_private.announcements set state='cancelled',revision=revision+1,updated_at=clock_timestamp() where id=a.id;
  update sdi_private.announcement_deliveries set state='suppressed',reason='cancelled',updated_at=clock_timestamp() where announcement_id=a.id and state='queued';
 else return jsonb_build_object('error','Unsupported announcement operation.'); end if;
 insert into sdi_private.announcement_audit(actor,announcement_id,action,reason) values(auth.uid(),a.id,action,trim(reason));
 return jsonb_build_object('status','confirmed','revision',a.revision+1);
exception when invalid_datetime_format or datetime_field_overflow then
 return jsonb_build_object('error','Invalid schedule time.');
end $$;
revoke all on function sdi_private.announce_admin(text,uuid,bigint,jsonb,text) from public,anon;
grant execute on function sdi_private.announce_admin(text,uuid,bigint,jsonb,text) to authenticated;
create function public.sdi_announce_admin(action text,announcement uuid default null,revision bigint default null,payload jsonb default '{}',reason text default '')
returns jsonb language sql security invoker set search_path='' as $$select sdi_private.announce_admin(action,announcement,revision,payload,reason)$$;
revoke all on function public.sdi_announce_admin(text,uuid,bigint,jsonb,text) from public,anon;
grant execute on function public.sdi_announce_admin(text,uuid,bigint,jsonb,text) to authenticated;

-- Service: fan out one due announcement (idempotent) and hand the worker a bounded
-- batch of push deliveries. Preference, audience, account state and daily cap are
-- applied here; the worker only transports.
-- Recipients: full, active accounts; subscribers only when the audience says so.
create function sdi_private.announcement_audience(audience text) returns table(user_id uuid) language sql stable security definer set search_path='' as $$
 select u.id from auth.users u where not u.is_anonymous
 and not exists(select 1 from sdi_private.account_controls c where c.user_id=u.id and c.state<>'active')
 and (audience='all' or exists(select 1 from sdi_private.entitlements e where e.user_id=u.id))
$$;
revoke all on function sdi_private.announcement_audience(text) from public,anon,authenticated;
create function sdi_private.announcement_claim(batch integer default 500) returns jsonb language plpgsql security definer set search_path='' as $$
declare a sdi_private.announcements; items jsonb; n integer;
begin
 if batch is null or batch not between 1 and 1000 then return jsonb_build_object('error','Batch must be 1 to 1000.'); end if;
 select * into a from sdi_private.announcements where state='sending' order by updated_at for update skip locked limit 1;
 if not found then
  select * into a from sdi_private.announcements where state='scheduled' and scheduled_for<=clock_timestamp() order by scheduled_for for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true); end if;
  update sdi_private.announcements set state='sending',updated_at=clock_timestamp() where id=a.id;
  if 'in_app'=any(a.channels) then
   insert into sdi_private.announcement_deliveries(announcement_id,user_id,channel,state,updated_at)
   select a.id,r.user_id,'in_app','sent',clock_timestamp() from sdi_private.announcement_audience(a.audience) r on conflict do nothing;
  end if;
  if 'push'=any(a.channels) then
   insert into sdi_private.announcement_deliveries(announcement_id,user_id,channel,device_id,state,reason)
   select a.id,r.user_id,'push',d.id,
    case when a.category='product' and not coalesce(p.push_product,false) then 'suppressed'
         when a.category='marketing' and not coalesce(p.push_marketing,false) then 'suppressed'
         when a.category<>'transactional' and (select count(*) from sdi_private.announcement_deliveries x where x.user_id=r.user_id and x.channel='push' and x.state='sent' and x.created_at>=date_trunc('day',clock_timestamp()))>=coalesce(p.daily_cap,2) then 'suppressed'
         else 'queued' end,
    case when a.category='product' and not coalesce(p.push_product,false) then 'product notices off'
         when a.category='marketing' and not coalesce(p.push_marketing,false) then 'marketing notices off'
         when a.category<>'transactional' and (select count(*) from sdi_private.announcement_deliveries x where x.user_id=r.user_id and x.channel='push' and x.state='sent' and x.created_at>=date_trunc('day',clock_timestamp()))>=coalesce(p.daily_cap,2) then 'daily cap'
         else '' end
   from sdi_private.announcement_audience(a.audience) r join sdi_private.device_tokens d on d.user_id=r.user_id and d.revoked_at is null
   left join sdi_private.notification_preferences p on p.user_id=r.user_id on conflict do nothing;
  end if;
  update sdi_private.announcements set queued_count=(select count(*) from sdi_private.announcement_deliveries x where x.announcement_id=a.id and x.state='queued'),
   suppressed_count=(select count(*) from sdi_private.announcement_deliveries x where x.announcement_id=a.id and x.state='suppressed'),updated_at=clock_timestamp() where id=a.id;
 end if;
 with picked as (
  select d.id from sdi_private.announcement_deliveries d where d.announcement_id=a.id and d.channel='push' and d.state='queued'
  and (d.claimed_at is null or d.claimed_at<clock_timestamp()-interval '10 minutes') order by d.created_at limit batch for update skip locked),
 marked as (update sdi_private.announcement_deliveries d set claimed_at=clock_timestamp() from picked where d.id=picked.id returning d.id,d.device_id)
 select coalesce(jsonb_agg(jsonb_build_object('delivery',m.id,'platform',t.platform,'environment',t.environment,'token',t.device_token,'title',a.title,'body',a.body,'category',a.category)),'[]'::jsonb),count(*)
  into items,n from marked m join sdi_private.device_tokens t on t.id=m.device_id;
 if n=0 and not exists(select 1 from sdi_private.announcement_deliveries d where d.announcement_id=a.id and d.state='queued') then
  update sdi_private.announcements set state='sent',sent_count=(select count(*) from sdi_private.announcement_deliveries x where x.announcement_id=a.id and x.state in('sent','read')),
   failed_count=(select count(*) from sdi_private.announcement_deliveries x where x.announcement_id=a.id and x.state='failed'),updated_at=clock_timestamp() where id=a.id;
  return jsonb_build_object('announcement',a.id,'deliveries',items,'complete',true);
 end if;
 return jsonb_build_object('announcement',a.id,'deliveries',items,'complete',false);
end $$;
create function sdi_private.announcement_finish(results jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; ok integer:=0; failed integer:=0;
begin
 if results is null or jsonb_typeof(results)<>'array' or jsonb_array_length(results)>1000 then return jsonb_build_object('error','Results must be an array of at most 1000 items.'); end if;
 for item in select * from jsonb_array_elements(results) loop
  if (item->>'ok')::boolean then
   update sdi_private.announcement_deliveries set state='sent',updated_at=clock_timestamp() where id=(item->>'delivery')::uuid and state='queued';
   if found then ok:=ok+1; end if;
  else
   update sdi_private.announcement_deliveries set state='failed',reason=left(coalesce(item->>'reason',''),200),updated_at=clock_timestamp() where id=(item->>'delivery')::uuid and state='queued';
   if found then failed:=failed+1; end if;
   if item->>'reason' in('unregistered','invalid_token','BadDeviceToken','Unregistered') then
    update sdi_private.device_tokens t set revoked_at=clock_timestamp() from sdi_private.announcement_deliveries d where d.id=(item->>'delivery')::uuid and t.id=d.device_id;
   end if;
  end if;
 end loop;
 return jsonb_build_object('sent',ok,'failed',failed);
exception when invalid_text_representation then
 return jsonb_build_object('error','Malformed results.');
end $$;
-- Email: suppression by hash (unsubscribe, bounce, complaint) and the allowed
-- recipients for one category. Unsubscribe blocks product and marketing only;
-- bounce and complaint block every category. Service role only; the worker holds
-- the addresses transiently and never logs them.
create function sdi_private.email_suppress(address_hash text,reason text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if address_hash is null or address_hash !~ '^[a-f0-9]{64}$' or reason not in('unsubscribe','bounce','complaint','manual') then return false; end if;
 insert into sdi_private.email_suppressions(email_hash,reason) values(address_hash,reason)
 on conflict(email_hash) do update set reason=case when email_suppressions.reason in('bounce','complaint') then email_suppressions.reason else excluded.reason end;
 return true;
end $$;
create function sdi_private.email_recipients(category text,batch integer default 500,page integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if category not in('transactional','product','marketing') or batch not between 1 and 1000 or page not between 0 and 999 then return jsonb_build_object('error','Category, batch and page required.'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'email',u.email,'email_hash',sdi_private.email_hash(u.email))),'[]'::jsonb) into items from (
  select u.id,u.email from auth.users u left join sdi_private.notification_preferences p on p.user_id=u.id
  where not u.is_anonymous and u.email is not null and u.email_confirmed_at is not null
  and not exists(select 1 from sdi_private.account_controls c where c.user_id=u.id and c.state<>'active')
  and not exists(select 1 from sdi_private.email_suppressions s where s.email_hash=sdi_private.email_hash(u.email) and (s.reason in('bounce','complaint') or category<>'transactional'))
  and (category='transactional' or (category='product' and coalesce(p.email_product,false)) or (category='marketing' and coalesce(p.email_marketing,false)))
  order by u.created_at,u.id limit batch offset page*batch) u;
 return jsonb_build_object('category',category,'recipients',items,'has_more',jsonb_array_length(items)=batch);
end $$;
revoke all on function sdi_private.announcement_claim(integer),sdi_private.announcement_finish(jsonb),sdi_private.email_suppress(text,text),sdi_private.email_recipients(text,integer,integer) from public,anon,authenticated;
grant execute on function sdi_private.announcement_claim(integer),sdi_private.announcement_finish(jsonb),sdi_private.email_suppress(text,text),sdi_private.email_recipients(text,integer,integer) to service_role;
create function public.sdi_announcement_claim(batch integer default 500) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.announcement_claim(batch)$$;
create function public.sdi_announcement_finish(results jsonb) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.announcement_finish(results)$$;
create function public.sdi_email_suppress(address_hash text,reason text) returns boolean language sql security invoker set search_path='' as $$select sdi_private.email_suppress(address_hash,reason)$$;
create function public.sdi_email_recipients(category text,batch integer default 500,page integer default 0) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.email_recipients(category,batch,page)$$;
revoke all on function public.sdi_announcement_claim(integer),public.sdi_announcement_finish(jsonb),public.sdi_email_suppress(text,text),public.sdi_email_recipients(text,integer,integer) from public,anon,authenticated;
grant execute on function public.sdi_announcement_claim(integer),public.sdi_announcement_finish(jsonb),public.sdi_email_suppress(text,text),public.sdi_email_recipients(text,integer,integer) to service_role;
commit;
