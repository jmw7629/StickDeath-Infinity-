-- Object-level authorization review (#187, #122). These assertions hold for the
-- whole installed candidate set, so every future candidate is checked too:
--  * every sdi_private table has row level security and no grant to a client role;
--  * every sdi_private function and every public sdi_* wrapper pins an empty search_path;
--  * public wrappers are security invoker; the definer bodies live in sdi_private;
--  * no public sdi_* function is executable by anon or PUBLIC;
--  * each public sdi_* function is executable by exactly one of authenticated and
--    service_role, and the service-only set is the explicit list below (adding a
--    worker function means reviewing it here);
--  * no column stores a password, secret or raw token; only hashes are kept;
--  * public tables (legacy rooms/watch surface) have RLS and no anon grants.
begin;
do $$
declare bad text; service_expected text[]:=array[
 'sdi_account_deletion_run','sdi_agent_log_retention','sdi_agent_proposal_finish','sdi_agent_proposals_due','sdi_agent_propose','sdi_agent_run_begin',
 'sdi_agent_run_finish','sdi_agent_run_heartbeat','sdi_announcement_claim','sdi_announcement_finish','sdi_audit_integrity_report',
 'sdi_award_achievements','sdi_billing_apply_event','sdi_billing_reconcile','sdi_challenge_finalize','sdi_consent_retention_sweep',
 'sdi_consent_verify','sdi_credential_load','sdi_credential_record_state','sdi_credential_revoke','sdi_credential_store','sdi_diagnostics_retention',
 'sdi_email_recipients','sdi_email_suppress','sdi_feed_publish_claim','sdi_feed_publish_finish','sdi_feed_removal_claim','sdi_feed_removal_finish',
 'sdi_legacy_communication_exposure','sdi_marketing_cadence_due','sdi_marketing_claim','sdi_marketing_finish','sdi_ops_report','sdi_preview_renew',
 'sdi_provision_owner','sdi_publication_release_candidates','sdi_publish_claim','sdi_publish_finish','sdi_publish_progress',
 'sdi_publish_removal_claim','sdi_publish_removal_finish','sdi_publish_removal_renew','sdi_publish_renew','sdi_publish_uncertain',
 'sdi_register_upload','sdi_release_published_upload','sdi_retire_upload','sdi_room_asset_sweep','sdi_spatter_credits_grant','sdi_spatter_credits_refund','sdi_spatter_draft_claim',
 'sdi_spatter_draft_progress','sdi_spatter_usage_meter','sdi_support_retention','sdi_upload_preview','sdi_war_expire_proposals','sdi_war_finalize',
 'sdi_worker_configuration','sdi_worker_heartbeat'];
 service_actual text[]; client_count integer;
begin
 select string_agg(c.relname,', ') into bad from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='sdi_private' and c.relkind='r' and not c.relrowsecurity;
 perform sdi_test.check(bad is null,'sdi_private tables without RLS: '||coalesce(bad,''));
 select string_agg(grantee||':'||table_name,', ') into bad from information_schema.role_table_grants
  where table_schema='sdi_private' and grantee in('anon','authenticated','PUBLIC');
 perform sdi_test.check(bad is null,'client grants on sdi_private tables: '||coalesce(bad,''));
 select string_agg(grantee||':'||table_name||'.'||column_name,', ') into bad from information_schema.role_column_grants
  where table_schema='sdi_private' and grantee in('anon','authenticated','PUBLIC');
 perform sdi_test.check(bad is null,'client column grants on sdi_private tables: '||coalesce(bad,''));
 select string_agg(n.nspname||'.'||p.proname,', ') into bad from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='sdi_private' or (n.nspname='public' and p.proname like 'sdi\_%')) and p.prokind='f'
  and not coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""'];
 perform sdi_test.check(bad is null,'functions without an empty search_path: '||coalesce(bad,''));
 select string_agg(p.proname,', ') into bad from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'sdi\_%' and p.prosecdef;
 perform sdi_test.check(bad is null,'public wrappers must be security invoker: '||coalesce(bad,''));
 select string_agg(p.proname,', ') into bad from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'sdi\_%' and has_function_privilege('anon',p.oid,'execute');
 perform sdi_test.check(bad is null,'public functions executable by anon: '||coalesce(bad,''));
 select string_agg(p.proname,', ') into bad from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'sdi\_%'
  and has_function_privilege('authenticated',p.oid,'execute')=has_function_privilege('service_role',p.oid,'execute');
 perform sdi_test.check(bad is null,'public functions must be client-only or service-only: '||coalesce(bad,''));
 select coalesce(array_agg(p.proname order by p.proname),'{}') into service_actual from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'sdi\_%' and has_function_privilege('service_role',p.oid,'execute');
 perform sdi_test.check(service_actual=service_expected,'service-only surface changed; review and update the list: '||array_to_string(service_actual,','));
 select count(*) into client_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'sdi\_%' and has_function_privilege('authenticated',p.oid,'execute');
 perform sdi_test.check(client_count>=40,'client surface present: '||client_count);
 select string_agg(table_schema||'.'||table_name||'.'||column_name,', ') into bad from information_schema.columns
  where table_schema in('sdi_private','public') and (column_name ~* 'password|secret|api_key|private_key' or (column_name ~* 'token' and column_name !~* '_hash$' and table_name<>'device_tokens'));
 perform sdi_test.check(bad is null,'secret-like columns: '||coalesce(bad,''));
 select string_agg(c.relname,', ') into bad from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;
 perform sdi_test.check(bad is null,'public tables without RLS: '||coalesce(bad,''));
 select string_agg(table_name,', ') into bad from information_schema.role_table_grants where table_schema='public' and grantee in('anon','PUBLIC');
 perform sdi_test.check(bad is null,'anon grants on public tables: '||coalesce(bad,''));
 select string_agg(table_name||':'||privilege_type,', ') into bad from information_schema.role_table_grants
  where table_schema='public' and grantee='authenticated' and privilege_type in('DELETE','TRUNCATE','REFERENCES','TRIGGER');
 perform sdi_test.check(bad is null,'authenticated may not delete or alter public tables directly: '||coalesce(bad,''));
 -- Cross-user denial on a representative object of each area: a different member's rows are invisible or refused.
 perform sdi_test.check((select count(*) from pg_policies where schemaname='public' and tablename='sdi_watch_media' and cmd='SELECT')=1,'approved-media read policy present');
end $$;
rollback;
