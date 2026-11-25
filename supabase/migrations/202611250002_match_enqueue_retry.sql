-- Make repeated queue requests idempotent, and allow Next after ending a session.
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
