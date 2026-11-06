# Backend installation and owner access

This procedure describes the repository's controls. A checked-in configuration,
historical account note, passing fixture or generated SQL bundle does not establish
the state of a live environment. Verify the authorized target and its current
deployment records before making changes. Keep host addresses, account identifiers,
database backups and credentials in private operational records.

## Preserve an existing installation

Back up and verify restoration of the existing database and authentication state
before a migration. Inventory applied migrations, schema, users and retained data;
compare them with the intended source revision. Apply only the required reviewed
upgrade through the authorized administration connection.

Do not reset a live schema, delete migration history, or rerun the fresh-install
bundle over existing data. `backend/sql/dist/sdi-backend-install.sql` is an install
artifact for a verified empty environment, not a recovery or upgrade command.
An old dashboard project or historical owner account is not authorization to
change that resource. Preserve other projects and services.

Record the actual apply result, production regression result, backup/restore proof
and rollback procedure separately. SQL fixture success does not prove that real
authentication, media uploads or external publishing work.

Existing billing installations must also review the correction in
[`2026-10-20-three-tiers.sql`](../backend/sql/upgrades/2026-10-20-three-tiers.sql).
A previously applied copy can contain older function definitions; the corrected
upgrade requires reapplication as documented in that file. Use its transaction
after verified backup/restore and review, preserving subscription, event and ledger
records. Do not substitute a schema reset or the fresh-install bundle.

## Establish the owner identity

1. Configure the intended authentication service and approved redirect URLs.
   Keep service-role keys and provider secrets on the server. Browser/native clients
   use the intended public origin and publishable key only. See
   [authentication configuration](AUTH_PROVIDER_CONFIGURATION.md).
2. The owner creates or uses their actual account through the configured sign-in
   flow, confirms their email and enrols and verifies a second factor. Set or reset
   the password through that secure flow; never embed a chat-supplied password in
   source, issues, scripts or deployment configuration.
3. Verify the account's authenticated user UUID in that same environment. Through
   the private authorized SQL administration connection, provision that verified
   identity using the existing procedure:

   ```sql
   select public.sdi_provision_owner(
     'REPLACE_WITH_VERIFIED_AUTH_USER_UUID'::uuid,
     'JWS',
     'J_Willy_Style'
   );
   ```

   Replace the UUID placeholder before execution. The procedure requires an existing
   non-anonymous account, confirmed email and verified MFA factor. It refuses a
   different existing owner, records the role grant and ends the account's existing
   sessions. Preserve those checks; do not remove MFA or create a synthetic owner
   to get past a deployment gate. Repeating the request for the same owner returns
   `already_owner` without reprovisioning. A different existing owner requires the
   separate recovery procedure rather than a second bootstrap.
4. Sign in again with MFA. Verify an allowed administrator operation and a denied
   member operation. Administrative access remains enforced on each server call;
   a username, hidden navigation item or local entitlement flag grants nothing.

The command center and native admin use the same verified identity and permission
model. Sensitive operations require recent step-up authentication. Additional
administrators receive only the capabilities granted by the owner. See the
[command-center guide](ADMIN_COMMAND_CENTER.md).

## Approve publishing terms before enabling intake and release

The HTML in `website/policies/` may be draft material. Its existence is not owner
approval or a user's acceptance. Review the actual text, rights, destinations and
marketing choices first. Through the owner session with MFA and recent step-up,
use the command center's policy-version controls backed by `sdi_consent_action`.
Publishing a version requires owner permission, an immutable version ID, summary,
metadata, effective time and an audit reason.

Verify that the effective publishing version matches the policy referenced by the
native client and the served policy page. The publication workflow also needs the
creator's current explicit consent and rights attestation. Keep private drafts
private; marketing permission is a separate choice. If the effective policy is
missing, differs or lacks owner provenance, leave the dependent intake/publishing
worker disabled and report the unavailable state. Do not insert a fixture policy
or silently accept terms for a user.

Spatter draft generation and public release are separate operations. The owner
must approve generated videos before release to the feed or an external channel.
Keep official-channel OAuth tokens server-side and verify uploads with isolated
data without making live public test uploads. See the
[operating runbook](OPERATING_RUNBOOK.md).

## Enable providers and billing deliberately

Keep cloud/model requests disabled until configuration, authentication, spending
limits and the owner's authorization are present. Historical spending notes do
not enable a budget. Local Studio creation, persistence and export remain usable
without those providers.

Configure Apple, Google, GitHub and Microsoft sign-in through their actual provider
applications and approved redirects; missing configuration must produce an honest
unavailable state. Signing and store distribution require the owner's authorized
Apple/Google accounts. See [store setup](STORE_SETUP_OWNER.md).

Subscription catalogue code is not a live payment account or a completed store
integration. Bind the intended billing products and server credentials, verify
signed events and entitlements in the providers' test environments, and retain
refund/cancellation controls. Do not open a paid account, enable live charges or
publish fabricated purchase success as part of verification.
