#!/usr/bin/env python3
"""Two real provider-delivery sessions against run_sql_tests.sh's isolated cluster.

The controller holds a separate two-integer advisory gate. A test-only BEFORE
INSERT trigger stops the older first event there. The newer delivery must wait
behind the production subscription lock, then apply last after the gate opens.
Ordering is observed through pg_locks/pg_blocking_pids, not a timed sleep race.
--expect-bug is an explicit negative control for an unpatched disposable cluster;
the normal SQL runner never sets it. No provider, DATABASE_URL or TCP is used.
"""
import argparse
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import time
import uuid


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Controller:
    def __init__(self, command, env):
        self.process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.output = b""

    def send(self, sql, marker):
        self.process.stdin.write((sql + "\n\\echo " + marker + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        token = (marker + "\n").encode()
        while token not in self.output:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Controller did not acknowledge " + marker)
            readable, _, _ = select.select([self.process.stdout], [], [], remaining)
            require(readable, "Controller acknowledgment timed out: " + marker)
            chunk = os.read(self.process.stdout.fileno(), 65536)
            require(chunk, "Controller exited before " + marker)
            self.output += chunk
        self.output = self.output.split(token, 1)[1]

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(b"\\q\n")
                self.process.stdin.flush()
                self.process.wait(timeout=3)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                self.process.wait(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class Harness:
    def __init__(self, args):
        require(os.environ.get("SDI_SQL_TEST_CLUSTER") == "1", "Isolated SQL test marker is required")
        host = Path(args.host)
        require(host.is_absolute() and host.is_dir() and not host.is_symlink()
                and host.resolve() == host and str(host).startswith("/tmp/sdisql."),
                "Only the runner's /tmp/sdisql.* Unix socket directory is allowed")
        socket = host / (".s.PGSQL." + str(args.port))
        require(socket.exists() and stat.S_ISSOCK(socket.stat().st_mode), "Local test Unix socket is missing")
        self.command = [args.psql, "-X", "-q", "-A", "-t", "--no-password", "-v", "ON_ERROR_STOP=1",
                        "-h", str(host), "-p", str(args.port), "-U", "postgres", "-d", "postgres"]
        # Ignore ambient libpq service/options/host-address and all password
        # settings. Every connection explicitly names the isolated Unix socket.
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("PG") and k != "DATABASE_URL"}
        self.environment["PGCONNECT_TIMEOUT"] = "3"
        self.environment["PGOPTIONS"] = "-c statement_timeout=15000 -c lock_timeout=12000"
        state = self.json("select pg_catalog.jsonb_build_object('test', pg_catalog.current_setting('sdi.test_cluster',true),"
                          "'unix_socket', pg_catalog.inet_server_addr() is null)")
        require(state == {"test": "1", "unix_socket": True}, "Server is not the runner's marked isolated cluster")

    def env(self, name):
        return dict(self.environment, PGAPPNAME=name)

    def sql(self, text):
        result = subprocess.run(self.command + ["-c", text], env=self.env("sdi-billing-race-observer"),
                                capture_output=True, text=True, timeout=20)
        require(result.returncode == 0, "Test SQL failed: " + result.stderr[-2000:])
        return result.stdout.strip()

    def json(self, text):
        return json.loads(self.sql(text))

    def delivery(self, text, name):
        return subprocess.Popen(self.command + ["-c", "begin isolation level read committed; set local role service_role; "
                                                + text + "; commit;"], env=self.env(name),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def wait_for(self, query, description, process):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.sql(query) == "t":
                return
            require(process.poll() is None, "Delivery exited before observed lock state: " + description)
            # Polling backoff only: progress requires the exact database state.
            time.sleep(0.02)
        raise RuntimeError("Did not observe " + description)


def finish(process):
    out, err = process.communicate(timeout=15)
    require(process.returncode == 0, "Delivery failed: " + err[-2000:])
    return json.loads(out.strip())


def run(args):
    h = Harness(args)
    token = uuid.uuid4().hex[:16]
    tag = "sdi-bill-race-" + token
    schema = "sdi_billing_race_" + token
    subscription = tag + "-subscription"
    old_product, new_product = tag + "-creator", tag + "-pro"
    old_event, new_event, stale_event = tag + "-old", tag + "-new", tag + "-stale"
    old_name, new_name = tag + "-older", tag + "-newer"
    gate_class, gate_id = 2147483000, int(token[:7], 16)
    old_time, new_time = "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"
    controller, deliveries, setup = None, [], False
    user = None
    q = literal
    predicate = "provider='stripe' and provider_subscription_id=" + q(subscription)

    def call(event, when, product, trial, ledger_ref, amount):
        ledger = [{"ref": ledger_ref, "kind": "adjustment" if amount <= 0 else "charge",
                   "amount_minor": amount, "currency": "USD"}]
        return ("select public.sdi_billing_apply_event(provider=>'stripe',event_id=>" + q(event)
                + ",event_type=>'subscription.updated',occurred_at=>" + q(when) + "::timestamptz,payload=>'{}'::jsonb,user_id=>"
                + q(user) + "::uuid,provider_subscription_id=>" + q(subscription) + ",product_id=>" + q(product)
                + ",status=>'active',paid_through=>'2099-02-01T00:00:00Z'::timestamptz,ledger=>"
                + q(json.dumps(ledger)) + "::jsonb,in_trial=>" + ("true" if trial else "false") + ")")

    def state():
        return h.json("select pg_catalog.jsonb_build_object('count',(select count(*) from sdi_private.subscriptions where "
                      + predicate + "),'row',(select pg_catalog.to_jsonb(s) from sdi_private.subscriptions s where "
                      + predicate + "),'newer',(select last_event_at=" + q(new_time)
                      + "::timestamptz from sdi_private.subscriptions where " + predicate + "))")

    try:
        user = h.sql("select sdi_test.user(" + q(tag) + ")")
        h.sql("insert into sdi_private.billing_products(product_id,provider,tier,period,approved) values ("
              + q(old_product) + ",'stripe','creator','monthly',true),(" + q(new_product)
              + ",'stripe','pro','monthly',true)")
        h.sql("create schema " + schema + "; create function " + schema + ".pause_old_first_insert() returns trigger "
              + "language plpgsql set search_path='' as $$begin if new.provider='stripe' and new.provider_subscription_id="
              + q(subscription) + " and new.last_event_at=" + q(old_time)
              + "::timestamptz then perform pg_catalog.pg_advisory_xact_lock(" + str(gate_class) + "," + str(gate_id)
              + "); end if; return new; end$$; create trigger " + schema
              + " before insert on sdi_private.subscriptions for each row execute function " + schema + ".pause_old_first_insert()")
        setup = True
        controller = Controller(h.command, h.env(tag + "-controller"))
        controller.send("select pg_catalog.pg_advisory_lock(" + str(gate_class) + "," + str(gate_id) + ");", "GATE_HELD")
        older = h.delivery(call(old_event, old_time, old_product, True, tag + "-ledger-old", 0), old_name)
        deliveries.append(older)
        h.wait_for("select exists(select 1 from pg_catalog.pg_locks l join pg_catalog.pg_stat_activity a using(pid) "
                   + "where a.application_name=" + q(old_name) + " and l.locktype='advisory' and not l.granted "
                   + "and l.classid=" + str(gate_class) + "::oid and l.objid=" + str(gate_id) + "::oid and l.objsubid=2)",
                   "older delivery paused immediately before its first INSERT", older)
        newer = h.delivery(call(new_event, new_time, new_product, False, tag + "-ledger-new", 999), new_name)
        deliveries.append(newer)
        if args.expect_bug:
            newer_reply = finish(newer)
            require(state()["newer"] is True, "Negative control did not commit the newer event while older was paused")
        else:
            h.wait_for("select exists(select 1 from pg_catalog.pg_locks l join pg_catalog.pg_stat_activity a using(pid) "
                       + "join pg_catalog.pg_stat_activity blocker on blocker.pid=any(pg_catalog.pg_blocking_pids(a.pid)) "
                       + "where a.application_name=" + q(new_name) + " and blocker.application_name=" + q(old_name)
                       + " and l.locktype='advisory' and not l.granted and l.objsubid=1)",
                       "newer delivery waiting behind the older subscription transaction", newer)
        controller.send("select pg_catalog.pg_advisory_unlock(" + str(gate_class) + "," + str(gate_id) + ");", "GATE_RELEASED")
        older_reply = finish(older)
        if not args.expect_bug:
            newer_reply = finish(newer)
        require(older_reply.get("outcome") == "applied" and newer_reply.get("outcome") == "applied",
                "Both first deliveries must commit factual applied receipts")
        final = state()
        require(final["count"] == 1, "Concurrent first deliveries created the wrong subscription count")
        require(final["newer"] is (not args.expect_bug), "Final timestamp does not match the expected race outcome")
        winner = old_product if args.expect_bug else new_product
        require(final["row"]["product_id"] == winner and final["row"]["in_trial"] is args.expect_bug,
                "Product/trial state did not follow the winning provider event")
        ledger_count = int(h.sql("select count(*) from sdi_private.finance_ledger where provider='stripe' and provider_ref like " + q(tag + "%")))
        require(ledger_count == 2, "Concurrent deliveries lost or duplicated ledger records")
        duplicate = h.json(call(new_event, new_time, old_product, True, tag + "-duplicate-never", 98765))
        require(duplicate.get("duplicate") is True and state() == final, "Duplicate event changed subscription state")
        require(h.sql("select count(*) from sdi_private.finance_ledger where provider_ref=" + q(tag + "-duplicate-never")) == "0",
                "Duplicate event reached the ledger path")
        stale = h.json(call(stale_event, "2025-12-31T00:00:00Z", old_product, True, tag + "-ledger-stale", -10))
        require(stale.get("outcome") == "ignored" and state() == final, "A sequential stale event moved subscription state backward")
        require(h.sql("select count(*) from sdi_private.finance_ledger where provider='stripe' and provider_ref like " + q(tag + "%")) == "3",
                "Stale subscription state incorrectly discarded its distinct financial record")
        require(h.sql("select count(*) from sdi_private.provider_events where provider='stripe' and event_id like " + q(tag + "%")) == "3",
                "Provider event replay was not idempotent")
    finally:
        if controller is not None:
            controller.close()  # Also releases the gate on any failed assertion.
        for process in deliveries:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=3)
        if setup:
            h.sql("drop trigger if exists " + schema + " on sdi_private.subscriptions; drop schema " + schema
                  + " cascade; delete from sdi_private.finance_ledger where provider='stripe' and provider_ref like " + q(tag + "%")
                  + "; delete from sdi_private.provider_events where provider='stripe' and event_id like " + q(tag + "%")
                  + "; delete from sdi_private.subscriptions where " + predicate
                  + "; delete from sdi_private.billing_products where product_id in (" + q(old_product) + "," + q(new_product) + ")")
        if user is not None:
            h.sql("delete from auth.users where id=" + q(user) + "::uuid")
    print(json.dumps({"billingConcurrency": "BUG_REPRODUCED" if args.expect_bug else "PASS",
                      "deliverySessions": 2, "controllerGate": "pg_locks-observed",
                      "latestEventWins": not args.expect_bug, "duplicateAndLedgerGuards": "PASS"}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--psql", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--expect-bug", action="store_true", help="Negative control on an unpatched disposable test cluster only")
    args = parser.parse_args()
    require(1 <= args.port <= 65535, "Invalid test port")
    run(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"billingConcurrency": "FAIL", "error": str(error)[:2500]}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
