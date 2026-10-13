-- Local assertions for agent-proposals.sql: proposals above caps wait for the owner.
begin;
do $$
declare owner uuid; viewer uuid; r jsonb; rev bigint; run uuid; proposal uuid; prev bigint;
begin
 owner:=sdi_test.admin('proposal-owner',true,array[]::text[]); viewer:=sdi_test.admin('proposal-viewer',false,array['overview']);
 perform sdi_test.login(owner,'aal2');
 select revision into rev from sdi_private.agents where key='marketing_proposals';
 r:=sdi_private.agent_admin('publish_instructions','marketing_proposals',rev,'{"body":"Propose only."}','Initial.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('set_permissions','marketing_proposals',rev,'{"permissions":["read"]}','Read only first.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('set_caps','marketing_proposals',rev,'{"daily_run_cap":"4","per_run_item_cap":"10","monthly_cost_cap_minor":"1000"}','Small budget.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('resume','marketing_proposals',rev,'{}','Enable.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.logout();
 r:=sdi_private.agent_run_begin('marketing_proposals','cycle-1'); run:=(r->>'run')::uuid;
 perform sdi_test.check(run is not null,'run started: '||r::text);

 -- Without the propose permission nothing is filed; an unknown run cannot file either.
 r:=sdi_private.agent_propose(run,'email_blast','Send the October blast to 12,000 subscribers','{"draft":"d1"}',4800,'monthly cost cap');
 perform sdi_test.check(r->>'error'='This agent may not propose actions.','read-only agent cannot propose');
 r:=sdi_private.agent_propose(gen_random_uuid(),'email_blast','x','{}',0,'cap');
 perform sdi_test.check(r->>'error'='A running agent run is required to propose.','unknown run cannot propose');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.agent_admin('set_permissions','marketing_proposals',rev,'{"permissions":["read","propose"]}','Allow proposals.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.logout();

 -- A live run files one proposal; the identical pending proposal is not duplicated.
 r:=sdi_private.agent_propose(run,'email_blast','Send the October blast to 12,000 subscribers','{"draft":"d1"}',4800,'monthly cost cap');
 perform sdi_test.check(r->>'state'='pending' and (r->>'proposal') is not null,'proposal filed: '||r::text); proposal:=(r->>'proposal')::uuid;
 r:=sdi_private.agent_propose(run,'email_blast','Send the October blast again','{"draft":"d1"}',4800,'monthly cost cap');
 perform sdi_test.check((r->>'proposal')::uuid=proposal and (r->>'duplicate')::boolean,'identical pending proposal returned, not duplicated');
 r:=sdi_private.agent_propose(run,'email_blast','Bad','{"draft":"d2"}',-1,'cap');
 perform sdi_test.check(r->>'error' like 'Proposal needs%','negative estimate refused');
 perform sdi_test.check((select count(*) from sdi_private.agent_proposals)=1,'one proposal stored');
 r:=sdi_private.agent_proposals_due('marketing_proposals');
 perform sdi_test.check(jsonb_array_length(r->'proposals')=0,'nothing executes before a decision');

 -- Viewers read the inbox; only the owner decides, with a reason, and the decision is audited.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.agent_proposal_admin('inbox');
 perform sdi_test.check((r->>'pending')::integer=1 and (r->'proposals'->0->>'cap_reason')='monthly cost cap','viewer reads the inbox: '||r::text);
 prev:=(r->'proposals'->0->>'revision')::bigint;
 r:=sdi_private.agent_proposal_admin('approve',proposal,prev,'Go ahead.');
 perform sdi_test.check(r->>'error' like 'Owner permission%','viewer cannot decide');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.agent_proposal_admin('approve',proposal,prev,'');
 perform sdi_test.check(r->>'error'='A reason is required.','decision needs a reason');
 r:=sdi_private.agent_proposal_admin('approve',proposal,prev+5,'Go ahead.');
 perform sdi_test.check(r->>'error' like 'Proposal changed%','stale revision refused');
 r:=sdi_private.agent_proposal_admin('approve',proposal,prev,'Approved for October.');
 perform sdi_test.check(r->>'status'='confirmed' and r->>'state'='approved','owner approves: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.agent_audit where actor=owner and action like 'proposal_approve%')=1,'approval audited');
 r:=sdi_private.agent_proposal_admin('reject',proposal,(r->>'revision')::bigint,'Changed my mind.');
 perform sdi_test.check(r->>'error'='Only a pending proposal can be decided.','decided proposal is final');
 perform sdi_test.logout();

 -- The worker receives approved proposals once and records the outcome.
 r:=sdi_private.agent_proposals_due('marketing_proposals');
 perform sdi_test.check(jsonb_array_length(r->'proposals')=1 and (r->'proposals'->0->>'id')::uuid=proposal,'approved proposal handed to the worker');
 perform sdi_test.check(not sdi_private.agent_proposal_finish(proposal,gen_random_uuid(),'executed','x'),'foreign run cannot finish it');
 perform sdi_test.check(not sdi_private.agent_proposal_finish(proposal,run,'done','x'),'unknown outcome state refused');
 perform sdi_test.check(sdi_private.agent_proposal_finish(proposal,run,'executed','Sent 12,000.'),'executing run records the outcome');
 perform sdi_test.check((select state from sdi_private.agent_proposals where id=proposal)='executed','state executed');
 perform sdi_test.check(jsonb_array_length(sdi_private.agent_proposals_due('marketing_proposals')->'proposals')=0,'executed proposal not handed out again');

 -- Expiry and emergency stop.
 r:=sdi_private.agent_propose(run,'email_blast','Stale one','{"draft":"d3"}',10,'cap'); proposal:=(r->>'proposal')::uuid;
 update sdi_private.agent_proposals set expires_at=clock_timestamp()-interval '1 second' where id=proposal;
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.agent_proposal_admin('inbox');
 perform sdi_test.check((select state from sdi_private.agent_proposals where id=proposal)='expired','pending proposal expired on inbox read');
 r:=sdi_private.agent_admin('emergency_stop',payload=>'{"enabled":true}',reason=>'Stop.');
 perform sdi_test.logout();
 r:=sdi_private.agent_proposals_due();
 perform sdi_test.check(jsonb_array_length(r->'proposals')=0 and r->>'reason'='Emergency stop is active.','emergency stop hands out nothing');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_agent_propose(gen_random_uuid(),''k'',''s'')'),'clients cannot file proposals');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_agent_proposals_due()'),'clients cannot read the worker queue');
end $$;
rollback;
