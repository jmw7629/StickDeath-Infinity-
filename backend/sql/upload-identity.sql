-- Unapplied candidate. Requires admin-users.sql. No service key in clients.
begin;
create function sdi_private.upload_identity() returns jsonb
language sql stable security definer set search_path='' as $$
 select case when sdi_private.account_active() and exists(
  select 1 from auth.users where id=auth.uid() and not is_anonymous
 ) then jsonb_build_object('authorized',true,'actor',auth.uid())
 else jsonb_build_object('authorized',false) end
$$;
revoke all on function sdi_private.upload_identity() from public,anon;
grant execute on function sdi_private.upload_identity() to authenticated;
create function public.sdi_upload_identity() returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.upload_identity()$$;
revoke all on function public.sdi_upload_identity() from public,anon;
grant execute on function public.sdi_upload_identity() to authenticated;
commit;
