-- Unapplied candidate. Requires war-room.sql. Invoke with a server scheduler;
-- no scheduler is installed by this source file.
begin;
create function sdi_private.war_finalize() returns jsonb
language plpgsql security definer set search_path='' as $$
declare m sdi_private.war_matches; left_count bigint; right_count bigint; completed integer:=0; removed integer:=0;
begin
 -- Same match lock as the vote endpoint serializes the terminal snapshot.
 for m in select * from sdi_private.war_matches where status='active' and ends_at<=clock_timestamp()
  order by ends_at,id for update skip locked limit 100 loop
  if (select count(*) from public.sdi_watch_media where approved
   and (expires_at is null or expires_at>=m.ends_at)
   and ((id=m.left_media and render_digest=m.left_digest) or (id=m.right_media and render_digest=m.right_digest)))<>2 then
   update sdi_private.war_matches set status='removed' where id=m.id;
   removed:=removed+1;continue;
  end if;
  select count(*) filter(where choice='left'),count(*) filter(where choice='right')
   into left_count,right_count from sdi_private.war_votes where match_id=m.id;
  insert into sdi_private.war_results(match_id,left_votes,right_votes,outcome,left_digest,right_digest)
   values(m.id,left_count,right_count,case when left_count=right_count then 'tie' when left_count>right_count then 'left' else 'right' end,m.left_digest,m.right_digest)
   on conflict(match_id) do nothing;
  update sdi_private.war_matches set status='completed' where id=m.id;
  completed:=completed+1;
 end loop;
 return jsonb_build_object('completed',completed,'removed',removed);
end $$;
revoke all on function sdi_private.war_finalize() from public,anon,authenticated;
grant execute on function sdi_private.war_finalize() to service_role;
create function public.sdi_war_finalize() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.war_finalize()$$;
revoke all on function public.sdi_war_finalize() from public,anon,authenticated;
grant execute on function public.sdi_war_finalize() to service_role;
commit;
