#!/usr/bin/env bash
# Applies every backend/sql candidate to a throwaway local PostgreSQL 16 cluster
# in the order listed in backend/sql/README.md, then runs backend/sql/tests/*.sql.
# This exercises the SQL on vanilla PostgreSQL with stubbed Supabase pieces
# (scripts/backend/sql_test_stubs.sql). It is not a deployment and proves nothing
# about the live project. Usage: scripts/backend/run_sql_tests.sh [--keep]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SQL_DIR="$ROOT/backend/sql"
README="$SQL_DIR/README.md"
STUBS="$ROOT/scripts/backend/sql_test_stubs.sql"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

# Locate PostgreSQL 16+ binaries (Debian/Ubuntu keep them off PATH).
PGBIN="${PGBIN:-}"
if [ -z "$PGBIN" ]; then
 for candidate in "$(command -v pg_config >/dev/null 2>&1 && pg_config --bindir || true)" /usr/lib/postgresql/*/bin /usr/local/pgsql/bin /opt/homebrew/opt/postgresql@16/bin; do
  if [ -n "$candidate" ] && [ -x "$candidate/initdb" ] && [ -x "$candidate/pg_ctl" ] && [ -x "$candidate/psql" ]; then PGBIN="$candidate"; fi
 done
fi
[ -n "$PGBIN" ] || { echo "initdb/pg_ctl/psql not found; install PostgreSQL 16 server binaries." >&2; exit 2; }
MAJOR="$("$PGBIN/pg_ctl" --version | sed -E 's/^pg_ctl \(PostgreSQL\) ([0-9]+).*/\1/')"
[ "$MAJOR" -ge 16 ] || { echo "PostgreSQL 16 or newer required; found $MAJOR." >&2; exit 2; }

# PostgreSQL refuses to run as root. When invoked by root, run the server inside
# a user namespace mapped to an existing unprivileged account so no system
# directories change ownership. Otherwise run as the current user.
AS_PG=()
if [ "$(id -u)" = "0" ]; then
 for account in postgres nobody; do
  if id "$account" >/dev/null 2>&1 && unshare --user --map-user="$account" --map-group="$account" -- true 2>/dev/null; then
   AS_PG=(unshare --user --map-user="$account" --map-group="$account" --); break
  fi
 done
 [ "${#AS_PG[@]}" -gt 0 ] || { echo "Running as root and no unprivileged mapping available; run this script as a normal user." >&2; exit 2; }
fi

WORK="${SDI_SQL_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/sdi-sql-test.XXXXXX")}"
mkdir -p "$WORK"
SOCKET_DIR="$(mktemp -d /tmp/sdisql.XXXXXX)"   # Unix socket paths are limited to 107 bytes.
DATA="$WORK/data"; LOG="$WORK/postgres.log"; PORT="${SDI_SQL_TEST_PORT:-54329}"
cleanup() {
 if [ -f "$DATA/postmaster.pid" ]; then "${AS_PG[@]}" "$PGBIN/pg_ctl" -D "$DATA" stop -m fast -s >/dev/null 2>&1 || true; fi
 rm -rf "$SOCKET_DIR"
 if [ "$KEEP" = "0" ]; then rm -rf "$WORK"; else echo "Cluster data kept at $WORK (log: $LOG)"; fi
}
trap cleanup EXIT
rm -rf "$DATA"
"${AS_PG[@]}" "$PGBIN/initdb" -D "$DATA" -A trust -U postgres --no-instructions >"$WORK/initdb.log" 2>&1 \
 || { cat "$WORK/initdb.log" >&2; exit 1; }
"${AS_PG[@]}" "$PGBIN/pg_ctl" -D "$DATA" -w -s -l "$LOG" \
 -o "-k $SOCKET_DIR -p $PORT -c listen_addresses='' -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c log_min_messages=warning" start \
 || { cat "$LOG" >&2; exit 1; }
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U postgres -d postgres)
"${PSQL[@]}" -c "select version();" -tA

# The README's apply-order block is the single source of truth for ordering.
mapfile -t ORDER < <(sed -n '/<!-- apply-order -->/,/<!-- \/apply-order -->/p' "$README" | grep -oE '[a-z0-9-]+\.sql' || true)
[ "${#ORDER[@]}" -gt 0 ] || { echo "backend/sql/README.md has no <!-- apply-order --> block." >&2; exit 1; }
missing=0
for file in "$SQL_DIR"/*.sql; do
 name="$(basename "$file")"
 if ! printf '%s\n' "${ORDER[@]}" | grep -qx "$name"; then echo "Not in README apply order: $name" >&2; missing=1; fi
done
[ "$missing" = "0" ] || exit 1
for name in "${ORDER[@]}"; do [ -f "$SQL_DIR/$name" ] || { echo "README lists missing file $name" >&2; exit 1; }; done

echo "== stubs: $(basename "$STUBS")"
"${PSQL[@]}" -f "$STUBS"
for name in "${ORDER[@]}"; do
 echo "== apply: $name"
 "${PSQL[@]}" -f "$SQL_DIR/$name"
done
echo "== applied ${#ORDER[@]} candidate files"

status=0; passed=0; failed=0
shopt -s nullglob
for test in "$SQL_DIR"/tests/*.sql; do
 name="$(basename "$test")"
 # Each test file wraps itself in begin/rollback so the cluster stays clean.
 if "${PSQL[@]}" -f "$test" >"$WORK/$name.out" 2>&1; then
  echo "PASS $name"; passed=$((passed+1))
 else
  echo "FAIL $name"; sed 's/^/    /' "$WORK/$name.out"; failed=$((failed+1)); status=1
 fi
done
echo "== sql tests: $passed passed, $failed failed"
exit $status
