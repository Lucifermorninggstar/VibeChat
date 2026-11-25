-- Elsewhere MVP: minimal profile and short-lived matching data. Never stores media.
create extension if not exists pgcrypto;
create type public.chat_mode as enum ('video','audio','text');
create type public.session_status as enum ('matched','connecting','connected','ended');
create type public.moderation_state as enum ('active','banned');
create table public.profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 gender text not null default 'Prefer not to say' check (gender in ('Male','Female','Non-binary','Transgender','Other','Prefer not to say')),
 adult_confirmed boolean not null default false, moderation_status public.moderation_state not null default 'active',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.user_preferences (
 user_id uuid primary key references public.profiles(user_id) on delete cascade,
 mode public.chat_mode not null default 'video', preferred_gender text not null default 'Any',
 interests text[] not null default '{}', region text, updated_at timestamptz not null default now(),
 check (cardinality(interests) <= 5)
);
create table public.premium_entitlements (
 user_id uuid primary key references public.profiles(user_id) on delete cascade,
 tier text not null default 'free' check (tier in ('free','plus')),
 active boolean not null default false, source text not null default 'demo', expires_at timestamptz,
 created_at timestamptz not null default now()
);
create table public.chat_sessions (
 id uuid primary key default gen_random_uuid(), user_a uuid not null references auth.users(id) on delete cascade,
 user_b uuid not null references auth.users(id) on delete cascade, mode public.chat_mode not null,
 status public.session_status not null default 'matched', ready_a boolean not null default false, ready_b boolean not null default false,
 created_at timestamptz not null default now(), last_heartbeat timestamptz not null default now(), expires_at timestamptz not null default now()+interval '2 hours', ended_at timestamptz,
 check(user_a <> user_b)
);
create unique index one_active_session_per_user_a on public.chat_sessions(user_a) where status <> 'ended';
create unique index one_active_session_per_user_b on public.chat_sessions(user_b) where status <> 'ended';
create table public.match_queue (
 user_id uuid primary key references auth.users(id) on delete cascade, mode public.chat_mode not null, status text not null default 'searching' check(status='searching'),
 gender text not null, preferred_gender text not null, region text not null default 'Any', interests text[] not null default '{}',
 queued_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '3 minutes'
);
create index match_queue_scan on public.match_queue(mode,queued_at);
create table public.blocked_users (
 blocker_id uuid not null references auth.users(id) on delete cascade, blocked_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(blocker_id,blocked_id), check(blocker_id<>blocked_id)
);
create table public.recent_skips (
 user_id uuid not null references auth.users(id) on delete cascade, skipped_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(user_id,skipped_id)
);
create table public.reports (
 id uuid primary key default gen_random_uuid(), reporter_id uuid not null references auth.users(id) on delete cascade,
 reported_id uuid not null references auth.users(id) on delete cascade, session_id uuid references public.chat_sessions(id) on delete set null,
 reason text not null check(reason in ('Inappropriate behavior','Harassment or hate','Possible minor','Spam or scam','Other')),
 status text not null default 'pending' check(status in ('pending','reviewed','actioned','dismissed')),
 created_at timestamptz not null default now(), reviewed_at timestamptz, check(reporter_id<>reported_id)
);
create index reports_pending on public.reports(status,created_at desc);
create table public.admin_roles(user_id uuid primary key references auth.users(id) on delete cascade, role text not null default 'moderator' check(role in ('admin','moderator')), created_at timestamptz not null default now());

