-- Local assertions for rooms-v2.sql: roles, versioned commands, reports, appeals.
begin;
do $$
declare owner uuid; editor uuid; viewer uuid; outsider uuid; admin uuid; admin2 uuid; room uuid; r jsonb; code text; op uuid:=gen_random_uuid(); report uuid;
begin
 owner:=sdi_test.user('room-owner'); editor:=sdi_test.user('room-editor'); viewer:=sdi_test.user('room-viewer'); outsider:=sdi_test.user('outsider');
 admin:=sdi_test.admin('room-mod',false,array['moderation']); admin2:=sdi_test.admin('room-mod2',false,array['moderation']);
 perform sdi_test.login(owner);
 r:=sdi_private.room_action('create',title=>'Shared short',consent=>true); room:=(r->>'room_id')::uuid;
 r:=sdi_private.room_action('invite',room); code:=r->>'code';
 perform sdi_test.check(length(code)=64,'invite code issued');
 -- Two members request through the code; owner approves both (mutual agreement).
 perform sdi_test.login(editor); r:=sdi_private.room_action('request',code=>code,consent=>true);
 perform sdi_test.check(r->>'status'='pending_owner_approval','editor request pending');
 perform sdi_test.login(viewer); r:=sdi_private.room_action('request',code=>code,consent=>true);
 r:=sdi_private.room_manage('my_requests');
 perform sdi_test.check(jsonb_array_length(r->'requests')=1 and (r->'requests'->0->>'room_id')::uuid=room,'pending request listed for the member: '||r::text);
 perform sdi_test.login(owner);
 perform sdi_test.check((sdi_private.room_action('approve',room,editor)->>'status')='updated','editor approved');
 perform sdi_test.check((sdi_private.room_action('approve',room,viewer)->>'status')='updated','viewer approved');
 perform sdi_test.login(viewer);
 r:=sdi_private.room_manage('my_requests');
 perform sdi_test.check(jsonb_array_length(r->'requests')=0,'approved request no longer pending');

 -- Project sharing and roles are owner-only; editor role needs edit permission.
 perform sdi_test.login(editor);
 r:=sdi_private.room_manage('set_project',room,project_ref=>'proj-1',project_title=>'Short',permissions=>array['view','edit'],revision=>1);
 perform sdi_test.check(r->>'error'='Only the owner can perform this operation.','member cannot share project');
 perform sdi_test.login(owner);
 r:=sdi_private.room_manage('set_role',room,editor,'editor');
 perform sdi_test.check(r->>'error' like 'Share the project with edit%','editor role needs edit permission first');
 r:=sdi_private.room_manage('set_project',room,project_ref=>'proj-1',project_title=>'Short',permissions=>array['view','edit'],revision=>1);
 perform sdi_test.check(r->>'status'='updated','owner shares project: '||r::text);
 r:=sdi_private.room_manage('set_project',room,project_ref=>'proj-2',project_title=>'Short',permissions=>array['view','edit'],revision=>1);
 perform sdi_test.check(r->>'error' is not null,'stale project revision refused');
 perform sdi_test.check((sdi_private.room_manage('set_role',room,editor,'editor')->>'status')='updated','editor role granted');
 perform sdi_test.check((sdi_private.room_manage('set_role',room,outsider,'editor')->>'error') is not null,'non-member cannot get a role');

 -- Versioned commands: viewer cannot append, editor can, conflicts are explicit, op ids are idempotent.
 perform sdi_test.login(viewer);
 r:=sdi_private.room_command('append',room,op,0,'frame.add','{"frame":1}');
 perform sdi_test.check(r->>'error' like 'You can view%','viewer cannot edit');
 perform sdi_test.login(editor);
 r:=sdi_private.room_command('append',room,op,0,'frame.add','{"frame":1}');
 perform sdi_test.check(r->>'status'='applied' and (r->>'revision')::bigint=1,'editor appends: '||r::text);
 r:=sdi_private.room_command('append',room,op,0,'frame.add','{"frame":1}');
 perform sdi_test.check(r->>'status'='duplicate' and (r->>'revision')::bigint=1,'duplicate op id is idempotent');
 perform sdi_test.login(owner);
 r:=sdi_private.room_command('append',room,gen_random_uuid(),0,'layer.add','{"layer":"ink"}');
 perform sdi_test.check(r->>'error'='conflict' and (r->>'head')::bigint=1 and jsonb_array_length(r->'missing')=1,'stale base revision surfaces the missing commands');
 r:=sdi_private.room_command('append',room,gen_random_uuid(),1,'layer.add','{"layer":"ink"}');
 perform sdi_test.check((r->>'revision')::bigint=2,'owner appends after catching up');
 perform sdi_test.login(viewer);
 r:=sdi_private.room_command('since',room,after=>0);
 perform sdi_test.check(jsonb_array_length(r->'commands')=2 and (r->>'head')::bigint=2,'viewer reads the command log');
 perform sdi_test.login(outsider);
 r:=sdi_private.room_command('since',room,after=>0);
 perform sdi_test.check(r->>'error'='Room is unavailable.','outsider cannot read commands');
 r:=sdi_private.room_manage('summary',room);
 perform sdi_test.check(r->>'error'='Room is unavailable.','outsider cannot read the project reference');
 perform sdi_test.login(viewer);
 r:=sdi_private.room_manage('summary',room);
 perform sdi_test.check(r->>'project_ref'='proj-1' and r->>'my_role'='viewer' and (r->>'can_edit')::boolean=false,'member summary: '||r::text);

 -- Revoked member loses access immediately.
 perform sdi_test.login(owner);
 perform sdi_private.room_action('remove',room,editor);
 perform sdi_test.login(editor);
 r:=sdi_private.room_command('append',room,gen_random_uuid(),2,'frame.add','{"frame":2}');
 perform sdi_test.check(r->>'error' is not null,'removed editor cannot append');

 -- Room report and admin queue; the involved administrator is excluded.
 perform sdi_test.login(viewer);
 r:=sdi_private.room_manage('report',room,reason=>'abuse',detail=>'Shared project contains harassment.');
 perform sdi_test.check(r->>'status'='recorded','room reported');
 select id into report from sdi_private.room_reports where room_id=room;
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.room_moderate('list');
 perform sdi_test.check(jsonb_array_length(r->'reports')=1 and (r->'reports'->0) ? 'detail' and not ((r->'reports'->0) ? 'reporter'),'queue lists report without reporter identity');
 perform sdi_test.login(admin);
 perform sdi_test.check((sdi_private.room_moderate('close',report,1,'Abusive content.')->>'error') is not null,'aal1 admin denied');
 perform sdi_test.login(admin,'aal2');
 perform sdi_test.check((sdi_private.room_moderate('close',report,1,'Abusive content.')->>'status')='confirmed','room closed by moderator');
 perform sdi_test.check((select closed from public.sdi_rooms where id=room),'room is closed');
 perform sdi_test.login(viewer);
 perform sdi_test.check((sdi_private.room_manage('summary',room)->>'error') is not null,'closed room unavailable to members');
