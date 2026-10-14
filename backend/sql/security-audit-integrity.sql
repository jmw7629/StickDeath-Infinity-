-- Unapplied candidate (#256). Install after every file that creates an audit table
-- (last in the apply order). Makes each sdi_private.*_audit table append-only for
-- every role that reaches it through the application: UPDATE is refused except when
-- a foreign key's ON DELETE SET NULL clears a member reference, and DELETE or
-- TRUNCATE is refused except inside the account purge (account_deletion_run sets the
-- transaction-local flag sdi.audit_purge). This protects evidence from application
-- paths and mistakes; it does not protect against the database owner, who can drop
-- triggers. audit_integrity_report() lets the restore drill and the owner confirm
-- that every audit table still carries the guard.
begin;
create function sdi_private.audit_append_only() returns trigger language plpgsql set search_path='' as $$
declare before jsonb; after jsonb; k text;
begin
 if tg_op in('DELETE','TRUNCATE') then
  if coalesce(current_setting('sdi.audit_purge',true),'')='on' then
   return case when tg_op='DELETE' then old else null end; end if;
  raise exception 'Audit records are append-only (%).',tg_table_name using errcode='42501';
 end if;
 before:=to_jsonb(old); after:=to_jsonb(new);
 for k in select key from jsonb_each(before) loop
  if before->k is distinct from after->k and not (after->k='null'::jsonb and k=any(tg_argv)) then
   raise exception 'Audit records are append-only (%.%).',tg_table_name,k using errcode='42501';
  end if;
 end loop;
 return new;
end $$;
revoke all on function sdi_private.audit_append_only() from public,anon,authenticated;

-- Attach to every audit table present now. Columns whose foreign key clears on
-- delete are the only ones an UPDATE may change, and only to null.
do $$
declare t record; cols text[];
begin
 for t in select c.oid,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='sdi_private' and c.relkind='r' and c.relname like '%\_audit' order by c.relname loop
  select coalesce(array_agg(distinct a.attname::text),'{}') into cols from pg_constraint k
   join pg_attribute a on a.attrelid=k.conrelid and a.attnum=any(k.conkey)
   where k.conrelid=t.oid and k.contype='f' and k.confdeltype='n';
  execute format('create trigger audit_append_only before update or delete on sdi_private.%I for each row execute function sdi_private.audit_append_only(%s)',
   t.relname,coalesce((select string_agg(quote_literal(c),',') from unnest(cols) c),''));
  execute format('create trigger audit_no_truncate before truncate on sdi_private.%I for each statement execute function sdi_private.audit_append_only()',t.relname);
 end loop;
end $$;

-- Service and owner check: every audit table, whether it is guarded, and its rows.
create function sdi_private.audit_integrity_report() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tables',coalesce(jsonb_agg(jsonb_build_object('table',c.relname,
   'guarded',exists(select 1 from pg_trigger g where g.tgrelid=c.oid and g.tgname='audit_append_only' and g.tgenabled<>'D')
    and exists(select 1 from pg_trigger g where g.tgrelid=c.oid and g.tgname='audit_no_truncate' and g.tgenabled<>'D'),
   'rls',c.relrowsecurity) order by c.relname),'[]'::jsonb),
  'unguarded',coalesce(sum(case when exists(select 1 from pg_trigger g where g.tgrelid=c.oid and g.tgname='audit_append_only' and g.tgenabled<>'D') then 0 else 1 end),0))
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='sdi_private' and c.relkind='r' and c.relname like '%\_audit'
$$;
revoke all on function sdi_private.audit_integrity_report() from public,anon,authenticated;
grant execute on function sdi_private.audit_integrity_report() to service_role;
create function public.sdi_audit_integrity_report() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.audit_integrity_report()$$;
revoke all on function public.sdi_audit_integrity_report() from public,anon,authenticated;
grant execute on function public.sdi_audit_integrity_report() to service_role;
commit;
