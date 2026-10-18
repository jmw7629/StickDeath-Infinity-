#!/usr/bin/env bash
# Measured burst / rate-limit rehearsal (#263) on the local throwaway PostgreSQL
# cluster that scripts/backend/run_sql_tests.sh creates. It applies every SQL
# candidate, drives feed listing, War Room votes, room commands and upload
# registrations past their documented limits (sequentially, then feed and votes
# from concurrent client sessions), and prints the measured accepted / limited /
# other counts. It is a local rehearsal on stubbed Supabase pieces, not a load test
# of the live project, and asserts nothing: read the numbers.
#
#   bash scripts/backend/burst_rehearsal.sh            # default 8 workers x 30 calls
#   SDI_BURST_WORKERS=16 SDI_BURST_CALLS=20 bash scripts/backend/burst_rehearsal.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${SDI_PGHOST:-}" ]; then
 # Outer invocation: let run_sql_tests.sh build the cluster and call us back.
 SDI_SQL_AFTER="$ROOT/scripts/backend/burst_rehearsal.sh" SDI_SQL_SKIP_TESTS=1 exec bash "$ROOT/scripts/backend/run_sql_tests.sh"
fi

WORKERS="${SDI_BURST_WORKERS:-8}"; CALLS="${SDI_BURST_CALLS:-30}"
[[ "$WORKERS" =~ ^[0-9]+$ && "$CALLS" =~ ^[0-9]+$ && "$WORKERS" -ge 1 && "$WORKERS" -le 64 && "$CALLS" -ge 1 && "$CALLS" -le 500 ]] \
 || { echo "SDI_BURST_WORKERS must be 1..64 and SDI_BURST_CALLS 1..500" >&2; exit 2; }
PSQL=("$SDI_PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$SDI_PGHOST" -p "$SDI_PGPORT" -U postgres -d postgres)
OUT="$SDI_WORK/burst"; mkdir -p "$OUT"

echo "== sequential phase"
"${PSQL[@]}" -f "$ROOT/scripts/backend/burst_rehearsal.sql"

fixture() { "${PSQL[@]}" -tA -c "select id from sdi_burst.fixture where key='$1'"; }
FEED_MEMBER="$(fixture concurrent_feed)"; VOTER="$(fixture concurrent_voter)"; MATCH="$(fixture match)"

# Each call is its own transaction (login claims are transaction-local), so the
# limiter sees genuinely interleaved commits from separate sessions.
concurrent() { # name, member, statement
 local name="$1" member="$2" statement="$3" i w
 for w in $(seq 1 "$WORKERS"); do
  { for i in $(seq 1 "$CALLS"); do
     printf "begin; select sdi_test.login('%s') \\\\g /dev/null\nselect coalesce(%s, 'ok');\ncommit;\n" "$member" "${statement//@I@/$i}"
    done; } > "$OUT/$name.$w.sql"
 done
 local started; started="$(date +%s.%N)"
 for w in $(seq 1 "$WORKERS"); do "${PSQL[@]}" -tA -f "$OUT/$name.$w.sql" > "$OUT/$name.$w.out" & done
 wait
 local elapsed; elapsed="$(awk -v s="$started" -v e="$(date +%s.%N)" 'BEGIN{printf "%.2f", e-s}')"
 echo "$elapsed" > "$OUT/$name.elapsed"
}

echo "== concurrent phase: $WORKERS sessions x $CALLS calls each"
concurrent feed "$FEED_MEMBER" "sdi_private.feed_action('list')->>'error'"
concurrent votes "$VOTER" "(select case when v->>'status'='confirmed' then null else v->>'error' end from (select sdi_private.war_action('vote','$MATCH'::uuid,choice=>case when @I@%2=0 then 'left' else 'right' end) v) s)"

record() { # name, label, limit message, note
 local name="$1" label="$2" limit="$3" note="$4" total ok lim other
 total="$(cat "$OUT/$1".*.out | grep -c . || true)"
 ok="$(cat "$OUT/$1".*.out | grep -cx 'ok' || true)"
 lim="$(cat "$OUT/$1".*.out | grep -cxF "$limit" || true)"
 other=$((total-ok-lim))
 "${PSQL[@]}" -c "insert into sdi_burst.results values('$label','concurrent ${WORKERS}x${CALLS}',$total,$ok,$lim,$other,'${note}wall $(cat "$OUT/$name.elapsed")s')"
}
STORED="$("${PSQL[@]}" -tA -c "select count(*) from sdi_private.war_votes where match_id='$MATCH' and voter='$VOTER'")"
record feed 'feed list' 'Please wait before trying again.' ""
record votes 'war votes' 'Too many requests. Wait a minute.' "stored vote rows: $STORED; "

echo "== measured results (local throwaway cluster; not the live project)"
"${PSQL[@]}" -P pager=off -c "select surface, mode, attempts, accepted, limited, other, note from sdi_burst.results order by mode desc, surface"
"${PSQL[@]}" -tA -c "select 'BURST_REHEARSAL_TOTAL attempts='||sum(attempts)||' accepted='||sum(accepted)||' limited='||sum(limited)||' other='||sum(other) from sdi_burst.results"
