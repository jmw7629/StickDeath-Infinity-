-- Local assertions for the rooms v2.1 block of rooms-v2.sql: server-side rebase
-- of concurrent commands, undo ownership, and bounded asset transfer with
-- quotas, resume, corruption rejection and verified cleanup (#232, #233).
begin;
do $$
declare owner uuid; editor uuid; viewer uuid; outsider uuid; room uuid; r jsonb; code text;
 op1 uuid:=gen_random_uuid(); op2 uuid:=gen_random_uuid(); op3 uuid:=gen_random_uuid();
 bytes bytea; digest text; asset uuid; bad uuid; small uuid; got bytea;
begin
 owner:=sdi_test.user('asset-owner'); editor:=sdi_test.user('asset-editor'); viewer:=sdi_test.user('asset-viewer'); outsider:=sdi_test.user('asset-outsider');
 perform sdi_test.login(owner);
 room:=(sdi_private.room_action('create',title=>'Asset room',consent=>true)->>'room_id')::uuid;
 code:=sdi_private.room_action('invite',room)->>'code';
 perform sdi_test.login(editor); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(viewer); perform sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.login(owner);
 perform sdi_private.room_action('approve',room,editor); perform sdi_private.room_action('approve',room,viewer);

 -- Assets need a shared project first.
 perform sdi_test.login(owner);
 r:=sdi_private.room_asset('declare',room,name=>'early.png',mime=>'image/png',byte_size=>10,sha256=>repeat('a',64),license=>'own-work');
 perform sdi_test.check(r->>'error' like 'Share a project%','no assets before a project is shared: '||r::text);
 perform sdi_private.room_manage('set_project',room,project_ref=>'device-project:x',project_title=>'Short',permissions=>array['view','edit'],revision=>1);
 perform sdi_private.room_manage('set_role',room,editor,'editor');

 -- Rebase: disjoint targets apply on top of a stale base; overlapping or
 -- untargeted edits stay explicit conflicts.
 perform sdi_test.login(editor);
 r:=sdi_private.room_command('append',room,op1,0,'frame.update','{"target":"frame:a","x":1}');
 perform sdi_test.check(r->>'status'='applied' and (r->>'revision')::int=1,'editor edits frame a: '||r::text);
 perform sdi_test.login(owner);
 r:=sdi_private.room_command('append',room,op2,0,'frame.update','{"target":"frame:b","x":2}');
 perform sdi_test.check(r->>'status'='rebased' and (r->>'revision')::int=2 and jsonb_array_length(r->'missing')=1,'disjoint edit rebased: '||r::text);
 perform sdi_test.login(editor);
 r:=sdi_private.room_command('append',room,gen_random_uuid(),1,'frame.update','{"target":"frame:b","x":3}');
 perform sdi_test.check(r->>'error'='conflict' and (r->'overlap'->>0)::uuid=op2,'overlapping edit is a conflict naming the other edit: '||r::text);
 r:=sdi_private.room_command('append',room,gen_random_uuid(),1,'layer.reorder','{"order":[1,2]}');
 perform sdi_test.check(r->>'error'='conflict','untargeted stale edit is a conflict');
 r:=sdi_private.room_command('append',room,gen_random_uuid(),9,'frame.update','{"target":"frame:c"}');
 perform sdi_test.check(r->>'error' like 'Base revision is ahead%','future base refused');
 r:=sdi_private.room_command('append',room,gen_random_uuid(),2,'frame.update','{"target":7}');
 perform sdi_test.check(r->>'error' is not null,'non-string target refused');

 -- Undo ownership.
 perform sdi_test.login(owner);
 r:=sdi_private.room_command('append',room,gen_random_uuid(),2,'undo',jsonb_build_object('undo_op',op1));
 perform sdi_test.check(r->>'error'='You can undo only your own edits.','owner cannot undo the editor''s edit');
 perform sdi_test.login(editor);
 r:=sdi_private.room_command('append',room,op3,2,'undo',jsonb_build_object('undo_op',op1));
 perform sdi_test.check(r->>'status'='applied' and (r->>'revision')::int=3,'editor undoes own edit: '||r::text);
 perform sdi_test.check((select target from sdi_private.room_commands where op_id=op3)='frame:a','undo inherits the undone target');
 r:=sdi_private.room_command('append',room,gen_random_uuid(),3,'undo',jsonb_build_object('undo_op',op1));
 perform sdi_test.check(r->>'error'='That edit was already undone.','undo happens once');
 r:=sdi_private.room_command('append',room,gen_random_uuid(),3,'undo',jsonb_build_object('undo_op','not-a-uuid'));
 perform sdi_test.check(r->>'error' like 'Undo needs%','malformed undo refused');
 r:=sdi_private.room_command('since',room,after=>2);
 perform sdi_test.check(r->'commands'->0->>'undoes'=op1::text and r->'commands'->0->>'target'='frame:a','since returns target and undo link');

 -- Asset declaration rules and quotas.
 bytes:=convert_to(repeat('stick',8000),'UTF8');  -- 40000 bytes: two chunks
 digest:=encode(extensions.digest(bytes,'sha256'),'hex');
 perform sdi_test.login(viewer);
 r:=sdi_private.room_asset('declare',room,name=>'v.png',mime=>'image/png',byte_size=>40000,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'error' like 'Only editors%','viewers cannot send assets');
 perform sdi_test.login(editor);
 r:=sdi_private.room_asset('declare',room,name=>'big.png',mime=>'image/png',byte_size=>9000000,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'error' is not null,'files over 8 MB refused');
 r:=sdi_private.room_asset('declare',room,name=>'clip.mov',mime=>'video/quicktime',byte_size=>100,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'error' is not null,'video and other types refused');
 r:=sdi_private.room_asset('declare',room,name=>'cc.png',mime=>'image/png',byte_size=>40000,sha256=>digest,license=>'cc-by');
 perform sdi_test.check(r->>'error' is not null,'CC BY needs attribution');
 r:=sdi_private.room_asset('declare',room,name=>'punch.png',mime=>'image/png',byte_size=>40000,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'status'='declared' and (r->>'chunk_count')::int=2 and (r->>'chunk_size')::int=32768,'declared: '||r::text);
 asset:=(r->>'asset_id')::uuid;
 r:=sdi_private.room_asset('declare',room,name=>'punch.png',mime=>'image/png',byte_size=>40000,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'status'='existing' and (r->>'asset_id')::uuid=asset,'same file deduplicated');

 perform sdi_test.login(owner);
 r:=sdi_private.room_asset('declare',room,name=>'punch.png',mime=>'image/png',byte_size=>40000,sha256=>digest,license=>'own-work');
 perform sdi_test.check(r->>'error'='Another member is already sending this file.','in-progress copy is not handed to another member');
 perform sdi_test.login(editor);

 -- Chunked transfer with resume.
 r:=sdi_private.room_asset('put',room,asset,chunk_index=>0,data=>encode(substring(bytes from 1 for 1000),'base64'));
 perform sdi_test.check(r->>'error' like 'Chunk length%','short chunk refused');
 r:=sdi_private.room_asset('put',room,asset,chunk_index=>0,data=>'%%%not base64');
 perform sdi_test.check(r->>'error' is not null,'invalid base64 refused');
 r:=sdi_private.room_asset('put',room,asset,chunk_index=>0,data=>encode(substring(bytes from 1 for 32768),'base64'));
 perform sdi_test.check(r->>'status'='stored' and (r->>'received')::int=1,'chunk 0 stored: '||r::text);
 perform sdi_test.login(viewer);
 r:=sdi_private.room_asset('get',room,asset,chunk_index=>0);
 perform sdi_test.check(r->>'error'='Asset is unavailable.','incomplete asset not downloadable');
 r:=sdi_private.room_asset('list',room);
 perform sdi_test.check(jsonb_array_length(r->'assets')=0,'others do not see an incomplete asset');
 perform sdi_test.login(editor);
 r:=sdi_private.room_asset('finalize',room,asset);
 perform sdi_test.check(r->>'error'='incomplete' and r->'received'='[0]'::jsonb,'finalize reports missing chunks: '||r::text);
 r:=sdi_private.room_asset('status',room,asset);
 perform sdi_test.check(r->'received'='[0]'::jsonb and r->>'state'='receiving','status supports resume');
 r:=sdi_private.room_asset('put',room,asset,chunk_index=>1,data=>encode(substring(bytes from 32769),'base64'));
 perform sdi_test.check((r->>'received')::int=2,'chunk 1 stored');
 r:=sdi_private.room_asset('finalize',room,asset);
 perform sdi_test.check(r->>'status'='available','server verified the hash: '||r::text);
 perform sdi_test.check((select expires_at from sdi_private.room_assets where id=asset)<=clock_timestamp()+interval '72 hours','bounded retention');
 r:=sdi_private.room_asset('put',room,asset,chunk_index=>0,data=>encode(substring(bytes from 1 for 32768),'base64'));
 perform sdi_test.check(r->>'error' is not null,'available asset is immutable');

 -- Download by another member; outsiders see nothing.
 perform sdi_test.login(viewer);
 r:=sdi_private.room_asset('list',room);
 perform sdi_test.check(jsonb_array_length(r->'assets')=1 and r->'assets'->0->>'sha256'=digest and r->'assets'->0->>'license'='own-work','member lists the asset: '||r::text);
 got:=decode(sdi_private.room_asset('get',room,asset,chunk_index=>0)->>'data','base64')||decode(sdi_private.room_asset('get',room,asset,chunk_index=>1)->>'data','base64');
 perform sdi_test.check(got=bytes,'member reassembles identical bytes');
 perform sdi_test.login(outsider);
 perform sdi_test.check(sdi_private.room_asset('get',room,asset,chunk_index=>0)->>'error'='Room is unavailable.','outsider cannot download');
 perform sdi_test.check(sdi_private.room_asset('list',room)->>'error'='Room is unavailable.','outsider cannot list');

 -- Corrupt upload: hash mismatch is discarded with verified cleanup.
 perform sdi_test.login(editor);
 r:=sdi_private.room_asset('declare',room,name=>'kick.wav',mime=>'audio/wav',byte_size=>5,sha256=>repeat('0',64),license=>'cc0');
 bad:=(r->>'asset_id')::uuid;
 perform sdi_private.room_asset('put',room,bad,chunk_index=>0,data=>encode('hello'::bytea,'base64'));
 r:=sdi_private.room_asset('finalize',room,bad);
 perform sdi_test.check(r->>'error' like 'The transferred file was corrupt%','corrupt transfer rejected');
 perform sdi_test.check((select state='deleted' and end_reason='rejected' and delete_verified from sdi_private.room_assets where id=bad),'corrupt copy deleted and verified');
 perform sdi_test.check(not exists(select 1 from sdi_private.room_asset_chunks where asset_id=bad),'no corrupt bytes remain');

 -- Cancel: the sender withdraws an in-progress transfer.
 r:=sdi_private.room_asset('declare',room,name=>'tiny.png',mime=>'image/png',byte_size=>3,sha256=>encode(extensions.digest('abc'::bytea,'sha256'),'hex'),license=>'own-work');
 small:=(r->>'asset_id')::uuid;
 perform sdi_private.room_asset('put',room,small,chunk_index=>0,data=>encode('abc'::bytea,'base64'));
 r:=sdi_private.room_asset('withdraw',room,small);
 perform sdi_test.check(r->>'status'='withdrawn' and (r->>'verified')::boolean,'withdrawal deletes and verifies');
 perform sdi_test.login(viewer);
 perform sdi_test.check(sdi_private.room_asset('withdraw',room,asset)->>'error' like 'Only the sender%','viewer cannot withdraw someone else''s asset');

 -- Membership ends: the asset disappears at once and the sweep deletes it.
 perform sdi_test.login(owner);
 perform sdi_private.room_action('remove',room,editor);
 perform sdi_test.login(viewer);
 perform sdi_test.check(jsonb_array_length(sdi_private.room_asset('list',room)->'assets')=0,'removed sender''s asset hidden immediately');
 perform sdi_test.check(sdi_private.room_asset('get',room,asset,chunk_index=>0)->>'error'='Asset is unavailable.','removed sender''s asset not downloadable');
 perform sdi_test.logout();
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_room_asset_sweep(integer)','execute')
  and has_function_privilege('service_role','public.sdi_room_asset_sweep(integer)','execute'),'sweep is service-only');
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((r->>'discarded')::int=1 and (r->>'verified')::int=1 and (r->>'unverified_total')::int=0,'sweep discards with verification: '||r::text);
 perform sdi_test.check((select end_reason from sdi_private.room_assets where id=asset)='membership_ended','reason recorded');
 perform sdi_test.check(not exists(select 1 from sdi_private.room_asset_chunks where asset_id=asset),'no bytes remain after sweep');
 perform sdi_test.check((select count(*) from sdi_private.room_asset_cleanup_audit where room_id=room)=3,'every discard audited');

 -- Expiry: an owner's available asset past its retention is swept.
 perform sdi_test.login(owner);
 r:=sdi_private.room_asset('declare',room,name=>'old.png',mime=>'image/png',byte_size=>3,sha256=>encode(extensions.digest('xyz'::bytea,'sha256'),'hex'),license=>'own-work');
 small:=(r->>'asset_id')::uuid;
 perform sdi_private.room_asset('put',room,small,chunk_index=>0,data=>encode('xyz'::bytea,'base64'));
 perform sdi_test.check(sdi_private.room_asset('finalize',room,small)->>'status'='available','owner asset available');
 update sdi_private.room_assets set expires_at=clock_timestamp()-interval '1 second' where id=small;
 perform sdi_test.check(sdi_private.room_asset('get',room,small,chunk_index=>0)->>'error'='Asset is unavailable.','expired asset not served');
 perform sdi_test.logout();
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((r->>'discarded')::int=1 and (select end_reason from sdi_private.room_assets where id=small)='expired','expired copy swept');

 -- Closing the room ends every transfer.
 perform sdi_test.login(owner);
 r:=sdi_private.room_asset('declare',room,name=>'last.png',mime=>'image/png',byte_size=>3,sha256=>encode(extensions.digest('qrs'::bytea,'sha256'),'hex'),license=>'own-work');
 small:=(r->>'asset_id')::uuid;
 perform sdi_private.room_action('close',room);
 perform sdi_test.logout();
 r:=sdi_private.room_asset_sweep(100);
 perform sdi_test.check((select end_reason from sdi_private.room_assets where id=small)='room_closed','closed room copies swept');
end $$;
rollback;
