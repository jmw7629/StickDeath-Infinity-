-- Local assertions for challenges.sql (lifecycle, calendar) and achievements.sql (idempotent awards).
begin;
do $$
declare a uuid; b uuid; voter uuid; admin uuid; media_a uuid; media_b uuid; ch uuid; entry_a uuid; entry_b uuid; r jsonb;
begin
 a:=sdi_test.user('entrant-a'); b:=sdi_test.user('entrant-b'); voter:=sdi_test.user('challenge-voter');
 admin:=sdi_test.admin('challenge-admin',false,array['moderation']);
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('A clip','https://cdn.example.test/a1.mp4',8,true,a,repeat('a',64)) returning id into media_a;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('B clip','https://cdn.example.test/b1.mp4',9,true,b,repeat('b',64)) returning id into media_b;

 perform sdi_test.login(a);
 r:=sdi_private.challenge_action('create',title=>'Walk cycle week');
 perform sdi_test.check(r->>'error' like 'Challenge administration%','members cannot create challenges');
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.challenge_action('create',title=>'Walk cycle week',brief=>'Animate a walk cycle.',reward=>'');
 perform sdi_test.check(r->>'status'='created','admin creates draft: '||r::text); ch:=(r->>'challenge_id')::uuid;
 r:=sdi_private.challenge_action('schedule',ch,revision=>1,starts_at=>clock_timestamp()+interval '1 hour',closes_at=>clock_timestamp()+interval '90 minutes',ends_at=>clock_timestamp()+interval '2 hours');
 perform sdi_test.check(r->>'error' is not null,'too-short windows refused');
 r:=sdi_private.challenge_action('schedule',ch,revision=>1,starts_at=>clock_timestamp()+interval '1 hour',closes_at=>clock_timestamp()+interval '1 day',ends_at=>clock_timestamp()+interval '2 days');
 perform sdi_test.check(r->>'status'='confirmed','scheduled: '||r::text);

 perform sdi_test.login(a);
 r:=sdi_private.challenge_action('list');
 perform sdi_test.check(r->'challenges'->0->>'phase'='upcoming','listed as upcoming');
 r:=sdi_private.challenge_action('submit',ch,media_a);
 perform sdi_test.check(r->>'error'='Submissions are not open.','no entries before start');
 update sdi_private.challenges set starts_at=clock_timestamp()-interval '1 hour' where id=ch;   -- server time moves the phase
 r:=sdi_private.challenge_action('submit',ch,media_b);
 perform sdi_test.check(r->>'error' like 'Select your approved%','cannot enter someone else''s video');
 r:=sdi_private.challenge_action('submit',ch,media_a);
 perform sdi_test.check(r->>'status'='entered','own approved video entered');
 r:=sdi_private.challenge_action('submit',ch,media_a);
 perform sdi_test.check(r->>'error' like 'One entry per creator%','one entry policy');
 perform sdi_test.login(b);
 perform sdi_test.check((sdi_private.challenge_action('submit',ch,media_b)->>'status')='entered','second entrant');
 select id into entry_a from sdi_private.challenge_entries where challenge_id=ch and creator=a;
 select id into entry_b from sdi_private.challenge_entries where challenge_id=ch and creator=b;
 perform sdi_test.login(voter);
 r:=sdi_private.challenge_action('vote',ch,entry=>entry_a);
 perform sdi_test.check(r->>'error'='Voting is not open.','no voting during submissions');
 r:=sdi_private.challenge_action('entries',ch);
 perform sdi_test.check(jsonb_array_length(r->'entries')=2 and (r->'entries'->0->'votes') = 'null'::jsonb,'entries visible, counts hidden before voting');
 update sdi_private.challenges set submissions_close_at=clock_timestamp()-interval '1 minute' where id=ch;
 perform sdi_test.check((sdi_private.challenge_action('vote',ch,entry=>entry_a)->>'status')='confirmed','voter votes');
 perform sdi_test.check((sdi_private.challenge_action('vote',ch,entry=>entry_b)->>'status')='confirmed','vote is mutable');
 perform sdi_test.check((select count(*) from sdi_private.challenge_votes where challenge_id=ch)=1,'one vote per voter');
 perform sdi_test.login(a);
 r:=sdi_private.challenge_action('vote',ch,entry=>entry_b);
 perform sdi_test.check(r->>'error' like 'Participants cannot vote%','entrants cannot vote');
 perform sdi_test.login(voter);
 r:=sdi_private.calendar_range(clock_timestamp()-interval '1 day',clock_timestamp()+interval '30 days');
 perform sdi_test.check((r->'items') @> jsonb_build_array(jsonb_build_object('kind','challenge','milestone','voting_ends','id',ch)),'calendar lists the voting deadline: '||r::text);
 r:=sdi_private.calendar_range(clock_timestamp(),clock_timestamp()+interval '90 days');
 perform sdi_test.check(r->>'error' is not null,'range beyond sixty-two days refused');
 update sdi_private.challenges set voting_ends_at=clock_timestamp()-interval '1 second' where id=ch;
 r:=sdi_private.challenge_finalize();
 perform sdi_test.check((r->>'completed')::integer=1,'finalized one challenge');
 perform sdi_test.check((select outcome from sdi_private.challenge_results where challenge_id=ch)='winner' and (select winner_entry from sdi_private.challenge_results where challenge_id=ch)=entry_b,'winner recorded from votes');
 perform sdi_test.check((sdi_private.challenge_finalize()->>'completed')::integer=0,'finalization idempotent');
 r:=sdi_private.award_pending();
 perform sdi_test.check((r->>'awarded')::integer=1,'challenge winner badge awarded once: '||r::text);
 perform sdi_test.check((sdi_private.award_pending()->>'awarded')::integer=0,'challenge badge sweep idempotent');
 perform sdi_test.login(b);
 r:=sdi_private.achievement_catalog();
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'achievements') e where e->>'badge_key'='challenge_first_win' and e->>'earned_at' is not null)=1,'winner sees the earned badge');
 perform sdi_test.login(a);
 r:=sdi_private.achievement_catalog();
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'achievements') e where e->>'earned_at' is not null)=0,'runner-up sees only locked badges');
end $$;

