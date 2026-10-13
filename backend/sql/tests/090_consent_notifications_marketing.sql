-- Local assertions for consent-versions.sql (#174/#261/#273), notifications.sql
-- (#290/#276) and marketing-workspace.sql (#274/#283).
begin;
create function sdi_test.social_review(creator uuid,digest text,consent text,spatter boolean default false) returns uuid language plpgsql as $$
declare review uuid;
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations,spatter_generated)
 values(creator,'Render '||left(digest,6),'rev1',digest,'https://intake.example.test/'||left(digest,6),clock_timestamp()+interval '1 day',consent,'Own work',true,array['feed','social'],spatter) returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,left(digest,6)||'.mp4',1024,'Render '||left(digest,6),'A caption.',false,clock_timestamp()+interval '24 hours');
 return review;
end $$;

do $$
declare owner uuid; member uuid; other uuid; reviewer uuid; r jsonb; review uuid; job uuid;
begin
 owner:=sdi_test.admin('consent-owner',true,array[]::text[]); member:=sdi_test.user('consenting'); other:=sdi_test.user('silent'); reviewer:=sdi_test.admin('consent-reviewer',false,array['reviews']);
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_consent_action(''current'')'),'anon cannot call the consent surface');
 perform sdi_test.login(member);
 r:=sdi_private.consent_action('accept','publishing','publishing-v1','ios');
 perform sdi_test.check(r->>'error' like 'This policy has not been published%','accept refused before any version exists');
 r:=sdi_private.consent_action('publish','publishing','publishing-v1',summary=>'x',reason=>'r');
 perform sdi_test.check(r->>'code'='forbidden','member cannot publish policy versions');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.consent_action('publish','publishing','publishing-v1',summary=>'Publishing permission v1.',reason=>'Initial.');
 perform sdi_test.check(r->>'code'='step_up_required','publishing a policy needs step-up');
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.consent_action('publish','publishing','publishing-v1',summary=>'Publishing permission v1.',reason=>'Initial.');
 perform sdi_test.check(r->>'status'='published','publishing policy v1 published: '||r::text);
 r:=sdi_private.consent_action('publish','content','content-v1',summary=>'Fictional stick animation only.',reason=>'Initial.');
 perform sdi_test.check(r->>'error' like 'The content policy needs min_age%','content policy requires an explicit age rule');
 r:=sdi_private.consent_action('publish','content','content-v1',summary=>'Fictional stick animation only.',metadata=>'{"min_age":"13"}',reason=>'Owner decision pending legal review.');
 perform sdi_test.check(r->>'status'='published','content policy published with min_age');
 perform sdi_private.consent_action('publish','marketing','marketing-v1',summary=>'Marketing reuse permission v1.',reason=>'Initial.');
 r:=sdi_private.consent_action('publish','marketing','marketing-v1',summary=>'Again.',reason=>'Dup.');
 perform sdi_test.check(r->>'error' like 'That version id already exists%','history cannot be edited');
 r:=sdi_private.consent_action('current');
 perform sdi_test.check(jsonb_array_length(r->'policies')=3,'three current policies');
 perform sdi_test.login(member);
 r:=sdi_private.consent_action('accept','publishing','publishing-v0','ios');
 perform sdi_test.check(r->>'error' like 'Policy version changed%' and r->>'current'='publishing-v1','stale version refused with the current id');
 r:=sdi_private.consent_action('accept','publishing','publishing-v1','ios');
 perform sdi_test.check(r->>'status'='accepted','publishing v1 accepted');
 r:=sdi_private.consent_verify(member,'publishing-v1');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'reason' like 'Current content policy%','content attestation required before submission: '||r::text);
 r:=sdi_private.consent_action('accept','content','content-v1','ios');
 perform sdi_test.check(r->>'error' like 'Confirm you meet%','content policy needs the age attestation');
 r:=sdi_private.consent_action('accept','content','content-v1','ios','{"age_ok":true}');
 perform sdi_test.check(r->>'status'='accepted','content policy accepted with attestation');
 perform sdi_test.check((sdi_private.consent_verify(member,'publishing-v1')->>'allowed')::boolean,'submission allowed with current consents');
 perform sdi_test.check((sdi_private.consent_verify(other,'publishing-v1')->>'allowed')::boolean=false,'another member without consent is refused');
 perform sdi_test.check((sdi_private.consent_verify(member,'publishing-v0')->>'reason') like 'Publishing terms changed%','old version refused by the service check');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_consent_verify(gen_random_uuid(),''x'')'),'clients cannot call consent_verify');
 r:=sdi_private.consent_action('mine');
 perform sdi_test.check((r->>'publishing_current')::boolean and not (r->>'marketing_current')::boolean,'mine reports separate publishing and marketing state: '||r::text);
 -- A new version makes the old acceptance non-current without deleting it.
 perform sdi_test.login(owner,'aal2',60);
 perform sdi_private.consent_action('publish','publishing','publishing-v2',summary=>'Publishing permission v2.',reason=>'Clarified channel permission.');
 perform sdi_test.login(member);
 perform sdi_test.check((sdi_private.consent_verify(member,'publishing-v1')->>'allowed')::boolean=false,'v1 consent no longer admits new submissions');
 perform sdi_test.check((sdi_private.consent_action('mine')->>'publishing_current')::boolean=false,'member sees that re-acceptance is needed');
 perform sdi_private.consent_action('accept','publishing','publishing-v2','web');
 perform sdi_test.check((sdi_private.consent_verify(member,'publishing-v2')->>'allowed')::boolean,'v2 accepted from the web');
 -- Withdrawal clears consent on every render and the publishing trigger cancels the queued job.
 review:=sdi_test.social_review(member,repeat('a',64),'publishing-v2');
 perform sdi_test.login(reviewer,'aal2');
 perform sdi_private.review_action('decide',review,repeat('a',64),1,'approved','Fine.');
 perform sdi_test.login(member);
 r:=sdi_private.creator_review('publish_feed',review,1);
 perform sdi_test.check(r->>'status'='queued','feed job queued before withdrawal: '||r::text);
 r:=sdi_private.consent_action('withdraw','terms');
 perform sdi_test.check(r ? 'error','terms cannot be withdrawn here');
 r:=sdi_private.consent_action('withdraw','publishing');
 perform sdi_test.check(r->>'status'='withdrawn' and (r->>'records')::integer=2,'publishing consent withdrawn: '||r::text);
 perform sdi_test.check((select consent_version from sdi_private.render_reviews where id=review)='','render consent cleared');
 perform sdi_test.check((select state from sdi_private.publish_jobs where review_id=review)='cancelled','queued job cancelled by withdrawal');
 perform sdi_test.check((sdi_private.consent_verify(member,'publishing-v2')->>'allowed')::boolean=false,'no new submissions after withdrawal');
 perform sdi_test.check((select count(*) from sdi_private.consent_audit where actor=member)=4,'member consent actions audited');
