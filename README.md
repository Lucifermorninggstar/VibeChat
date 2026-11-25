# Elsewhere

An adults-only, anonymous random chat MVP. The frontend is React + TypeScript + Vite, with Redux Toolkit/RTK Query for app state, Tailwind available for utility styling, and Supabase for anonymous auth, PostgreSQL, RPC matchmaking, and private Realtime. Calls use browser WebRTC peer-to-peer. Media streams are never recorded or uploaded.

## What works

- Landing, onboarding, matching, chat, premium demo, safety, settings, and protected moderation routes.
- Anonymous Supabase sign-in after the 18+ and community guidelines confirmations.
- Transactional matchmaking RPC with gender preference entitlement enforcement, interests, block exclusions, reciprocal preferences, recent skip avoidance, active-session constraints, expiry, and a per-user start cooldown.
- Session readiness, private Realtime channels, ephemeral WebRTC signaling, text messages limited by the database RPC, camera/mic controls, report and block flows.
- Admin role checks in SQL RPCs and RLS; the browser role flag alone grants no access.
- Database stores profile preferences, reports, entitlement metadata, and short-lived text messages. It never stores audio/video.

## Local setup

1. Install Node.js 20.19+ and npm.
2. Create a Supabase project. In **Authentication → Sign In / Providers**, enable Anonymous Sign-Ins. Anonymous auth is available on Supabase Free, subject to its current abuse limits.
3. In the Supabase SQL Editor, run the files in `supabase/migrations/` once in filename order. If you already applied `202611250001_initial.sql`, run only the new `202611250002_match_enqueue_retry.sql`. To apply migrations with the CLI instead, run `npx supabase login`, `npx supabase link --project-ref YOUR_PROJECT_REF`, then `npx supabase db push --dry-run --remote` and `npx supabase db push --remote`. The CLI needs `--remote` to target the hosted project.
4. Copy `.env.example` to `.env.local` and set the project URL and anon/publishable key. Never put a service role key in this app.
5. Run `npm install`, then `npm run dev`.
6. In Supabase Auth URL settings, allow your local URL and the Netlify production URL. The app can run locally against hosted Supabase without Docker; a full local Supabase stack via CLI requires Docker/container runtime.

If TypeScript build tooling versions change, retain `npm run build` as the deployment build command.

## Admin setup

Create an initial moderator only from the Supabase SQL Editor after an account has signed in once. Find that account in **Authentication → Users**, then insert its UUID:

```sql
insert into public.admin_roles(user_id, role)
values ('AUTH_USER_UUID', 'admin');
```

Only users in `admin_roles` can read reports or call ban/review RPCs. Do not expose a client-side admin toggle.

## Premium demo

The Plus page enables a no-payment demo entitlement. The SQL `enable_demo_plus()` and `disable_demo_plus()` RPCs exist only to demonstrate server-side entitlement checks. Remove or restrict those RPCs before public launch and replace them with a verified payment webhook. No live payment integration is present. Country matching is a self-selected preference from the supported country list; no location is inferred or verified.

## Deploy to Netlify

- Import this repository into Netlify.
- Build command: `npm run build`; publish directory: `dist` (also set in `netlify.toml`).
- Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in Netlify environment variables, then deploy. SPA route fallback is included for nested route refreshes.
- Optional TURN variables: `VITE_TURN_URLS`, `VITE_TURN_USERNAME`, `VITE_TURN_CREDENTIAL`. Use credentials from infrastructure you control; do not commit them.

## Supabase and retention notes

- Queue entries expire after 3 minutes. Match RPCs clean expired queue rows under a transaction lock and prevent a user from holding more than one active session.
- Active sessions expire after 2 hours. Ended session rows are cleaned after 24 hours; text messages are cleaned after 1 hour; completed reports after 90 days; pending reports remain for moderator action. Run `public.cleanup_expired_data()` periodically from a trusted scheduler/pg_cron if available. The queue is also cleaned during matchmaking.
- Text messages are persisted briefly to support Realtime delivery and can be read only by the two session participants. Message sends are validated and rate-limited by an RPC. Reports contain reason, reporter, target, and session references.
- WebRTC uses Google’s public STUN endpoint. STUN does not relay media. Peer connections can fail behind restrictive NAT/firewalls without TURN, so configure a TURN relay for dependable production connectivity. No TURN service is included in the free MVP.
- Supabase Free tier quotas, auth abuse limits, Realtime limits, and project pausing rules can change. Review the limits in your Supabase dashboard before launch. Free-tier traffic is not a reliability guarantee.

## Operational work before public launch

The current age check is self-attestation, not age verification. Build a robust adult-safety and abuse response process before opening to the public. Assign a moderator and define report response coverage. Disable demo Plus, configure a TURN provider if broad call connectivity is required, set the Supabase production URL allowlist, and choose a trusted scheduler for retention cleanup. No call recordings are made.