alter table public.profiles enable row level security;
alter table public.user_preferences enable row level security;
alter table public.premium_entitlements enable row level security;
alter table public.chat_sessions enable row level security;
alter table public.match_queue enable row level security;
alter table public.blocked_users enable row level security;
alter table public.recent_skips enable row level security;
alter table public.reports enable row level security;
alter table public.admin_roles enable row level security;
create policy "own profile read" on public.profiles for select to authenticated using (user_id=auth.uid());
create policy "own preferences read" on public.user_preferences for select to authenticated using (user_id=auth.uid());
create policy "own entitlement read" on public.premium_entitlements for select to authenticated using (user_id=auth.uid());
create policy "session participants read" on public.chat_sessions for select to authenticated using (auth.uid() in (user_a,user_b));
create policy "own blocks read" on public.blocked_users for select to authenticated using (blocker_id=auth.uid());
create policy "own blocks add" on public.blocked_users for insert to authenticated with check (blocker_id=auth.uid());
create policy "own blocks remove" on public.blocked_users for delete to authenticated using (blocker_id=auth.uid());
create policy "reporter creates own report" on public.reports for insert to authenticated with check (reporter_id=auth.uid());
create policy "reporter reads own reports" on public.reports for select to authenticated using (reporter_id=auth.uid());
create policy "admin roles self read" on public.admin_roles for select to authenticated using (user_id=auth.uid());
-- Queue, skips and reports are never world-readable. All matching mutations use definer RPCs.
revoke all on public.match_queue,public.recent_skips from anon,authenticated;
revoke insert,update,delete on public.chat_sessions from anon,authenticated;
revoke update,delete on public.reports from anon,authenticated;

create or replace function public.enqueue_for_match(p_mode public.chat_mode,p_gender text,p_preference text,p_interests text[],premium_claim boolean default false,p_adult_confirmed boolean default false,p_guidelines_accepted boolean default false,p_region text default 'Any')
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); has_plus boolean;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('enqueue:'||uid::text,0));
 if not p_adult_confirmed or not p_guidelines_accepted then raise exception 'Confirm age 18+ and community guidelines'; end if;
 if p_gender not in ('Male','Female','Non-binary','Transgender','Other','Prefer not to say') then raise exception 'Invalid gender'; end if;
 if p_preference not in ('Any','Male','Female','Non-binary','Transgender','Other','Prefer not to say') then raise exception 'Invalid preference'; end if;
 if cardinality(coalesce(p_interests,'{}'))>5 then raise exception 'Choose up to five interests'; end if;
 select exists(select 1 from premium_entitlements where user_id=uid and tier='plus' and active and (expires_at is null or expires_at>now())) into has_plus;
 if (p_preference<>'Any' or coalesce(p_region,'Any')<>'Any') and not has_plus then raise exception 'Premium entitlement required for advanced filters'; end if;
 if coalesce(p_region,'Any') not in ('Any','United States','India','United Kingdom','Canada','Australia','Brazil','France','Germany','Japan','Mexico','Philippines','South Africa') then raise exception 'Invalid region'; end if;
 insert into profiles(user_id,gender,adult_confirmed) values(uid,p_gender,true) on conflict(user_id) do update set gender=excluded.gender,adult_confirmed=true,updated_at=now();
 if (select moderation_status from profiles where user_id=uid)<>'active' then raise exception 'Account is unavailable'; end if;
 if exists(select 1 from chat_sessions where status<>'ended' and uid in(user_a,user_b)) then raise exception 'End your current conversation before searching'; end if;
 if exists(select 1 from match_queue where user_id=uid and expires_at>now()) then return; end if;
 insert into user_preferences(user_id,mode,preferred_gender,interests,region) values(uid,p_mode,p_preference,coalesce(p_interests,'{}'),coalesce(p_region,'Any')) on conflict(user_id) do update set mode=excluded.mode,preferred_gender=excluded.preferred_gender,interests=excluded.interests,region=excluded.region,updated_at=now();
 insert into premium_entitlements(user_id) values(uid) on conflict do nothing;
 insert into match_rate_limits(user_id,last_enqueue) values(uid,now()) on conflict(user_id) do update set last_enqueue=now() where match_rate_limits.last_enqueue < now()-interval '5 seconds'
  or exists(select 1 from chat_sessions c where uid in(c.user_a,c.user_b) and c.status='ended' and c.ended_at>match_rate_limits.last_enqueue);
 if not found then raise exception 'Please wait a few seconds before searching again'; end if;
 insert into match_queue(user_id,mode,gender,preferred_gender,region,interests,queued_at,expires_at) values(uid,p_mode,p_gender,p_preference,coalesce(p_region,'Any'),coalesce(p_interests,'{}'),now(),now()+interval '3 minutes') on conflict(user_id) do update set mode=excluded.mode,gender=excluded.gender,preferred_gender=excluded.preferred_gender,region=excluded.region,interests=excluded.interests,queued_at=now(),expires_at=now()+interval '3 minutes';
