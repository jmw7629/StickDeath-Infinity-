-- Unapplied candidate. Install after publishing-withdrawal.sql.
begin;
alter table sdi_private.publish_jobs add column revision bigint not null default 1;
create function sdi_private.publish_job_revision() returns trigger language plpgsql set search_path='' as $$
begin new.revision=old.revision+1;return new;end $$;
revoke all on function sdi_private.publish_job_revision() from public;
create trigger publish_job_revision before update on sdi_private.publish_jobs
for each row execute function sdi_private.publish_job_revision();
create table sdi_private.publishing_audit (
 id uuid primary key default gen_random_uuid(), job_id uuid not null references sdi_private.publish_jobs(id),
 actor uuid not null references auth.users(id), action text not null, previous_state text not null,
 job_revision bigint not null, reason text not null check(length(reason) between 1 and 2000),
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.publishing_audit enable row level security;
revoke all on sdi_private.publishing_audit from public,anon,authenticated;
create function sdi_private.publishing_admin(action text,job uuid default null,revision bigint default null,
 reason text default '',page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; items jsonb; history jsonb;
begin
 if not sdi_private.admin_can('publishing') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current administrator MFA session required.');end if;
 if action='list' then
  if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid page.');end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select p.id,r.title,p.destination,p.state,p.phase,p.revision,p.attempts,p.removal_attempts,
   p.render_digest,p.provider_id,p.result_url,p.last_error,p.updated_at
   from sdi_private.publish_jobs p join sdi_private.render_reviews r on r.id=p.review_id
   order by p.created_at desc,p.id limit 50 offset page*50
  ) item;
  return jsonb_build_object('jobs',items);
 end if;
 if action='history' and job is not null then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into history from (
   select id,actor,publishing_audit.action,previous_state,job_revision,publishing_audit.reason,created_at
   from sdi_private.publishing_audit where job_id=job order by created_at desc,id limit 100
  ) item;
  return jsonb_build_object('history',history);
 end if;
 if action is null or action not in('withdraw','retry_withdrawal') or job is null or revision is null
 or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','Select a current job and provide a reason.');end if;
 select * into j from sdi_private.publish_jobs where id=job for update;
 if not found or j.revision<>revision then return jsonb_build_object('error','Job changed. Refresh before acting.');end if;
 if j.destination<>'youtube' then return jsonb_build_object('error','This destination requires its own removal adapter.');end if;
 if (select count(*) from sdi_private.publishing_audit where actor=auth.uid() and created_at>clock_timestamp()-interval '1 minute')>=20 then
  return jsonb_build_object('error','Please wait before another publishing action.');end if;
 if action='retry_withdrawal' then
  if j.state<>'removal_pending' or j.provider_id is null or (j.lease_expires is not null and j.lease_expires>=clock_timestamp()-interval '60 seconds') then
   return jsonb_build_object('error','Withdrawal cannot be retried while a worker may be active.');end if;
  update sdi_private.publish_jobs set removal_attempts=0,next_attempt=clock_timestamp(),lease=null,lease_expires=null,
   last_error='Administrator requested withdrawal retry.',updated_at=clock_timestamp() where id=j.id;
 else
  if j.state='cancelled' then return jsonb_build_object('error','Job already cancelled.');end if;
  update sdi_private.publish_jobs set state=case when state in('leased','cancel_requested') then 'cancel_requested'
   when provider_id is not null then 'removal_pending' when state='reconcile' then 'reconcile' else 'cancelled' end,
   last_error='Administrator requested cancellation or withdrawal.',updated_at=clock_timestamp() where id=j.id;
 end if;
 insert into sdi_private.publishing_audit(job_id,actor,action,previous_state,job_revision,reason)
 values(j.id,auth.uid(),action,j.state,j.revision,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.publishing_admin(text,uuid,bigint,text,integer) from public,anon;
grant execute on function sdi_private.publishing_admin(text,uuid,bigint,text,integer) to authenticated;
create function public.sdi_publishing_admin(action text,job uuid default null,revision bigint default null,
 reason text default '',page integer default 0) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.publishing_admin(action,job,revision,reason,page)$$;
revoke all on function public.sdi_publishing_admin(text,uuid,bigint,text,integer) from public,anon;
grant execute on function public.sdi_publishing_admin(text,uuid,bigint,text,integer) to authenticated;
commit;