-- War Room result awards are idempotent per source event and cover both participants.
do $$
declare a uuid; b uuid; media_a uuid; media_b uuid; match uuid; r jsonb;
begin
 a:=sdi_test.user('war-a'); b:=sdi_test.user('war-b');
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('A','https://cdn.example.test/wa.mp4',8,true,a,repeat('d',64)) returning id into media_a;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('B','https://cdn.example.test/wb.mp4',8,true,b,repeat('e',64)) returning id into media_b;
 insert into sdi_private.war_matches(creator,opponent,left_media,right_media,left_digest,right_digest,status,starts_at,ends_at)
 values(a,b,media_a,media_b,repeat('d',64),repeat('e',64),'active',clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day') returning id into match;
 r:=sdi_private.award_from_war_result(match);
 perform sdi_test.check(r->>'error' is not null,'unfinalized match awards nothing');
 r:=sdi_private.war_finalize();
 perform sdi_test.check((r->>'completed')::integer=1,'match finalized as a tie');
 r:=sdi_private.award_from_war_result(match);
 perform sdi_test.check((r->>'awarded')::integer=2,'both participants earn First Matchup: '||r::text);
 r:=sdi_private.award_from_war_result(match);
 perform sdi_test.check((r->>'duplicate')::boolean and (r->>'awarded')::integer=0,'re-award of the same event is a no-op');
 perform sdi_test.check((select count(*) from sdi_private.earned_badges where user_id in(a,b))=2,'exactly two badges exist');
 perform sdi_test.check((select count(*) from sdi_private.earned_badges where badge_key='war_first_win')=0,'a tie awards no win badge');
 perform sdi_test.check((sdi_private.award_pending()->>'processed')::integer=0,'sweep finds nothing unprocessed');
end $$;
rollback;