end $$;
revoke all on function public.enqueue_for_match(public.chat_mode,text,text,text[],boolean,boolean,boolean,text) from public;
grant execute on function public.enqueue_for_match(public.chat_mode,text,text,text[],boolean,boolean,boolean,text) to authenticated;

create or replace function public.try_match() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); me match_queue%rowtype; candidate match_queue%rowtype; sid uuid;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('elsewhere_matchmaking',0));
 delete from match_queue where expires_at<now(); update chat_sessions set status='ended',ended_at=now() where status<>'ended' and (expires_at<now() or (status in ('matched','connecting') and created_at<now()-interval '45 seconds') or (status='connected' and last_heartbeat<now()-interval '90 seconds'));
 select * into me from match_queue where user_id=uid and expires_at>now();
 if not found then return jsonb_build_object('session_id',null); end if;
 if exists(select 1 from profiles where user_id=uid and moderation_status<>'active') then delete from match_queue where user_id=uid;raise exception 'Account unavailable';end if;
 select q.* into candidate from match_queue q join profiles p on p.user_id=q.user_id
 where q.user_id<>uid and q.mode=me.mode and q.expires_at>now() and p.moderation_status='active'
 and (me.preferred_gender='Any' or me.preferred_gender=q.gender)
 and (q.preferred_gender='Any' or q.preferred_gender=me.gender)
 and (me.region='Any' or me.region=q.region) and (q.region='Any' or q.region=me.region)
 and (cardinality(me.interests)=0 or cardinality(q.interests)=0 or me.interests&&q.interests)
 and not exists(select 1 from blocked_users b where (b.blocker_id=uid and b.blocked_id=q.user_id) or (b.blocker_id=q.user_id and b.blocked_id=uid))
 and not exists(select 1 from recent_skips s where (s.user_id=uid and s.skipped_id=q.user_id or s.user_id=q.user_id and s.skipped_id=uid) and s.created_at>now()-interval '10 minutes')
 and not exists(select 1 from chat_sessions c where c.status<>'ended' and (c.user_a in(uid,q.user_id) or c.user_b in(uid,q.user_id)))
 order by q.queued_at for update of q skip locked limit 1;
 if not found then return jsonb_build_object('session_id',null); end if;
 insert into chat_sessions(user_a,user_b,mode) values(uid,candidate.user_id,me.mode) returning id into sid;
 delete from match_queue where user_id in(uid,candidate.user_id);
 return jsonb_build_object('session_id',sid);
exception when unique_violation then return jsonb_build_object('session_id',null);
end $$;
revoke all on function public.try_match() from public;
grant execute on function public.try_match() to authenticated;

