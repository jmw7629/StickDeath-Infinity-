-- Unapplied candidate. Install after publishing-jobs.sql.
begin;
alter table sdi_private.publish_jobs add column removal_attempts integer not null default 0;
create function sdi_private.withdraw_invalidated_render() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update sdi_private.publish_jobs j set state=case
  when j.state in('leased','cancel_requested') then 'cancel_requested'
  when j.provider_id is not null then 'removal_pending'
  when j.state='reconcile' then 'reconcile' else 'cancelled' end,
  last_error='Render approval, rights or destination consent changed.',updated_at=clock_timestamp()
 where j.review_id=new.id and j.state not in('cancelled','removal_pending')
 and not (new.state='approved' and new.rights_cleared
  and length(new.consent_version)>0 and j.review_version=new.version
  and j.render_digest=new.render_digest and j.destination=any(new.destinations));
 return new;
end $$;
revoke all on function sdi_private.withdraw_invalidated_render() from public,anon,authenticated;
create trigger withdraw_invalidated_render after update on sdi_private.render_reviews
for each row execute function sdi_private.withdraw_invalidated_render();
create function sdi_private.publish_removal_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs;
begin
 -- Leave a grace interval beyond the last release lease so an in-flight provider
 -- request cannot immediately follow withdrawal with a late public promotion.
 update sdi_private.publish_jobs set state='removal_pending',updated_at=clock_timestamp()
 where state='cancel_requested' and provider_id is not null
 and lease_expires<clock_timestamp()-interval '60 seconds';
 select * into j from sdi_private.publish_jobs
 where state='removal_pending' and destination='youtube'
 and provider_id ~ '^[A-Za-z0-9_-]{11}$' and removal_attempts<5
 and next_attempt<=clock_timestamp()
 and (lease_expires is null or lease_expires<clock_timestamp()-interval '60 seconds')
 order by updated_at for update skip locked limit 1;
 if not found then return jsonb_build_object('empty',true);end if;
 update sdi_private.publish_jobs set lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',
 removal_attempts=removal_attempts+1,updated_at=clock_timestamp()
 where id=j.id returning * into j;
 return jsonb_build_object('job',j.id,'lease',j.lease,'digest',j.render_digest,'provider',j.provider_id);
end $$;
create function sdi_private.publish_removal_renew(job uuid,token uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 update sdi_private.publish_jobs set lease_expires=clock_timestamp()+interval '2 minutes'
 where id=job and lease=token and state='removal_pending' and lease_expires>clock_timestamp();
 return found;
end $$;
create function sdi_private.publish_removal_finish(job uuid,token uuid,provider text,confirmed boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs;
begin
 select * into j from sdi_private.publish_jobs where id=job and lease=token and state='removal_pending'
 and lease_expires>clock_timestamp() for update;
 if not found or confirmed is null or provider is distinct from j.provider_id then return false;end if;
 update sdi_private.publish_jobs set state=case when confirmed then 'cancelled' else 'removal_pending' end,
 result_url=case when confirmed then null else result_url end,
 last_error=case when confirmed then 'Channel video confirmed private; originals preserved.'
  when removal_attempts>=5 then 'Withdrawal needs administrator reconciliation.'
  else 'Withdrawal not confirmed; bounded retry pending.' end,
 next_attempt=clock_timestamp()+make_interval(secs=>least(3600,60*power(2,removal_attempts)::integer)),
 lease=null,lease_expires=null,updated_at=clock_timestamp() where id=j.id;
 return true;
end $$;
revoke all on function sdi_private.publish_removal_claim(),sdi_private.publish_removal_renew(uuid,uuid),sdi_private.publish_removal_finish(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function sdi_private.publish_removal_claim(),sdi_private.publish_removal_renew(uuid,uuid),sdi_private.publish_removal_finish(uuid,uuid,text,boolean) to service_role;
create function public.sdi_publish_removal_claim() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.publish_removal_claim()$$;
create function public.sdi_publish_removal_renew(job uuid,token uuid) returns boolean language sql security invoker set search_path='' as $$select sdi_private.publish_removal_renew(job,token)$$;
create function public.sdi_publish_removal_finish(job uuid,token uuid,provider text,confirmed boolean) returns boolean language sql security invoker set search_path='' as $$select sdi_private.publish_removal_finish(job,token,provider,confirmed)$$;
revoke all on function public.sdi_publish_removal_claim(),public.sdi_publish_removal_renew(uuid,uuid),public.sdi_publish_removal_finish(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.sdi_publish_removal_claim(),public.sdi_publish_removal_renew(uuid,uuid),public.sdi_publish_removal_finish(uuid,uuid,text,boolean) to service_role;
commit;
