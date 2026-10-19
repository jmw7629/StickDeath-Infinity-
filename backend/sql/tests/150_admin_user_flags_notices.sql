-- Local assertions for #285: the audited "reset flags" account action, the
-- sign-up source and open-report columns in the user directory, and the
-- affected-member account notices (notifications.sql).
begin;
do $$
declare usersonly uuid; moderator uuid; creator uuid; reporter1 uuid; reporter2 uuid; other uuid;
 media uuid; the_post uuid; r jsonb; notice uuid;
begin
 usersonly:=sdi_test.admin('flags-users-only',false,array['users']);
 moderator:=sdi_test.admin('flags-moderator',false,array['users','moderation']);
 creator:=sdi_test.user('flags-creator'); reporter1:=sdi_test.user('flags-reporter-1'); reporter2:=sdi_test.user('flags-reporter-2');
 other:=sdi_test.user('flags-other');
 update auth.users set raw_app_meta_data=jsonb_build_object('provider','github') where id=creator;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Flagged','https://cdn.example.test/flagged.mp4',4,true,creator,repeat('f',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,creator,'flags-creator',true) returning id into the_post;
 insert into sdi_private.feed_reports(post,actor,reason) values(the_post,reporter1,'spam'),(the_post,reporter2,'abuse'),(the_post,moderator,'rights');

 -- Members cannot call the directory or the action.
 perform sdi_test.login(other,'aal2',60);
 r:=sdi_private.users_action('reset_flags',creator,reason=>'Coordinated false reports.');
 perform sdi_test.check(r->>'error' is not null and r->>'status' is null,'members cannot reset flags: '||r::text);
 r:=sdi_private.users_action('list');
 perform sdi_test.check(r->'users' is null,'members cannot read the directory');
 perform sdi_test.check(not has_function_privilege('anon','public.sdi_users_action(text,uuid,text,integer,text)','execute'),'anon cannot call account actions');

 -- Directory: sign-up source and open reports (moderation capability only).
 perform sdi_test.login(moderator,'aal2');
 r:=sdi_private.users_action('list',query=>'flags-creator');
 perform sdi_test.check(r->'users'->0->>'signup_source'='github' and (r->'users'->0->>'open_report_count')::integer=3
  and (r->'users'->0->>'feed_report_count')::integer=3,'directory shows sign-up source and open reports: '||r::text);
 perform sdi_test.login(usersonly,'aal2');
 r:=sdi_private.users_action('list',query=>'flags-creator');
 perform sdi_test.check(r->'users'->0->'open_report_count'='null'::jsonb,'open reports hidden without moderation');

 -- Step-up, reason and capability are required.
 r:=sdi_private.users_action('reset_flags',creator,reason=>'Coordinated false reports.');
 perform sdi_test.check(r->>'code'='step_up_required','reset needs a recent second factor: '||r::text);
 perform sdi_test.login(usersonly,'aal2',60);
 r:=sdi_private.users_action('reset_flags',creator,reason=>'Coordinated false reports.');
 perform sdi_test.check(r->>'error' like 'Resetting flags also needs the moderation%','users capability alone cannot reset flags: '||r::text);
 perform sdi_test.login(moderator,'aal2',60);
 r:=sdi_private.users_action('reset_flags',creator,reason=>'');
 perform sdi_test.check(r->>'error' is not null,'reason required');
 r:=sdi_private.users_action('reset_flags',moderator,reason=>'Self.');
 perform sdi_test.check(r->>'error' is not null,'administrators cannot reset their own flags');
 perform sdi_test.check((select count(*) from sdi_private.feed_reports where feed_reports.post=the_post and state='pending')=3,'nothing changed on refusal');

 -- Reset: other reporters' open reports are dismissed and audited; the acting
 -- administrator's own report stays for another reviewer.
 r:=sdi_private.users_action('reset_flags',creator,reason=>'Coordinated false reports.');
 perform sdi_test.check(r->>'status'='confirmed' and (r->>'dismissed')::integer=2,'reset dismisses two reports: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.feed_reports f where f.post=the_post and f.state='pending' and f.actor=moderator)=1,'own report left pending');
 perform sdi_test.check((select count(*) from sdi_private.moderation_audit where media_id=media and action='dismiss' and actor=moderator
  and reason='Account flags reset: Coordinated false reports.')=2,'each dismissal is in the moderation audit');
 perform sdi_test.check(exists(select 1 from sdi_private.admin_user_audit where subject=creator and action='reset_flags' and actor=moderator),'reset audited');
 perform sdi_test.check((select visible from sdi_private.feed_posts where id=the_post),'reset removes nothing');
 r:=sdi_private.users_action('reset_flags',creator,reason=>'Again.');
 perform sdi_test.check(r->>'status'='unchanged' and (r->>'dismissed')::integer=0,'second reset finds nothing open: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.admin_user_audit where subject=creator and action='reset_flags')=1,'an empty reset changes and notifies nothing');

 -- Affected-member notices: suspend and sign-out notify; notes do not.
 r:=sdi_private.users_action('note',creator,reason=>'Internal: watch this account.');
 r:=sdi_private.users_action('suspend',creator,reason=>'Internal-only detail 4711.');
 perform sdi_test.check(r->>'status'='confirmed','suspended');
 perform sdi_test.check((select count(*) from sdi_private.account_notices where user_id=creator)=2,'the reset and the suspension notified, the note did not');
 perform sdi_test.check(not exists(select 1 from sdi_private.account_notices where body like '%4711%' or body like '%Internal%'),'notices never repeat the internal reason');

 -- The suspended member can still read their notices with a fresh session.
 perform sdi_test.login(creator);
 perform sdi_test.check(not sdi_private.account_active(),'member is restricted');
 r:=sdi_private.account_notices_action('list');
 perform sdi_test.check(jsonb_array_length(r->'notices')=2 and (r->>'unread')::integer=2 and r->'notices'->0->>'kind'='suspended','restricted member reads notices: '||r::text);
 notice:=(r->'notices'->0->>'id')::uuid;
 perform sdi_test.login(other);
 r:=sdi_private.account_notices_action('list');
 perform sdi_test.check(jsonb_array_length(r->'notices')=0,'other members see none of them');
 r:=sdi_private.account_notices_action('mark_read',notice);
 perform sdi_test.check(r->>'status'='unchanged','another member cannot mark the notice');
 perform sdi_test.login(creator);
 r:=sdi_private.account_notices_action('mark_read',notice);
 perform sdi_test.check(r->>'status'='confirmed','member marks the notice read');
 r:=sdi_private.account_notices_action('list');
 perform sdi_test.check((r->>'unread')::integer=1,'unread count drops');

 -- Restoring notifies too.
 perform sdi_test.login(moderator,'aal2',60);
 r:=sdi_private.users_action('restore',creator,reason=>'Reviewed.');
 perform sdi_test.check(exists(select 1 from sdi_private.account_notices where user_id=creator and kind='restored'),'restore notified');

 perform sdi_test.logout();
 r:=sdi_private.account_notices_action('list');
 perform sdi_test.check(r->>'error' is not null and r->'notices' is null,'signed-out callers are refused');
 perform sdi_test.check(not has_function_privilege('anon','public.sdi_account_notices(text,uuid)','execute')
  and has_function_privilege('authenticated','public.sdi_account_notices(text,uuid)','execute'),'notices are for signed-in members only');
end $$;
rollback;