end $$;

do $$
declare a uuid; b uuid; c uuid; d uuid; ghost uuid; agent uuid; r jsonb; ann uuid; rev bigint; dev_a uuid; dev_c uuid; i integer; claimed jsonb; delivery_a uuid; delivery_c uuid; hash_c text;
begin
 a:=sdi_test.user('push-a'); b:=sdi_test.user('push-b'); c:=sdi_test.user('push-c'); d:=sdi_test.user('push-d'); ghost:=sdi_test.user('push-ghost',true);
 agent:=sdi_test.admin('announcer',false,array['users']);
 insert into sdi_private.account_controls(user_id,state,reason) values(d,'suspended','test');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_notify_action(''preferences'')'),'anon cannot read preferences');
 perform sdi_test.login(a);
 r:=sdi_private.notify_action('preferences');
 perform sdi_test.check((r->>'push_marketing')::boolean=false and (r->>'email_marketing')::boolean=false and (r->>'daily_cap')::integer=2,'marketing is off by default: '||r::text);
 perform sdi_test.check((sdi_private.notify_action('set_preferences','{"daily_cap":"11"}')) ? 'error','daily cap bounded');
 r:=sdi_private.notify_action('register_device','{"platform":"ios","environment":"sandbox","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'); dev_a:=(r->>'device')::uuid;
 perform sdi_test.check(r->>'status'='confirmed','device registered');
 for i in 1..4 loop perform sdi_private.notify_action('register_device',jsonb_build_object('platform','ios','environment','sandbox','token',repeat('b',40)||i)); end loop;
 r:=sdi_private.notify_action('register_device','{"platform":"android","environment":"production","token":"cccccccccccccccccccccccccccccccccccccccccc"}');
 perform sdi_test.check(r->>'error' like 'Five devices%','sixth device refused');
 perform sdi_test.check(jsonb_array_length(sdi_private.notify_action('preferences')->'devices')=5 and (sdi_private.notify_action('preferences')->'devices'->0) ? 'platform' and not (sdi_private.notify_action('preferences')->'devices'->0) ? 'token','device list never returns tokens');
 for i in 1..4 loop perform sdi_private.notify_action('revoke_device',jsonb_build_object('device',(select id from sdi_private.device_tokens where user_id=a and device_token=repeat('b',40)||i))); end loop;
 perform sdi_test.login(c);
 perform sdi_private.notify_action('set_preferences','{"push_marketing":true,"email_product":true}');
 r:=sdi_private.notify_action('register_device','{"platform":"android","environment":"production","token":"cccccccccccccccccccccccccccccccccccccccc"}'); dev_c:=(r->>'device')::uuid;
 perform sdi_test.login(d);
 perform sdi_test.check((sdi_private.notify_action('register_device','{"platform":"ios","environment":"sandbox","token":"dddddddddddddddddddddddddddddddddddddddd"}')) ? 'error','suspended member cannot register');
 insert into sdi_private.device_tokens(user_id,platform,environment,device_token) values(d,'ios','sandbox',repeat('d',40));
 -- Compose and schedule (users capability; scheduling needs step-up).
 perform sdi_test.login(a);
 perform sdi_test.check((sdi_private.announce_admin('list')->>'code')='forbidden','member cannot read announcements');
 perform sdi_test.login(agent,'aal2');
 r:=sdi_private.announce_admin('compose',payload=>'{"title":"Service notice","body":"Export fix shipped.","category":"transactional","audience":"all","channels":["push","in_app"]}',reason=>'Release note.');
 perform sdi_test.check(r->>'status'='draft','announcement composed: '||r::text); ann:=(r->>'announcement')::uuid; rev:=(r->>'revision')::bigint;
 r:=sdi_private.announce_admin('schedule',ann,rev,'{}','Send now.');
 perform sdi_test.check(r->>'code'='step_up_required','scheduling needs step-up');
 perform sdi_test.login(agent,'aal2',60);
 r:=sdi_private.announce_admin('schedule',ann,rev,'{}','Send now.');
 perform sdi_test.check(r->>'status'='confirmed','scheduled'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check((sdi_private.announce_admin('schedule',ann,rev,'{}','Again.')) ? 'error','cannot schedule twice');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_announcement_claim()'),'clients cannot run the fan-out');
 -- Service fan-out: in-app to every active full account, push to registered devices.
 claimed:=sdi_private.announcement_claim();
 perform sdi_test.check((claimed->>'announcement')::uuid=ann and jsonb_array_length(claimed->'deliveries')=2 and (claimed->>'complete')::boolean=false,'two push deliveries claimed: '||claimed::text);
 perform sdi_test.check((select count(*) from sdi_private.announcement_deliveries where announcement_id=ann and channel='in_app' and state='sent' and user_id in(a,b,c))=3,'in-app delivered to a, b, c');
 perform sdi_test.check(not exists(select 1 from sdi_private.announcement_deliveries where announcement_id=ann and user_id in(d,ghost)),'suspended and anonymous accounts excluded');
 perform sdi_test.check((select count(*) from jsonb_array_elements(claimed->'deliveries') e where e->>'token' in(repeat('a',40),repeat('c',40)))=2,'batch carries the device tokens for transport');
 select id into delivery_a from sdi_private.announcement_deliveries where announcement_id=ann and user_id=a and channel='push';
 select id into delivery_c from sdi_private.announcement_deliveries where announcement_id=ann and user_id=c and channel='push';
 perform sdi_test.check(jsonb_array_length(sdi_private.announcement_claim()->'deliveries')=0,'claimed deliveries are not handed out twice');
 r:=sdi_private.announcement_finish(jsonb_build_array(jsonb_build_object('delivery',delivery_a,'ok',true),jsonb_build_object('delivery',delivery_c,'ok',false,'reason','Unregistered')));
 perform sdi_test.check((r->>'sent')::integer=1 and (r->>'failed')::integer=1,'results recorded');
 perform sdi_test.check((select revoked_at is not null from sdi_private.device_tokens where id=dev_c),'unregistered token revoked');
 claimed:=sdi_private.announcement_claim();
 perform sdi_test.check((claimed->>'complete')::boolean,'announcement completes when nothing is queued');
 -- sent_count includes the in-app rows of every full account in this shared transaction plus the one push.
 perform sdi_test.check((select state='sent' and sent_count>=4 and failed_count=1 from sdi_private.announcements where id=ann),'counts recorded on the announcement');
 r:=sdi_private.announce_admin('results',ann);
 perform sdi_test.check(jsonb_array_length(r->'results')>=2,'admin reads delivery results');
 perform sdi_test.login(a);
 r:=sdi_private.notify_action('inbox');
 perform sdi_test.check((r->>'unread')::integer=1 and r->'notices'->0->>'title'='Service notice','member inbox has the notice');
 perform sdi_private.notify_action('mark_read',jsonb_build_object('delivery',(r->'notices'->0->>'delivery')::uuid));
 perform sdi_test.check((sdi_private.notify_action('inbox')->>'unread')::integer=0,'notice marked read');
 -- Marketing push respects the opt-in and can be cancelled while sending.
 perform sdi_test.login(c);
 perform sdi_private.notify_action('register_device','{"platform":"android","environment":"production","token":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}');
 perform sdi_test.login(agent,'aal2',60);
 r:=sdi_private.announce_admin('compose',payload=>'{"title":"New brushes","body":"Try them.","category":"marketing","audience":"all","channels":["push"]}',reason=>'Campaign.');
 ann:=(r->>'announcement')::uuid; rev:=(r->>'revision')::bigint;
 r:=sdi_private.announce_admin('schedule',ann,rev,'{}','Go.'); rev:=(r->>'revision')::bigint;
 claimed:=sdi_private.announcement_claim();
 perform sdi_test.check(jsonb_array_length(claimed->'deliveries')=1 and claimed->'deliveries'->0->>'token'=repeat('e',40),'only the opted-in member is queued for marketing: '||claimed::text);
 perform sdi_test.check((select reason from sdi_private.announcement_deliveries where announcement_id=ann and user_id=a)='marketing notices off','opt-out recorded as suppression');
 r:=sdi_private.announce_admin('cancel',ann,rev,'{}','Wrong copy.');
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.announcements where id=ann)='cancelled','sending announcement cancelled');
 perform sdi_test.check((select state from sdi_private.announcement_deliveries where announcement_id=ann and user_id=c)='suppressed','queued delivery suppressed by cancellation');
 -- Email: suppression semantics and category gating; addresses only through the service role.
 hash_c:=sdi_private.email_hash('push-c@example.test');
 r:=sdi_private.email_recipients('transactional');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'recipients') e where e->>'user_id' in(a::text,b::text,c::text))=3 and not exists(select 1 from jsonb_array_elements(r->'recipients') e where e->>'user_id' in(d::text,ghost::text)),'transactional email goes to active full accounts only');
 perform sdi_test.check(jsonb_array_length(sdi_private.email_recipients('marketing')->'recipients')=0,'nobody opted into marketing email');
 perform sdi_test.check(jsonb_array_length(sdi_private.email_recipients('product')->'recipients')=1,'one member opted into product email');
 perform sdi_test.check(sdi_private.email_suppress(hash_c,'unsubscribe'),'unsubscribe recorded');
 perform sdi_test.check(jsonb_array_length(sdi_private.email_recipients('product')->'recipients')=0,'unsubscribe blocks product email');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(sdi_private.email_recipients('transactional')->'recipients') e where e->>'user_id'=c::text),'unsubscribe keeps service notices');
 perform sdi_test.check(sdi_private.email_suppress(hash_c,'bounce'),'bounce recorded');
 perform sdi_test.check(not exists(select 1 from jsonb_array_elements(sdi_private.email_recipients('transactional')->'recipients') e where e->>'user_id'=c::text),'bounce blocks every category');
 perform sdi_test.check(not sdi_private.email_suppress('zz','manual'),'malformed hash refused');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_email_recipients(''transactional'')'),'clients cannot list recipients');
