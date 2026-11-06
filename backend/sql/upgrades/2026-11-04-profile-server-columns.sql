-- Existing-install profile column ACL correction; apply as the table owner.
-- Fresh projects use users-profiles.sql/current bundle. No data, defaults,
-- RLS policies, service grants, role memberships or global default ACLs change.
-- No CASCADE: unexpected dependent grants fail the transaction for review.
begin;

-- Keep this block identical to the candidate's revoke/regrant statements.
-- Table REVOKE also removes the corresponding old column grants from this grantor.
revoke all on public.users from public,anon,authenticated;
grant select on public.users to authenticated;
grant insert(id,email,username,bio,avatar_url,onboarded,skill_level,interests) on public.users to authenticated;
grant update(username,bio,avatar_url,onboarded,skill_level,interests) on public.users to authenticated;

-- Other grantors or inherited role privileges can survive a local ACL reset.
-- Fail closed rather than changing memberships or claiming those rights vanished.
do $profile_acl$
declare bad text;
begin
 if not (select relrowsecurity from pg_class where oid='public.users'::regclass) then
  raise exception 'Profile ACL correction requires the existing RLS-enabled canonical table.';
 end if;
 if not has_table_privilege('authenticated','public.users','SELECT')
  or has_table_privilege('authenticated','public.users','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
  raise exception 'Profile ACL correction did not produce the intended table privileges; review inherited/other-grantor rights.';
 end if;
 select string_agg(a.attname::text,', ' order by a.attnum) into bad from pg_attribute a
  where a.attrelid='public.users'::regclass and a.attnum>0 and not a.attisdropped
  and (has_column_privilege('authenticated','public.users',a.attname::text,'INSERT') is distinct from
    (a.attname::text=any(array['id','email','username','bio','avatar_url','onboarded','skill_level','interests']))
   or has_column_privilege('authenticated','public.users',a.attname::text,'UPDATE') is distinct from
    (a.attname::text=any(array['username','bio','avatar_url','onboarded','skill_level','interests'])));
 if bad is not null then
  raise exception 'Profile ACL correction left unexpected insert/update column privileges: %',bad;
 end if;
 if has_any_column_privilege('anon','public.users','SELECT,INSERT,UPDATE,REFERENCES')
  or has_any_column_privilege('public','public.users','SELECT,INSERT,UPDATE,REFERENCES') then
  raise exception 'Profile ACL correction left anonymous/public column privileges; review inherited/other-grantor rights.';
 end if;
end $profile_acl$;

commit;
