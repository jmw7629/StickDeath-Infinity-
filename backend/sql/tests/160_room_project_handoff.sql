-- Local assertions for the rooms v2.2 block of rooms-v2.sql: owner-approved
-- project handoff (#234). One live snapshot per room, server-verified SHA-256,
-- approved-member-only download, per-member receipts, deletion after delivery,
-- revocation, replacement, project change, room close and expiry, and audit rows.
begin;
do $$
declare owner uuid; a uuid; b uuid; pending uuid; outsider uuid; other_owner uuid; room uuid; other_room uuid; r jsonb; code text;
 bytes bytea; digest text; snap uuid; other_snap uuid; got bytea; bad uuid; chunk integer:=262144;
begin
 owner:=sdi_test.user('handoff-owner'); a:=sdi_test.user('handoff-a'); b:=sdi_test.user('handoff-b');
 pending:=sdi_test.user('handoff-pending'); outsider:=sdi_test.user('handoff-outsider'); other_owner:=sdi_test.user('handoff-other-owner');
 perform sdi_test.login(owner);
 room:=(sdi_private.room_action('create',title=>'Handoff room',consent=>true)->>'room_id')::uuid;
 code:=sdi_private.room_action('invite',room)->>'code';
 perform sdi_test.login(a); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(b); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(pending); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(owner);
 perform sdi_private.room_action('approve',room,a); perform sdi_private.room_action('approve',room,b);

 -- Privileges: no anon access; the RPC is for signed-in members; tables are closed.
 perform sdi_test.check(not has_function_privilege('anon','public.sdi_room_snapshot(text,uuid,uuid,bigint,text,integer,text)','execute')
  and has_function_privilege('authenticated','public.sdi_room_snapshot(text,uuid,uuid,bigint,text,integer,text)','execute'),'rpc grants');
 perform sdi_test.check(not has_table_privilege('authenticated','sdi_private.room_project_snapshots','select')
  and not has_table_privilege('anon','sdi_private.room_project_snapshot_chunks','select')
  and not has_table_privilege('authenticated','sdi_private.room_project_snapshot_receipts','select')
  and not has_table_privilege('authenticated','sdi_private.room_snapshot_audit','select'),'tables closed to clients');
 perform sdi_test.check((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='sdi_private'
  and c.relname in('room_project_snapshots','room_project_snapshot_chunks','room_project_snapshot_receipts','room_snapshot_budget','room_snapshot_audit')),'rls enabled');

 bytes:=convert_to('SDIPROJECT000001'||repeat('stickfigure',30000),'UTF8'); -- 330016 bytes: two chunks
 digest:=encode(extensions.digest(bytes,'sha256'),'hex');

 -- A project must be shared first; only the owner may offer.
 r:=sdi_private.room_snapshot('offer',room,byte_size=>octet_length(bytes),sha256=>digest);
 perform sdi_test.check(r->>'error' like 'Share a project%','no handoff before a project is shared: '||r::text);
 perform sdi_private.room_manage('set_project',room,project_ref=>'device-project:h',project_title=>'Duel',permissions=>array['view'],revision=>1);
 perform sdi_test.login(a);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>octet_length(bytes),sha256=>digest);
 perform sdi_test.check(r->>'error'='Only the room owner can send the shared project.','members cannot offer');
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>33554433,sha256=>digest);
 perform sdi_test.check(r->>'error' like 'A project backup up to 32 MB%','size cap enforced');
 r:=sdi_private.room_snapshot('offer',room,byte_size=>octet_length(bytes),sha256=>'XYZ');
 perform sdi_test.check(r->>'error' is not null,'malformed sha refused');
 r:=sdi_private.room_snapshot('offer',room,byte_size=>octet_length(bytes),sha256=>digest);
 perform sdi_test.check(r->>'status'='declared' and (r->>'chunk_count')::int=2 and (r->>'chunk_size')::int=chunk,'declared: '||r::text);
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_test.check((select expires_at from sdi_private.room_project_snapshots where id=snap)<=clock_timestamp()+interval '1 hour','unfinished upload expires in an hour');

 -- Chunked upload with resume; members cannot see an unfinished snapshot.
 r:=sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode(substring(bytes from 1 for 100),'base64'));
 perform sdi_test.check(r->>'error' like 'Chunk length%','short chunk refused');
 r:=sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode(substring(bytes from 1 for chunk),'base64'));
 perform sdi_test.check(r->>'status'='stored' and (r->>'received')::int=1,'chunk 0 stored: '||r::text);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>octet_length(bytes),sha256=>digest);
 perform sdi_test.check(r->>'status'='existing' and (r->>'snapshot_id')::uuid=snap and r->'received'='[0]'::jsonb,'re-offer resumes: '||r::text);
 r:=sdi_private.room_snapshot('finalize',room,snap);
 perform sdi_test.check(r->>'error'='incomplete' and r->'received'='[0]'::jsonb,'finalize names missing chunks');
 perform sdi_test.login(a);
 r:=sdi_private.room_snapshot('current',room);
 perform sdi_test.check(r->'snapshot'='null'::jsonb,'members do not see a receiving snapshot: '||r::text);
 perform sdi_test.check(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'error' like 'No shared project%','unfinished snapshot not downloadable');
 perform sdi_test.login(owner);
 perform sdi_private.room_snapshot('put',room,snap,chunk_index=>1,data=>encode(substring(bytes from chunk+1),'base64'));
 r:=sdi_private.room_snapshot('finalize',room,snap);
 perform sdi_test.check(r->>'status'='available' and (r->>'awaiting')::int=2,'server verified the hash; two members awaiting: '||r::text);
 perform sdi_test.check((select expires_at from sdi_private.room_project_snapshots where id=snap) between clock_timestamp()+interval '71 hours' and clock_timestamp()+interval '72 hours','72-hour retention');
 perform sdi_test.check(sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode(substring(bytes from 1 for chunk),'base64'))->>'error' is not null,'available snapshot immutable');
 perform sdi_test.check(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'error' like 'No shared project%','owner does not download their own project');
 r:=sdi_private.room_snapshot('current',room);
 perform sdi_test.check((r->'snapshot'->>'delivered')::int=0 and (r->'snapshot'->>'awaiting')::int=2 and (r->'snapshot'->>'mine')::boolean,'owner sees delivery counts');

 -- Outsiders, pending requesters and other rooms see nothing.
 perform sdi_test.login(outsider);
 perform sdi_test.check(sdi_private.room_snapshot('current',room)->>'error'='Room is unavailable.','outsider cannot see');
 perform sdi_test.check(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'error'='Room is unavailable.','outsider cannot download');
 perform sdi_test.login(pending);
 perform sdi_test.check(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'error'='Room is unavailable.','pending requester cannot download');
 perform sdi_test.login(other_owner);
 other_room:=(sdi_private.room_action('create',title=>'Other room',consent=>true)->>'room_id')::uuid;
 perform sdi_private.room_manage('set_project',other_room,project_ref=>'device-project:o',project_title=>'Other',permissions=>array['view'],revision=>1);
 r:=sdi_private.room_snapshot('offer',other_room,byte_size=>3,sha256=>encode(extensions.digest('abc'::bytea,'sha256'),'hex'));
 other_snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',other_room,other_snap,chunk_index=>0,data=>encode('abc'::bytea,'base64'));
 perform sdi_test.check(sdi_private.room_snapshot('finalize',other_room,other_snap)->>'status'='available','other room snapshot available');
 code:=sdi_private.room_action('invite',other_room)->>'code';
 perform sdi_test.login(a); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(other_owner); perform sdi_private.room_action('approve',other_room,a);
 perform sdi_test.login(a);
 perform sdi_test.check(sdi_private.room_snapshot('get',room,other_snap,chunk_index=>0)->>'error' like 'No shared project%','another room''s snapshot id never resolves in this room');
 perform sdi_test.login(b);
 perform sdi_test.check(sdi_private.room_snapshot('get',other_room,other_snap,chunk_index=>0)->>'error'='Room is unavailable.','member of one room cannot reach another room''s snapshot');

 -- Member download and receipt. Wrong digest receipt is refused.
 perform sdi_test.login(a);
 r:=sdi_private.room_snapshot('current',room);
 perform sdi_test.check(r->'snapshot'->>'sha256'=digest and r->'snapshot'->>'state'='available' and not (r->'snapshot'->>'received_by_me')::boolean
  and r->'snapshot'->'delivered'='null'::jsonb,'member sees the offer without delivery counts: '||r::text);
 got:=decode(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'data','base64')||decode(sdi_private.room_snapshot('get',room,snap,chunk_index=>1)->>'data','base64');
 perform sdi_test.check(got=bytes,'member reassembles identical bytes');
 perform sdi_test.check(sdi_private.room_snapshot('receipt',room,snap,sha256=>repeat('0',64))->>'error' like 'The receipt does not match%','mismatched receipt refused');
 r:=sdi_private.room_snapshot('receipt',room,snap,sha256=>digest);
 perform sdi_test.check(r->>'status'='recorded' and r->>'server_copy'='retained','first receipt keeps the copy for the other member: '||r::text);
 r:=sdi_private.room_snapshot('receipt',room,snap,sha256=>digest);
 perform sdi_test.check(r->>'status'='recorded','receipt is idempotent');
 perform sdi_test.check((select count(*) from sdi_private.room_snapshot_audit where snapshot_id=snap and event='downloaded')=1,'one download audit per member');
 perform sdi_test.check((sdi_private.room_snapshot('current',room)->'snapshot'->>'received_by_me')::boolean,'member sees own receipt');

 -- The last current member's receipt deletes the server copy with verification.
 perform sdi_test.login(b);
 got:=decode(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'data','base64')||decode(sdi_private.room_snapshot('get',room,snap,chunk_index=>1)->>'data','base64');
 perform sdi_test.check(got=bytes,'second member reassembles identical bytes');
 r:=sdi_private.room_snapshot('receipt',room,snap,sha256=>digest);
 perform sdi_test.check(r->>'server_copy'='deleted' and (r->>'verified')::boolean,'delivered to everyone: deleted: '||r::text);
 perform sdi_test.check((select state='deleted' and end_reason='delivered' and delete_verified from sdi_private.room_project_snapshots where id=snap),'delivered state recorded');
 perform sdi_test.check(not exists(select 1 from sdi_private.room_project_snapshot_chunks where snapshot_id=snap),'no bytes remain after delivery');
 perform sdi_test.check(sdi_private.room_snapshot('current',room)->'snapshot'='null'::jsonb,'nothing offered after delivery');
 perform sdi_test.check((select array_agg(event order by created_at,event) from sdi_private.room_snapshot_audit where snapshot_id=snap)
  =array['offered','downloaded','downloaded','delivered'],'audit trail');

 -- Revocation by the owner.
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('xyz'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode('xyz'::bytea,'base64'));
 perform sdi_private.room_snapshot('finalize',room,snap);
 perform sdi_test.login(a);
 perform sdi_test.check(sdi_private.room_snapshot('revoke',room,snap)->>'error' like 'Only the room owner%','members cannot revoke');
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('revoke',room,snap);
 perform sdi_test.check(r->>'status'='revoked' and (r->>'verified')::boolean,'owner revokes with verified deletion');
 perform sdi_test.login(a);
 perform sdi_test.check(sdi_private.room_snapshot('get',room,snap,chunk_index=>0)->>'error' like 'No shared project%','revoked snapshot not served');

 -- Replacement: a new offer discards the previous live snapshot.
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('one'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('two'::bytea,'sha256'),'hex'));
 perform sdi_test.check((r->>'snapshot_id')::uuid<>snap and (select end_reason from sdi_private.room_project_snapshots where id=snap)='replaced','replaced snapshot discarded');
 snap:=(r->>'snapshot_id')::uuid;

 -- Corrupt upload is rejected and discarded.
 r:=sdi_private.room_snapshot('offer',room,byte_size=>5,sha256=>repeat('0',64));
 bad:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',room,bad,chunk_index=>0,data=>encode('hello'::bytea,'base64'));
 r:=sdi_private.room_snapshot('finalize',room,bad);
 perform sdi_test.check(r->>'error' like 'The sent project was corrupt%','corrupt snapshot rejected');
 perform sdi_test.check((select end_reason='rejected' and delete_verified from sdi_private.room_project_snapshots where id=bad),'corrupt copy deleted and verified');

 -- Changing the shared project invalidates an offer.
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('pqr'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode('pqr'::bytea,'base64'));
 perform sdi_private.room_snapshot('finalize',room,snap);
 perform sdi_private.room_manage('set_project',room,project_ref=>'device-project:h2',project_title=>'Duel 2',permissions=>array['view'],revision=>2);
 perform sdi_test.logout();
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((r->>'snapshots_discarded')::int=1 and (r->>'snapshots_verified')::int=1 and (r->>'snapshots_unverified_total')::int=0,'sweep removes changed-project snapshot: '||r::text);
 perform sdi_test.check((select end_reason from sdi_private.room_project_snapshots where id=snap)='project_changed','project change reason');

 -- Expiry.
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('old'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode('old'::bytea,'base64'));
 perform sdi_private.room_snapshot('finalize',room,snap);
 update sdi_private.room_project_snapshots set expires_at=clock_timestamp()-interval '1 second' where id=snap;
 perform sdi_test.login(a);
 perform sdi_test.check(sdi_private.room_snapshot('current',room)->'snapshot'='null'::jsonb,'expired snapshot hidden');
 perform sdi_test.check((select end_reason from sdi_private.room_project_snapshots where id=snap)='expired','expired on access');

 -- Delivered to every current member when a remaining member leaves (sweep).
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('lvl'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_snapshot('put',room,snap,chunk_index=>0,data=>encode('lvl'::bytea,'base64'));
 perform sdi_private.room_snapshot('finalize',room,snap);
 perform sdi_test.login(a);
 perform sdi_test.check(sdi_private.room_snapshot('receipt',room,snap,sha256=>encode(extensions.digest('lvl'::bytea,'sha256'),'hex'))->>'server_copy'='retained','b still awaiting');
 perform sdi_test.login(owner); perform sdi_private.room_action('remove',room,b);
 perform sdi_test.logout();
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((r->>'snapshots_discarded')::int=1 and (select end_reason from sdi_private.room_project_snapshots where id=snap)='delivered','sweep deletes once every current member received');

 -- Closing the room ends the handoff.
 perform sdi_test.login(owner);
 r:=sdi_private.room_snapshot('offer',room,byte_size=>3,sha256=>encode(extensions.digest('end'::bytea,'sha256'),'hex'));
 snap:=(r->>'snapshot_id')::uuid;
 perform sdi_private.room_action('close',room);
 perform sdi_test.logout();
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((select end_reason from sdi_private.room_project_snapshots where id=snap)='room_closed','closed room snapshot swept');
 perform sdi_test.check(not exists(select 1 from sdi_private.room_project_snapshot_chunks c join sdi_private.room_project_snapshots x on x.id=c.snapshot_id where x.room_id=room),'no handoff bytes remain for the room');
 perform sdi_test.check(not exists(select 1 from sdi_private.room_snapshot_audit where room_id=room and event not in('offered','downloaded') and not verified),'every deletion verified');
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_room_asset_sweep(integer)','execute'),'sweep stays service-only');
end $$;
rollback;
