-- Local assertions for the merch interest poll (merch-interest.sql, owner decision
-- 2026-10-15): the anon role reaches exactly the read/vote/suggest wrappers; one
-- changeable vote per voter per target; browser keys are stored only as salted hashes;
-- only approved ideas are public; per-key, global and daily limits; moderation needs the
-- moderation capability with MFA and step-up; totals are counted from stored votes only.
begin;
-- The assertion helper runs while the transaction is switched to the anon role.
grant usage on schema sdi_test to anon;
do $$
declare k1 uuid:=gen_random_uuid(); k2 uuid:=gen_random_uuid(); k3 uuid:=gen_random_uuid(); r jsonb; t jsonb; bad text;
 fan uuid; moderator uuid; idea uuid; idea2 uuid; rev bigint; i integer; anon_private text[];
begin
 -- Surface: anon executes exactly three sdi_private bodies and no table is readable.
 select coalesce(array_agg(p.proname::text order by p.proname),'{}') into anon_private from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='sdi_private' and has_function_privilege('anon',p.oid,'execute');
 perform sdi_test.check(anon_private=array['merch_suggest','merch_totals','merch_vote'],'anon private surface: '||array_to_string(anon_private,','));
 perform sdi_test.check(sdi_test.denied('anon','select count(*) from sdi_private.merch_votes'),'anon cannot read votes');
 perform sdi_test.check(sdi_test.denied('anon','select count(*) from sdi_private.merch_ideas'),'anon cannot read ideas');
 perform sdi_test.check(sdi_test.denied('anon','select count(*) from sdi_private.merch_settings'),'anon cannot read the salt');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_merch_moderate(''results'')'),'anon cannot moderate');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_merch_retention()'),'anon cannot run retention');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_merch_retention()'),'members cannot run retention');

 -- Empty state: the store poll and all 22 concepts, every count zero, no ideas.
 perform sdi_test.logout();
 set local role anon;
 r:=public.sdi_merch_totals(k1);
 reset role;
 perform sdi_test.check(jsonb_array_length(r->'targets')=23 and r->'targets'->0->>'kind'='store','store plus 22 concepts: '||left(r::text,200));
 perform sdi_test.check(not exists(select 1 from jsonb_array_elements(r->'targets') e where (e->>'up')::int<>0 or (e->>'down')::int<>0),'no invented counts');
 perform sdi_test.check(r->'ideas'='[]'::jsonb and r->'mine'='{}'::jsonb and (r->>'voting_open')::boolean,'no ideas, no votes yet');

 -- Votes: a key is required; one vote per key per target, changeable and removable.
 set local role anon;
 r:=public.sdi_merch_vote('store','open-store',1,null);
 perform sdi_test.check(r->>'code'='no_voter','a voter key is required');
 r:=public.sdi_merch_vote('store','open-store',1,k1);
 perform sdi_test.check(r->>'status'='recorded' and (r->'counts'->>'up')::int=1,'first up vote: '||r::text);
 r:=public.sdi_merch_vote('store','open-store',1,k1);
 perform sdi_test.check((r->'counts'->>'up')::int=1,'repeat vote counts once');
 r:=public.sdi_merch_vote('store','open-store',-1,k1);
 perform sdi_test.check((r->'counts'->>'up')::int=0 and (r->'counts'->>'down')::int=1,'vote changed to down');
 r:=public.sdi_merch_vote('store','open-store',1,k2);
 perform sdi_test.check((r->'counts'->>'up')::int=1 and (r->'counts'->>'down')::int=1 and (r->'counts'->>'member_up')::int=0,'second browser counted as anonymous');
 r:=public.sdi_merch_vote('concept','swat-cap',1,k1);
 perform sdi_test.check(r->>'status'='recorded','concept vote');
 r:=public.sdi_merch_vote('concept','not-a-design',1,k1);
 perform sdi_test.check(r->>'error'='Unknown vote target.','unknown concept refused');
 r:=public.sdi_merch_vote('store','close-store',1,k1);
 perform sdi_test.check(r->>'error'='Unknown vote target.','unknown poll refused');
 r:=public.sdi_merch_vote('store','open-store',2,k1);
 perform sdi_test.check(r ? 'error','vote weight above one refused');
 r:=public.sdi_merch_totals(k1);
 reset role;
 perform sdi_test.check((r->'mine'->>'store:open-store')::int=-1 and (r->'mine'->>'concept:swat-cap')::int=1,'own votes returned: '||(r->'mine')::text);
 perform sdi_test.check(not exists(select 1 from sdi_private.merch_votes where voter like '%'||replace(k1::text,'-','')||'%' or voter like '%'||k1::text||'%'),'raw browser key never stored');
 perform sdi_test.check((select count(*) from sdi_private.merch_votes where voter ~ '^k:[0-9a-f]{64}$')=3,'anonymous voters stored as HMAC digests');
 set local role anon;
 r:=public.sdi_merch_vote('store','open-store',0,k1);
 reset role;
 perform sdi_test.check((r->'counts'->>'down')::int=0 and (r->'counts'->>'up')::int=1 and r->>'mine'='0','vote cleared');

 -- Members vote as their account and are counted apart; an ended session cannot fall back to a key.
 fan:=sdi_test.user('merch-member');
 perform sdi_test.login(fan);
 r:=sdi_private.merch_vote('store','open-store',1,k3);
 perform sdi_test.check((r->'counts'->>'up')::int=2 and (r->'counts'->>'member_up')::int=1,'member vote counted: '||r::text);
 perform sdi_test.check(exists(select 1 from sdi_private.merch_votes where voter_user=fan and member),'stored against the account');
 delete from auth.sessions where user_id=fan;
 r:=sdi_private.merch_vote('store','open-store',-1,k3);
 perform sdi_test.check(r->>'code'='no_voter','inactive session cannot vote');
 perform sdi_test.logout();

 -- Ideas: validated, pending until approved, idempotent, limited per day.
 set local role anon;
 r:=public.sdi_merch_suggest('Hi','A design with a long enough description.',null,gen_random_uuid(),k1);
 perform sdi_test.check(r->>'error' like 'Give the idea%','short title refused');
 r:=public.sdi_merch_suggest('Link spam','Buy at https://example.com today please',null,gen_random_uuid(),k1);
 perform sdi_test.check(r->>'error' like 'Leave out links%','links refused');
 r:=public.sdi_merch_suggest('<b>Bold</b>','Markup should never be stored here.',null,gen_random_uuid(),k1);
 perform sdi_test.check(r->>'error' like 'Use plain text%','angle brackets refused');
 r:=public.sdi_merch_suggest('Glow tee','Glow in the dark Super Beast eyes.','bad handle!',gen_random_uuid(),k1);
 perform sdi_test.check(r->>'error' like 'A handle is%','invalid handle refused');
 r:=public.sdi_merch_suggest('Glow tee',E'Glow in the dark Super Beast eyes.\nBlack shirt.','@stickfan_99','00000000-0000-4000-8000-000000000001',k1);
 perform sdi_test.check(r->>'status'='pending','idea pending: '||r::text); idea:=(r->>'id')::uuid;
 r:=public.sdi_merch_suggest('Glow tee',E'Glow in the dark Super Beast eyes.\nBlack shirt.','@stickfan_99','00000000-0000-4000-8000-000000000001',k1);
 perform sdi_test.check(r->>'status'='duplicate' and (r->>'id')::uuid=idea,'retry is idempotent');
 r:=public.sdi_merch_suggest('Stickzilla plush','A soft Stickzilla plush with felt spikes.',null,gen_random_uuid(),k1);
 idea2:=(r->>'id')::uuid;
 r:=public.sdi_merch_suggest('Greenville sign','A metal Greenville road sign replica.',null,gen_random_uuid(),k1);
 perform sdi_test.check(r->>'status'='pending','third idea accepted');
 r:=public.sdi_merch_suggest('Fourth idea','Daily limit should stop this one.',null,gen_random_uuid(),k1);
 perform sdi_test.check(r->>'code'='rate_limited','fourth idea in a day refused');
 r:=public.sdi_merch_vote('idea',idea::text,1,k2);
 perform sdi_test.check(r->>'error'='Unknown vote target.','pending ideas cannot be voted on');
 r:=public.sdi_merch_totals(k2);
 reset role;
 perform sdi_test.check(r->'ideas'='[]'::jsonb,'pending ideas are not public');
 perform sdi_test.check((select handle from sdi_private.merch_ideas where id=idea)='stickfan_99','handle stored without the @');

 -- Moderation: capability, MFA and step-up; approval publishes, rejection removes votes.
 perform sdi_test.login(fan,'aal2');
 r:=sdi_private.merch_moderate('queue');
 perform sdi_test.check(r->>'code'='forbidden','members cannot see the queue');
 moderator:=sdi_test.admin('merch-mod',false,array['moderation']);
 perform sdi_test.login(moderator,'aal2');
 r:=sdi_private.merch_moderate('queue');
 perform sdi_test.check(jsonb_array_length(r->'ideas')=3 and r->'ideas'->0->>'submitter_kind'='anonymous' and not (r->'ideas'->0 ? 'submitter'),'queue lists pending ideas without identity: '||left(r::text,200));
 select revision into rev from sdi_private.merch_ideas where id=idea;
 r:=sdi_private.merch_moderate('decide',idea,'approved','Nice.',rev);
 perform sdi_test.check(r->>'code'='step_up_required','decision needs a recent second factor');
 perform sdi_test.login(moderator,'aal2',60);
 r:=sdi_private.merch_moderate('decide',idea,'approved','Nice.',rev+5);
 perform sdi_test.check(r ? 'error','stale revision refused');
 r:=sdi_private.merch_moderate('decide',idea,'approved','Nice.',rev);
 perform sdi_test.check(r->>'status'='confirmed','approved: '||r::text);
 perform sdi_test.check(exists(select 1 from sdi_private.admin_access_audit where actor=moderator and operation='merch_moderate.decide' and allowed),'decision audited');
 perform sdi_test.logout();
 set local role anon;
 r:=public.sdi_merch_vote('idea',idea::text,1,k2);
 perform sdi_test.check(r->>'status'='recorded','approved idea votable');
 r:=public.sdi_merch_totals(k2);
 reset role;
 perform sdi_test.check(jsonb_array_length(r->'ideas')=1 and r->'ideas'->0->>'title'='Glow tee' and (r->'ideas'->0->>'up')::int=1 and r->'ideas'->0->>'handle'='stickfan_99','approved idea listed with its count');
 perform sdi_test.check(not (r->'ideas'->0 ? 'submitter'),'submitter never public');
 perform sdi_test.login(moderator,'aal2',60);
 select revision into rev from sdi_private.merch_ideas where id=idea;
 r:=sdi_private.merch_moderate('decide',idea,'rejected','Changed our mind.',rev);
 perform sdi_test.check(r->>'status'='confirmed' and not exists(select 1 from sdi_private.merch_votes where target_kind='idea' and target_key=idea::text),'rejection removes the idea and its votes');
 r:=sdi_private.merch_moderate('results');
 perform sdi_test.check((r->'ideas'->>'rejected')::int=1 and (r->'ideas'->>'pending')::int=2 and (r->>'distinct_members')::int=1,'results summary: '||left(r::text,300));
 select e.value into t from jsonb_array_elements(r->'targets') e where e.value->>'kind'='store';
 perform sdi_test.check((t->>'up')::int=2 and (t->>'member_up')::int=1 and t->>'title'='Open the SDI merch store','store poll result: '||t::text);
 -- Settings: closing voting is a step-up change with a revision check.
 r:=sdi_private.merch_moderate('settings',null,null,'',(select revision from sdi_private.merch_settings),0,'pending',false,null);
 perform sdi_test.check(r->>'status'='confirmed','voting closed');
 perform sdi_test.logout();
 set local role anon;
 r:=public.sdi_merch_vote('store','open-store',1,k3);
 reset role;
 perform sdi_test.check(r->>'code'='closed','closed poll refuses votes');
 update sdi_private.merch_settings set voting_open=true;

 -- Per-key budget (30 a minute) and the global anonymous budget.
 set local role anon;
 for i in 1..30 loop r:=public.sdi_merch_vote('concept','swat-tee',case when i%2=0 then 1 else -1 end,k3); end loop;
 perform sdi_test.check(r->>'status'='recorded','30 actions in a minute allowed');
 r:=public.sdi_merch_vote('concept','swat-tee',1,k3);
 reset role;
 perform sdi_test.check(r->>'code'='rate_limited','31st action in a minute refused');
 update sdi_private.merch_budget set window_start=clock_timestamp()-interval '2 minutes';
 r:=sdi_private.merch_vote('concept','swat-tee',1,k3);
 perform sdi_test.check(r->>'status'='recorded','expired window admits the key again');
 update sdi_private.merch_settings set anon_votes_per_minute=(select attempts from sdi_private.merch_global_budget where bucket='anon_vote')+2;
 r:=sdi_private.merch_vote('concept','stickzilla-poster',1,gen_random_uuid());
 r:=sdi_private.merch_vote('concept','stickzilla-poster',1,gen_random_uuid());
 perform sdi_test.check(r->>'status'='recorded','global budget not yet spent');
 r:=sdi_private.merch_vote('concept','stickzilla-poster',1,gen_random_uuid());
 perform sdi_test.check(r->>'code'='rate_limited','global anonymous budget refuses fresh keys');

 -- Retention removes stale budgets; rejected ideas stay until 30 days after the decision.
 update sdi_private.merch_budget set window_start=clock_timestamp()-interval '2 days';
 i:=sdi_private.merch_retention();
 perform sdi_test.check(i>=1 and not exists(select 1 from sdi_private.merch_budget),'stale budgets swept: '||i);
 perform sdi_test.check(exists(select 1 from sdi_private.merch_ideas where id=idea),'recent rejection kept');
end $$;
rollback;