end $$;

-- Feed removal appeal (problem 9).
do $$
declare creator uuid; reporter uuid; mod1 uuid; mod2 uuid; media uuid; the_post uuid; report uuid; appeal uuid; r jsonb;
begin
 creator:=sdi_test.user('appellant'); reporter:=sdi_test.user('reporter');
 mod1:=sdi_test.admin('remover',false,array['moderation']); mod2:=sdi_test.admin('appeal-reviewer',false,array['moderation']);
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('Clip','https://cdn.example.test/c.mp4',5,true,creator,repeat('c',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,creator,'appellant',true) returning id into the_post;
 perform sdi_test.login(reporter);
 perform sdi_private.feed_action('report',the_post,reason=>'rights');
 select id into report from sdi_private.feed_reports where feed_reports.post=the_post;
 perform sdi_test.login(mod1,'aal2');
 perform sdi_test.check((sdi_private.moderation_action('remove',report,1,'Rights complaint upheld.')->>'status')='confirmed','media removed');
 perform sdi_test.login(creator);
 r:=sdi_private.moderation_appeal('submit',media,'This is my own work; here is the project file hash.');
 perform sdi_test.check(jsonb_array_length(r->'appeals')=1 and r->'appeals'->0->>'state'='pending','appeal submitted: '||r::text);
 select id into appeal from sdi_private.moderation_appeals where media_id=media;
 perform sdi_test.login(reporter);
 r:=sdi_private.moderation_appeal('submit',media,'Not mine.');
 perform sdi_test.check(r->>'error' is not null,'only the owner can appeal');
 perform sdi_test.login(mod1,'aal2');
 r:=sdi_private.moderation_appeal('accept',null,'',appeal,1,'Restoring.');
 perform sdi_test.check(r->>'error' like 'Another uninvolved%','removing admin cannot decide the appeal');
 perform sdi_test.login(mod2,'aal2');
 r:=sdi_private.moderation_appeal('queue');
 perform sdi_test.check(jsonb_array_length(r->'appeals')=1 and r->'appeals'->0->>'removal_state'='pending','queue shows removal state');
 r:=sdi_private.moderation_appeal('accept',null,'',appeal,1,'Ownership evidence accepted.');
 perform sdi_test.check(r->>'status'='confirmed','appeal accepted: '||r::text);
 perform sdi_test.check((select approved from public.sdi_watch_media where id=media) and (select visible from sdi_private.feed_posts where id=the_post),'media and post restored');
 perform sdi_test.check((select state from sdi_private.removal_jobs where media_id=media)='withdrawn','removal job withdrawn');
 perform sdi_test.login(creator);
 r:=sdi_private.moderation_appeal('mine');
 perform sdi_test.check(r->'appeals'->0->>'state'='accepted' and r->'appeals'->0->>'reply'='Ownership evidence accepted.','member sees the decision');
end $$;
rollback;
