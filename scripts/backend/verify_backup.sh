#!/usr/bin/env bash
# Backup/restore rehearsal for the SQL candidates (#256, #257). Starts a throwaway
# PostgreSQL 16 cluster exactly like run_sql_tests.sh, applies the stubs and every
# candidate, loads a minimal fixture of the "minimum server records" (an account,
# an admin role, a subscription, a support request, a consent record, a feed post),
# takes a pg_dump custom-format backup, restores it into a second database and
# verifies: identical row counts for every sdi_private and public table, row level
# security still enabled on every restored table, the service/client function
# grants intact, and no plaintext secret-looking value in the dump. It exercises the
# procedure, not the live project: production backups are the host's managed
# backups and must be rehearsed there by the owner with the same checks.
# Usage: scripts/backend/verify_backup.sh [--keep]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SQL_DIR="$ROOT/backend/sql"; README="$SQL_DIR/README.md"; STUBS="$ROOT/scripts/backend/sql_test_stubs.sql"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
PGBIN="${PGBIN:-}"
if [ -z "$PGBIN" ]; then
 for candidate in "$(command -v pg_config >/dev/null 2>&1 && pg_config --bindir || true)" /usr/lib/postgresql/*/bin /usr/local/pgsql/bin /opt/homebrew/opt/postgresql@16/bin; do
  if [ -n "$candidate" ] && [ -x "$candidate/initdb" ] && [ -x "$candidate/pg_dump" ] && [ -x "$candidate/pg_restore" ]; then PGBIN="$candidate"; fi
 done
fi
[ -n "$PGBIN" ] || { echo "PostgreSQL 16 server binaries (initdb, pg_dump, pg_restore) not found." >&2; exit 2; }
AS_PG=()
if [ "$(id -u)" = "0" ]; then
 for account in postgres nobody; do
  if id "$account" >/dev/null 2>&1 && unshare --user --map-user="$account" --map-group="$account" -- true 2>/dev/null; then
   AS_PG=(unshare --user --map-user="$account" --map-group="$account" --); break
  fi
 done
 [ "${#AS_PG[@]}" -gt 0 ] || { echo "Running as root without an unprivileged mapping; run as a normal user." >&2; exit 2; }
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sdi-backup-test.XXXXXX")"; SOCKET_DIR="$(mktemp -d /tmp/sdibk.XXXXXX)"
DATA="$WORK/data"; LOG="$WORK/postgres.log"; PORT="${SDI_SQL_TEST_PORT:-54331}"; DUMP="$WORK/backup.dump"
cleanup() {
 if [ -f "$DATA/postmaster.pid" ]; then "${AS_PG[@]}" "$PGBIN/pg_ctl" -D "$DATA" stop -m fast -s >/dev/null 2>&1 || true; fi
 rm -rf "$SOCKET_DIR"; if [ "$KEEP" = "0" ]; then rm -rf "$WORK"; else echo "Kept $WORK"; fi
}
trap cleanup EXIT
"${AS_PG[@]}" "$PGBIN/initdb" -D "$DATA" -A trust -U postgres --no-instructions >"$WORK/initdb.log" 2>&1 || { cat "$WORK/initdb.log" >&2; exit 1; }
"${AS_PG[@]}" "$PGBIN/pg_ctl" -D "$DATA" -w -s -l "$LOG" -o "-k $SOCKET_DIR -p $PORT -c listen_addresses='' -c fsync=off -c synchronous_commit=off -c log_min_messages=warning" start || { cat "$LOG" >&2; exit 1; }
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U postgres)
mapfile -t ORDER < <(sed -n '/<!-- apply-order -->/,/<!-- \/apply-order -->/p' "$README" | grep -oE '[a-z0-9-]+\.sql' || true)
[ "${#ORDER[@]}" -gt 0 ] || { echo "No apply order in README." >&2; exit 1; }
"${PSQL[@]}" -d postgres -c "create database source" -c "create database restored" >/dev/null
"${PSQL[@]}" -d source -f "$STUBS" >/dev/null
for name in "${ORDER[@]}"; do "${PSQL[@]}" -d source -f "$SQL_DIR/$name" >/dev/null; done
echo "== applied ${#ORDER[@]} candidates to 'source'"
# Minimal fixture of the records a restore must bring back.
"${PSQL[@]}" -d source <<'SQL' >/dev/null
do $$
declare member uuid; owner uuid; media uuid;
begin
 member:=sdi_test.user('restore-member'); owner:=sdi_test.admin('restore-owner',true,array[]::text[]);
 insert into sdi_private.billing_products(product_id,provider,tier,period,approved,owner_configured_at) values('sdi.creator.monthly','apple','creator','monthly',true,clock_timestamp());
 perform sdi_private.billing_apply_event('apple','evt-restore','SUBSCRIBED',clock_timestamp(),'{"environment":"Sandbox"}',member,'orig-restore','sdi.creator.monthly','active',clock_timestamp()+interval '30 days');
 perform sdi_test.login(member);
 perform sdi_private.support_action('create',category=>'account',platform=>'ios',subject=>'Restore test',body=>'Fixture.',idempotency=>gen_random_uuid());
 perform sdi_test.login(owner,'aal2',60);
 perform sdi_private.consent_action('publish','publishing','publishing-v1',summary=>'Fixture.',reason=>'Fixture.');
 perform sdi_test.login(member);
 perform sdi_private.consent_action('accept','publishing','publishing-v1','ios');
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('Fixture','https://cdn.example.test/f.mp4',3,true,member,repeat('e',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,member,'restore-member',true);
 perform sdi_test.logout();
end $$;
SQL
"${AS_PG[@]}" "$PGBIN/pg_dump" -h "$SOCKET_DIR" -p "$PORT" -U postgres -Fc -f "$DUMP" source
echo "== dump written: $(stat -c %s "$DUMP") bytes"
"${AS_PG[@]}" "$PGBIN/pg_restore" -h "$SOCKET_DIR" -p "$PORT" -U postgres -d restored --no-owner "$DUMP" 2>"$WORK/restore.err" || { echo "pg_restore reported errors:" >&2; cat "$WORK/restore.err" >&2; exit 1; }
[ -s "$WORK/restore.err" ] && { echo "pg_restore warnings:"; cat "$WORK/restore.err"; }
COUNT_SQL="select n.nspname||'.'||c.relname||'='||(xpath('/row/c/text()',query_to_xml(format('select count(*) as c from %I.%I',n.nspname,c.relname),false,true,'')))[1]::text
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname in('sdi_private','public') order by 1"
"${PSQL[@]}" -d source -tA -c "$COUNT_SQL" >"$WORK/counts.source"
"${PSQL[@]}" -d restored -tA -c "$COUNT_SQL" >"$WORK/counts.restored"
if ! diff -u "$WORK/counts.source" "$WORK/counts.restored" >"$WORK/counts.diff"; then echo "Row counts differ after restore:" >&2; cat "$WORK/counts.diff" >&2; exit 1; fi
TABLES="$(wc -l <"$WORK/counts.source")"; NONEMPTY="$(grep -vc '=0$' "$WORK/counts.source" || true)"
echo "== row counts identical for $TABLES tables ($NONEMPTY non-empty)"
NO_RLS="$("${PSQL[@]}" -d restored -tA -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname in('sdi_private','public') and not c.relrowsecurity")"
[ "$NO_RLS" = "0" ] || { echo "Restored tables without RLS: $NO_RLS" >&2; exit 1; }
echo "== row level security enabled on every restored table"
ANON_FN="$("${PSQL[@]}" -d restored -tA -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'sdi\_%' and has_function_privilege('anon',p.oid,'execute')")"
SVC_FN="$("${PSQL[@]}" -d restored -tA -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'sdi\_%' and has_function_privilege('service_role',p.oid,'execute')")"
[ "$ANON_FN" = "0" ] || { echo "anon can execute $ANON_FN functions after restore" >&2; exit 1; }
echo "== grants intact: anon=0 service-only=$SVC_FN"
ENTITLED="$("${PSQL[@]}" -d restored -tA -c "select count(*) from sdi_private.entitlements")"
[ "$ENTITLED" = "1" ] || { echo "Entitlement view did not come back ($ENTITLED)" >&2; exit 1; }
echo "== fixture entitlement readable after restore"
if "$PGBIN/pg_restore" -l "$DUMP" | grep -qiE 'password|secret'; then echo "Dump catalogue mentions password/secret objects" >&2; exit 1; fi
if strings "$DUMP" | grep -qE 'sk_live|sk_test|whsec_|-----BEGIN'; then echo "Dump contains credential-shaped text" >&2; exit 1; fi
echo "== no credential-shaped content in the dump"
echo "BACKUP RESTORE REHEARSAL PASSED (local throwaway cluster; not the live project)"
