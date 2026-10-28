# BST Planner

A single-file clone of the Microsoft Teams / Planner **Tasks → Board** experience (English and German) that syncs live between teammates through a free [Supabase](https://supabase.com) backend.

**Live app:** <https://nikhilahuja-bright.github.io/bst-planner/>

## Setup
See [SETUP.md](SETUP.md) for the full walkthrough: create the Supabase project, run [`setup.sql`](setup.sql), configure the auth redirect URLs, and deploy the [`invite-member`](supabase/functions/invite-member/index.ts) Edge Function.

Until the backend is connected, the live page shows a **"Backend not configured"** screen. You can still choose **Use without sync** there (data stays in that browser only).

## Keys
- The Supabase **project URL** and **public (publishable / anon) key** go into the two constants at the top of [`index.html`](index.html): `SUPABASE_URL` and `SUPABASE_ANON_KEY`. The public key is meant to ship in the page; Row Level Security protects the data.
- The **`service_role` / secret key** never goes into `index.html` or this repository. It exists only in the Supabase Edge Function secrets (`SUPABASE_SERVICE_ROLE_KEY`, injected by Supabase).

## Files
- `index.html` – the whole app (CDN scripts: supabase-js, SortableJS, Chart.js)
- `setup.sql` – database schema, RLS policies and realtime setup
- `SETUP.md` – setup and deployment guide
- `supabase/functions/invite-member/index.ts` – Edge Function that sends invitation e-mails