create or replace function public.leave_match_queue() returns void language sql security definer set search_path=public,pg_temp as $$ delete from match_queue where user_id=auth.uid() $$;
grant execute on function public.leave_match_queue() to authenticated;
create or replace function public.end_chat_session(p_session_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare other uuid; begin update chat_sessions set status='ended',ended_at=now() where id=p_session_id and auth.uid() in(user_a,user_b) and status<>'ended' returning case when user_a=auth.uid() then user_b else user_a end into other; if other is not null then insert into recent_skips values(auth.uid(),other,now()) on conflict(user_id,skipped_id) do update set created_at=now(); end if; end $$;
grant execute on function public.end_chat_session(uuid) to authenticated;
create or replace function public.mark_session_ready(p_session_id uuid) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare ready boolean; begin update chat_sessions set ready_a=ready_a or user_a=auth.uid(),ready_b=ready_b or user_b=auth.uid(),status='connecting' where id=p_session_id and auth.uid() in(user_a,user_b) and status<>'ended' returning ready_a and ready_b into ready; return coalesce(ready,false); end $$;
create or replace function public.mark_session_connected(p_session_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 update chat_sessions set status='connected' where id=p_session_id and auth.uid() in(user_a,user_b) and ready_a and ready_b and status='connecting';
end $$;
grant execute on function public.mark_session_connected(uuid) to authenticated;
grant execute on function public.mark_session_ready(uuid) to authenticated;

create or replace function public.admin_ban_user(p_user_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 if not exists(select 1 from admin_roles where user_id=auth.uid()) then raise exception 'Admin only'; end if;
 update profiles set moderation_status='banned' where user_id=p_user_id;delete from match_queue where user_id=p_user_id;
 update chat_sessions set status='ended',ended_at=now() where status<>'ended' and p_user_id in(user_a,user_b);
end $$;
create or replace function public.admin_unban_user(p_user_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 if not exists(select 1 from admin_roles where user_id=auth.uid()) then raise exception 'Admin only'; end if;
 update profiles set moderation_status='active' where user_id=p_user_id;
end $$;
grant execute on function public.admin_ban_user(uuid),public.admin_unban_user(uuid) to authenticated;

-- Run periodically from Supabase SQL editor/pg_cron if available; app handles queue expiry on matching.
create or replace function public.cleanup_expired_data() returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 delete from match_queue where expires_at<now();
 update chat_sessions set status='ended',ended_at=now() where status<>'ended' and (expires_at<now() or (status in ('matched','connecting') and created_at<now()-interval '45 seconds') or (status='connected' and last_heartbeat<now()-interval '90 seconds'));
 delete from chat_sessions where status='ended' and ended_at<now()-interval '24 hours';
 delete from recent_skips where created_at<now()-interval '10 minutes';
 delete from chat_messages where created_at<now()-interval '1 hour';
 delete from reports where status<>'pending' and created_at<now()-interval '90 days';
end $$;

-- Demo premium is explicitly non-payment demo access. Remove this RPC when a payment provider is added.
create or replace function public.enable_demo_plus() returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 insert into profiles(user_id,adult_confirmed) values(auth.uid(),true) on conflict(user_id) do nothing;
 insert into premium_entitlements(user_id,tier,active,source) values(auth.uid(),'plus',true,'demo')
 on conflict(user_id) do update set tier='plus',active=true,source='demo',expires_at=null;
end $$;
grant execute on function public.enable_demo_plus() to authenticated;

create policy "admins read all reports" on public.reports for select to authenticated using (exists(select 1 from admin_roles a where a.user_id=auth.uid()));
create policy "admins update reports" on public.reports for update to authenticated using (exists(select 1 from admin_roles a where a.user_id=auth.uid())) with check (exists(select 1 from admin_roles a where a.user_id=auth.uid()));
create or replace function public.admin_review_report(p_report_id uuid,p_status text) returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 if not exists(select 1 from admin_roles where user_id=auth.uid()) then raise exception 'Admin only'; end if;
 if p_status not in ('reviewed','actioned','dismissed') then raise exception 'Invalid report status'; end if;
 update reports set status=p_status,reviewed_at=now() where id=p_report_id;
end $$;
grant execute on function public.admin_review_report(uuid,text) to authenticated;

-- Private Realtime topics grant access only to participants in the named session.
create policy "session members read realtime" on realtime.messages for select to authenticated
 using (realtime.topic() ~ '^room:[0-9a-f-]{36}$' and exists(select 1 from chat_sessions s where s.id::text=split_part(realtime.topic(),':',2) and auth.uid() in(s.user_a,s.user_b) and s.status<>'ended'));
create policy "session members send realtime" on realtime.messages for insert to authenticated
 with check (realtime.topic() ~ '^room:[0-9a-f-]{36}$' and exists(select 1 from chat_sessions s where s.id::text=split_part(realtime.topic(),':',2) and auth.uid() in(s.user_a,s.user_b) and s.status<>'ended'));
-- The client subscribes to session status for lifecycle changes.
do $$ begin alter publication supabase_realtime add table public.chat_sessions; exception when duplicate_object then null; end $$;

create table public.match_rate_limits(user_id uuid primary key references auth.users(id) on delete cascade,last_enqueue timestamptz not null default now());
alter table public.match_rate_limits enable row level security;
revoke all on public.match_rate_limits from anon,authenticated;

-- Text messages are retained briefly for reconnects and moderation flow; media is never stored.
create table public.chat_messages(
 id uuid primary key default gen_random_uuid(), session_id uuid not null references public.chat_sessions(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade, body text not null check(length(body) between 1 and 1000),
 created_at timestamptz not null default now()
);
create index chat_messages_by_session on public.chat_messages(session_id,created_at);
alter table public.chat_messages enable row level security;
create policy "session participants read messages" on public.chat_messages for select to authenticated
 using(exists(select 1 from chat_sessions s where s.id=session_id and auth.uid() in(s.user_a,s.user_b)));
revoke insert,update,delete on public.chat_messages from anon,authenticated;
create table public.message_rate_limits(user_id uuid primary key references auth.users(id) on delete cascade,last_sent timestamptz not null default now());
alter table public.message_rate_limits enable row level security;
revoke all on public.message_rate_limits from anon,authenticated;
create or replace function public.send_chat_message(p_session_id uuid,p_body text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); message_id uuid;
begin
 if uid is null then raise exception 'Authentication required';end if;
 if length(trim(p_body)) not between 1 and 1000 then raise exception 'Message must be 1–1000 characters';end if;
 if not exists(select 1 from chat_sessions where id=p_session_id and status='connected' and ready_a and ready_b and auth.uid() in(user_a,user_b) and expires_at>now()) then raise exception 'Chat is not active';end if;
 if exists(select 1 from profiles where user_id=uid and moderation_status<>'active') then raise exception 'Account unavailable';end if;
 insert into message_rate_limits(user_id,last_sent) values(uid,now()) on conflict(user_id) do update set last_sent=now() where message_rate_limits.last_sent<now()-interval '1 second';
 if not found then raise exception 'Please wait before sending another message';end if;
 insert into chat_messages(session_id,sender_id,body) values(p_session_id,uid,trim(p_body)) returning id into message_id;
 return message_id;
end $$;
revoke all on function public.send_chat_message(uuid,text) from public;
grant execute on function public.send_chat_message(uuid,text) to authenticated;
do $$ begin alter publication supabase_realtime add table public.chat_messages; exception when duplicate_object then null; end $$;
create or replace function public.admin_search_users(p_query text) returns table(user_id uuid,gender text,moderation_status public.moderation_state,created_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$begin
 if not exists(select 1 from admin_roles where admin_roles.user_id=auth.uid()) then raise exception 'Admin only';end if;
 return query select p.user_id,p.gender,p.moderation_status,p.created_at from profiles p where p.user_id::text=p_query limit 20;
end $$;
grant execute on function public.admin_search_users(text) to authenticated;

create policy "admins read profiles" on public.profiles for select to authenticated using (exists(select 1 from admin_roles a where a.user_id=auth.uid()));
create policy "admins read sessions" on public.chat_sessions for select to authenticated using (exists(select 1 from admin_roles a where a.user_id=auth.uid()));
create or replace function public.heartbeat_chat_session(p_session_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 update chat_sessions set last_heartbeat=now() where id=p_session_id and auth.uid() in(user_a,user_b) and status<>'ended';
end $$;
grant execute on function public.heartbeat_chat_session(uuid) to authenticated;

revoke all on function public.cleanup_expired_data() from public,anon,authenticated;
grant execute on function public.cleanup_expired_data() to service_role;
create or replace function public.disable_demo_plus() returns void language plpgsql security definer set search_path=public,pg_temp as $$begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 update premium_entitlements set tier='free',active=false,source='demo',expires_at=null where user_id=auth.uid();
end $$;
grant execute on function public.disable_demo_plus() to authenticated;
