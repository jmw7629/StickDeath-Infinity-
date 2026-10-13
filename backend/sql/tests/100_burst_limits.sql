-- Burst fixtures for the documented per-minute caps (#263). Each block drives the
-- real RPC to its cap, asserts that the next call is refused with the documented
-- message, and that an expired window admits the member again. Runs on the
-- throwaway cluster only; nothing here sleeps, the window is moved by updating
-- the budget row the way time would.
begin;
do $$
declare member uuid; admin uuid; room uuid; r jsonb; i integer; refused integer;
begin
 member:=sdi_test.user('burst-member'); admin:=sdi_test.admin('burst-admin',false,array['moderation']);
 perform sdi_test.login(member);

 -- Feed listing: 60 per minute, then "Please wait".
 for i in 1..60 loop
  r:=sdi_private.feed_action('list');
  perform sdi_test.check(r->>'error' is null,'feed call '||i||' allowed: '||coalesce(r->>'error',''));
 end loop;
 r:=sdi_private.feed_action('list');
 perform sdi_test.check(r->>'error'='Please wait before trying again.','feed call 61 refused: '||r::text);
 update sdi_private.feed_budget set started_at=clock_timestamp()-interval '2 minutes' where actor=member;
 r:=sdi_private.feed_action('list');
 perform sdi_test.check(r->>'error' is null,'feed window expiry admits the member again');
 perform sdi_test.check((select attempts from sdi_private.feed_budget where actor=member)=1,'feed window restarted at one attempt');

 -- Challenges: 60 per minute.
 for i in 1..60 loop r:=sdi_private.challenge_action('list'); end loop;
 perform sdi_test.check(r->>'error' is null,'challenge call 60 allowed: '||coalesce(r->>'error',''));
 r:=sdi_private.challenge_action('list');
 perform sdi_test.check(r->>'error'='Too many requests. Wait a minute.','challenge call 61 refused: '||r::text);
 update sdi_private.challenge_budget set starts_at=clock_timestamp()-interval '2 minutes' where user_id=member;
 perform sdi_test.check((sdi_private.challenge_action('list')->>'error') is null,'challenge window expiry admits again');

 -- War Room: 60 per minute.
 for i in 1..60 loop r:=sdi_private.war_action('list'); end loop;
 perform sdi_test.check(r->>'error' is null,'war call 60 allowed: '||coalesce(r->>'error',''));
 r:=sdi_private.war_action('list');
 perform sdi_test.check(r->>'error'='Too many requests. Wait a minute.','war call 61 refused: '||r::text);
 update sdi_private.war_budget set starts_at=clock_timestamp()-interval '2 minutes' where user_id=member;
 perform sdi_test.check((sdi_private.war_action('list')->>'error') is null,'war window expiry admits again');

 -- Rooms: creation and management share one 30-per-minute budget.
 r:=sdi_private.room_action('create',title=>'Burst room',consent=>true); room:=(r->>'room_id')::uuid;
 perform sdi_test.check(room is not null,'room created: '||r::text);
 for i in 2..30 loop r:=sdi_private.room_manage('my_requests'); end loop;
 perform sdi_test.check(r->>'error' is null,'room request 30 allowed: '||coalesce(r->>'error',''));
 r:=sdi_private.room_manage('my_requests');
 perform sdi_test.check(r->>'error'='Too many requests. Wait a minute.','room request 31 refused: '||r::text);
 r:=sdi_private.room_action('invite',room);
 perform sdi_test.check(r->>'error'='Too many requests. Wait a minute.','invite shares the exhausted budget: '||r::text);
 update sdi_private.room_request_budget set window_start=clock_timestamp()-interval '2 minutes' where user_id=member;
 perform sdi_test.check((sdi_private.room_manage('my_requests')->>'error') is null,'room window expiry admits again');

 -- Room commands: 300 per minute per member, independent of the request budget.
 refused:=0;
 for i in 1..300 loop
  r:=sdi_private.room_command('since',room,after=>0);
  if r->>'error' is not null then refused:=refused+1; end if;
 end loop;
 perform sdi_test.check(refused=0,'300 room command calls allowed; refused '||refused||' last: '||r::text);
 r:=sdi_private.room_command('since',room,after=>0);
 perform sdi_test.check(r->>'error'='Too many edits per minute. Pause and resynchronize.','room command 301 refused: '||r::text);
 update sdi_private.room_command_budget set window_start=clock_timestamp()-interval '2 minutes' where user_id=member;
 perform sdi_test.check((sdi_private.room_command('since',room,after=>0)->>'error') is null,'command window expiry admits again');

 -- Administrative gate: 60 per minute per administrator, each refusal audited.
 perform sdi_test.login(admin,'aal2');
 for i in 1..60 loop r:=sdi_private.admin_gate('burst-fixture','moderation'); end loop;
 perform sdi_test.check(r is null,'admin gate call 60 allowed: '||coalesce(r::text,''));
 r:=sdi_private.admin_gate('burst-fixture','moderation');
 perform sdi_test.check(r->>'code'='rate_limited' and r->>'error'='Too many administrative requests. Wait a minute.','admin gate call 61 refused: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.admin_access_audit where actor=admin and operation='burst-fixture' and not allowed and detail='rate_limited')=1,'refusal audited once');
 r:=sdi_private.admin_gate('burst-fixture','moderation',false,10);
 perform sdi_test.check(r->>'code'='rate_limited','tighter limit refuses too');
 update sdi_private.admin_budget set window_start=clock_timestamp()-interval '2 minutes' where user_id=admin;
 perform sdi_test.check(sdi_private.admin_gate('burst-fixture','moderation') is null,'admin window expiry admits again');
end $$;
rollback;
