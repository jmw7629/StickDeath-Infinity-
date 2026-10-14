-- Unapplied candidate (#260). Install after rate-limits.sql. User-to-user messaging,
-- text chat and voice/video calling are retired scope. None of the SQL candidates in
-- this directory create such objects; this file closes any legacy ones a live
-- project may still hold from the earlier app (for example chat rooms, messages or
-- call records) without deleting data blindly: client roles lose every privilege on
-- matching public tables, views and functions, and matching tables leave the
-- realtime publication. Rows are kept for the owner's documented retention decision.
-- Names under sdi_* or containing spatter (the Studio assistant), including Watch
-- Together's approved no-chat playback objects, are never touched. The report lists
-- exactly what was closed; an empty list on a fresh project is the expected result.
begin;
create function sdi_private.legacy_communication_name(name text) returns boolean language sql immutable set search_path='' as $$
 select name !~ '^sdi_' and name !~ 'spatter' and name ~ ('^(chats?|chat_[a-z0-9_]+|[a-z0-9_]+_chats?|messages?|message_[a-z0-9_]+|[a-z0-9_]+_messages?|direct_messages?|dms?|dm_[a-z0-9_]+'
  ||'|conversations?|conversation_[a-z0-9_]+|calls?|call_[a-z0-9_]+|[a-z0-9_]+_calls?|voice_[a-z0-9_]+|video_calls?|video_call_[a-z0-9_]+'
  ||'|livekit_[a-z0-9_]+|[a-z0-9_]+_livekit[a-z0-9_]*|typing_[a-z0-9_]+|watch_part(y|ies)[a-z0-9_]*)$')
$$;
revoke all on function sdi_private.legacy_communication_name(text) from public,anon,authenticated;

create function sdi_private.retire_legacy_communications() returns jsonb language plpgsql security definer set search_path='' as $$
declare item record; closed_relations jsonb:='[]'::jsonb; closed_functions jsonb:='[]'::jsonb; unpublished jsonb:='[]'::jsonb;
begin
 for item in select c.oid,c.relname,c.relkind from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in('r','v','m','p','f') and sdi_private.legacy_communication_name(c.relname) order by c.relname loop
  execute format('revoke all on table public.%I from public,anon,authenticated',item.relname);
  if item.relkind in('r','p') then execute format('alter table public.%I enable row level security',item.relname); end if;
  closed_relations:=closed_relations||to_jsonb(item.relname::text);
  if item.relkind in('r','p') and exists(select 1 from pg_publication_tables p where p.pubname='supabase_realtime' and p.schemaname='public' and p.tablename=item.relname) then
   execute format('alter publication supabase_realtime drop table public.%I',item.relname);
   unpublished:=unpublished||to_jsonb(item.relname::text);
  end if;
 end loop;
 for item in select p.oid,p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid) as args from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind in('f','p') and sdi_private.legacy_communication_name(p.proname) order by p.proname loop
  execute format('revoke all on %s public.%I(%s) from public,anon,authenticated',
   case when (select prokind from pg_proc where oid=item.oid)='p' then 'procedure' else 'function' end,item.proname,item.args);
  closed_functions:=closed_functions||to_jsonb(item.proname||'('||item.args||')');
 end loop;
 return jsonb_build_object('closed_relations',closed_relations,'closed_functions',closed_functions,'removed_from_realtime',unpublished,
  'note','Client access removed; no rows were deleted. Retention or deletion of legacy rows is a separate owner decision.');
end $$;
revoke all on function sdi_private.retire_legacy_communications() from public,anon,authenticated;
grant execute on function sdi_private.retire_legacy_communications() to service_role;

-- Read-only check for the release gate: any client-reachable legacy object left?
create function sdi_private.legacy_communication_exposure() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'relations',coalesce((select jsonb_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in('r','v','m','p','f') and sdi_private.legacy_communication_name(c.relname)
   and (has_table_privilege('anon',c.oid,'select,insert,update,delete') or has_table_privilege('authenticated',c.oid,'select,insert,update,delete'))),'[]'::jsonb),
  'functions',coalesce((select jsonb_agg(p.proname order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and sdi_private.legacy_communication_name(p.proname)
   and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute'))),'[]'::jsonb))
$$;
revoke all on function sdi_private.legacy_communication_exposure() from public,anon,authenticated;
grant execute on function sdi_private.legacy_communication_exposure() to service_role;
create function public.sdi_legacy_communication_exposure() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.legacy_communication_exposure()$$;
revoke all on function public.sdi_legacy_communication_exposure() from public,anon,authenticated;
grant execute on function public.sdi_legacy_communication_exposure() to service_role;

do $$ begin perform sdi_private.retire_legacy_communications(); end $$;
commit;