end $$;

do $$
declare owner uuid; publisher uuid; reviewer uuid; creator uuid; campaign uuid; draft uuid; draft2 uuid; draft3 uuid; draft4 uuid; rev bigint; review uuid; review2 uuid; spatter uuid; r jsonb; claimed jsonb; token uuid;
begin
 owner:=sdi_test.admin('mk-owner',true,array[]::text[]); publisher:=sdi_test.admin('mk-publisher',false,array['publishing']); reviewer:=sdi_test.admin('mk-reviewer',false,array['reviews']); creator:=sdi_test.user('mk-creator');
 perform sdi_test.login(owner,'aal2',60);
 perform sdi_private.consent_action('publish','publishing','publishing-v1',summary=>'Publishing.',reason=>'Init.');
 perform sdi_private.consent_action('publish','marketing','marketing-v1',summary=>'Marketing reuse.',reason=>'Init.');
 r:=sdi_private.marketing_action('brand_voice',payload=>'{"body":"Short, dark, funny. Never invent numbers."}',reason=>'Owner voice guide v1.');
 perform sdi_test.check((r->>'version')::integer=1,'brand voice v1 stored');
 perform sdi_test.login(creator);
 perform sdi_private.consent_action('accept','publishing','publishing-v1','ios');
 review:=sdi_test.social_review(creator,repeat('b',64),'publishing-v1'); review2:=sdi_test.social_review(creator,repeat('c',64),'publishing-v1');
 spatter:=sdi_test.social_review(owner,repeat('d',64),'publishing-v1',true);
 perform sdi_test.login(reviewer,'aal2');
 perform sdi_private.review_action('decide',review,repeat('b',64),1,'approved','Fine.');
 perform sdi_private.review_action('decide',review2,repeat('c',64),1,'approved','Fine.');
 perform sdi_test.login(owner,'aal2',60);
 perform sdi_private.review_action('decide',spatter,repeat('d',64),1,'approved','Owner approves the exact render.');
 perform sdi_test.check((sdi_private.marketing_action('list')->>'brand_voice_version')::integer=1,'owner lists the workspace');
 perform sdi_test.login(creator);
 perform sdi_test.check((sdi_private.marketing_action('list')->>'code')='forbidden','member cannot read the workspace');
 perform sdi_test.login(publisher,'aal2');
 r:=sdi_private.marketing_action('create_campaign',payload=>'{"title":"Launch week","goal":"Show the Studio."}',reason=>'Plan.'); campaign:=(r->>'campaign')::uuid;
 r:=sdi_private.marketing_action('create_draft',campaign,payload=>jsonb_build_object('destination','discord','review',review,'copy','New stick carnage from a member.'),reason=>'Draft.');
 draft:=(r->>'draft')::uuid; rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='draft' and r->>'release_problem' like 'The creator has not given current marketing permission%','draft names the missing marketing consent: '||r::text);
 r:=sdi_private.marketing_action('approve',draft=>draft,revision=>rev,reason=>'Ship it.');
 perform sdi_test.check(r->>'code'='step_up_required' or r->>'error'='Owner permission required.','publisher cannot approve: '||r::text);
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.marketing_action('approve',draft=>draft,revision=>rev,reason=>'Ship it.');
 perform sdi_test.check(r->>'error' like 'The creator has not given%','owner cannot approve without creator marketing consent');
 perform sdi_test.login(creator);
 perform sdi_private.consent_action('accept','marketing','marketing-v1','ios');
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.marketing_action('approve',draft=>draft,revision=>rev,reason=>'Ship it.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed' and (select approved_digest=repeat('b',64) and approved_copy_hash is not null and brand_voice_version=1 from sdi_private.marketing_drafts where id=draft),'approval binds digest, copy hash and voice version');
 -- An edit clears approval.
 perform sdi_test.login(publisher,'aal2');
 r:=sdi_private.marketing_action('update_draft',draft=>draft,revision=>rev,payload=>'{"copy":"Fresh stick carnage from a member."}',reason=>'Typo.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check((select state='draft' and approved_at is null from sdi_private.marketing_drafts where id=draft),'edit returns the draft to unapproved');
 r:=sdi_private.marketing_action('queue',draft=>draft,revision=>rev,reason=>'Go.');
 perform sdi_test.check(r->>'error'='Approve the draft first.','unapproved draft cannot be queued');
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.marketing_action('approve',draft=>draft,revision=>rev,reason=>'Ship it.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.marketing_action('queue',draft=>draft,revision=>rev,reason=>'Go.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed','approved draft queued');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_marketing_claim()'),'clients cannot claim marketing work');
 claimed:=sdi_private.marketing_claim(); token:=(claimed->>'lease')::uuid;
 perform sdi_test.check((claimed->>'draft')::uuid=draft and claimed->>'destination'='discord' and claimed->>'digest'=repeat('b',64) and claimed->>'object_key'='bbbbbb.mp4' and claimed->>'media_url' is null,'claim carries the exact render reference: '||claimed::text);
 perform sdi_test.check(not sdi_private.marketing_finish(draft,token,'http://insecure.example/post'),'insecure result url refused');
 perform sdi_test.check(sdi_private.marketing_finish(draft,token,'https://discord.com/channels/1/2/3','msg-3'),'published with the provider result');
 perform sdi_test.check((select state='published' and result_url like 'https://discord.com/%' from sdi_private.marketing_drafts where id=draft),'result recorded');
 perform sdi_test.check(not sdi_private.marketing_finish(draft,token,'https://discord.com/channels/1/2/3','msg-3'),'finishing twice is refused');
 -- Consent withdrawal invalidates approved work bound to the creator's renders.
 r:=sdi_private.marketing_action('create_draft',campaign,payload=>jsonb_build_object('destination','x','review',review2,'copy','Second clip.'),reason=>'Draft.'); draft2:=(r->>'draft')::uuid; rev:=(r->>'revision')::bigint;
 r:=sdi_private.marketing_action('approve',draft=>draft2,revision=>rev,reason=>'Ship.'); rev:=(r->>'revision')::bigint;
 perform sdi_private.marketing_action('queue',draft=>draft2,revision=>rev,reason=>'Go.');
 perform sdi_test.login(creator);
 perform sdi_private.consent_action('withdraw','marketing');
 perform sdi_test.check((select state='invalidated' and last_error like 'Creator withdrew%' from sdi_private.marketing_drafts where id=draft2),'marketing withdrawal invalidates the queued draft');
 perform sdi_test.check((sdi_private.marketing_claim()->>'empty')::boolean,'invalidated draft is never claimed');
 -- Spatter renders need no member consent (owner content) but still need the exact owner approval; cadence queues only approved drafts.
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.marketing_action('create_draft',campaign,payload=>jsonb_build_object('destination','facebook','review',spatter,'copy','Daily draft.'),reason=>'Draft.'); draft3:=(r->>'draft')::uuid; rev:=(r->>'revision')::bigint;
 r:=sdi_private.marketing_action('create_draft',campaign,payload=>jsonb_build_object('destination','facebook','copy','Text only plug.'),reason=>'Draft.'); draft4:=(r->>'draft')::uuid;
 r:=sdi_private.marketing_action('set_cadence',payload=>jsonb_build_object('destination','facebook','enabled',true,'cadence','daily','hour_utc',extract(hour from clock_timestamp())::integer),reason=>'Daily plug.');
 perform sdi_test.check(r->>'status'='confirmed','cadence configured');
 r:=sdi_private.marketing_cadence_due();
 perform sdi_test.check(jsonb_array_length(r->'queued')=0,'cadence queues nothing while no draft is approved: '||r::text);
 r:=sdi_private.marketing_action('approve',draft=>draft3,revision=>rev,reason=>'Exact render approved.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed','spatter draft approved by the owner');
 update sdi_private.marketing_cadence set last_run_at=null where destination='facebook';
 r:=sdi_private.marketing_cadence_due();
 perform sdi_test.check(jsonb_array_length(r->'queued')=1 and (r->'queued'->0->>'draft')::uuid=draft3,'cadence queued the approved draft only: '||r::text);
 perform sdi_test.check((select state from sdi_private.marketing_drafts where id=draft4)='draft','unapproved text draft untouched by cadence');
 perform sdi_test.check(jsonb_array_length(sdi_private.marketing_cadence_due()->'queued')=0,'cadence slot runs once');
 claimed:=sdi_private.marketing_claim(); token:=(claimed->>'lease')::uuid;
 perform sdi_test.check((claimed->>'draft')::uuid=draft3 and (claimed->>'attempt')::integer=1,'cadence-queued draft claimed');
 perform sdi_test.check(sdi_private.marketing_finish(draft3,token,failure=>'Provider not configured.'),'failure recorded');
 select revision into rev from sdi_private.marketing_drafts where id=draft3;
 r:=sdi_private.marketing_action('retry',draft=>draft3,revision=>rev,reason=>'Configured now.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed' and (select state from sdi_private.marketing_drafts where id=draft3)='queued','retry re-queues');
 r:=sdi_private.marketing_action('cancel',draft=>draft3,revision=>rev,reason=>'Hold.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed' and (sdi_private.marketing_claim()->>'empty')::boolean,'cancelled draft is not claimed');
 perform sdi_test.check((sdi_private.marketing_action('cancel',draft=>draft3,revision=>rev,reason=>'Hold.')->>'status')='unchanged','cancel is idempotent');
 -- A render revision invalidates approval bound to the old version.
 perform sdi_test.login(creator);
 perform sdi_private.consent_action('accept','marketing','marketing-v1','ios');
 perform sdi_test.login(owner,'aal2',60);
 r:=sdi_private.marketing_action('create_draft',campaign,payload=>jsonb_build_object('destination','youtube','review',review2,'copy','Clip.'),reason=>'Draft.'); draft2:=(r->>'draft')::uuid; rev:=(r->>'revision')::bigint;
 r:=sdi_private.marketing_action('approve',draft=>draft2,revision=>rev,reason=>'Ship.');
 perform sdi_test.check(r->>'status'='confirmed','re-consented render approved again');
 update sdi_private.render_reviews set state='pending' where id=review2;
 perform sdi_test.check((select state from sdi_private.marketing_drafts where id=draft2)='invalidated','render change invalidates marketing approval');
 perform sdi_test.check((select count(*) from sdi_private.marketing_audit)>=12,'marketing actions audited');
end $$;
rollback;
