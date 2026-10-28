# BST Planner: team setup (Supabase, free tier)

This takes about 15 minutes. You need a free [Supabase](https://supabase.com) account and a host for one static file. This repository is already published on GitHub Pages at <https://nikhilahuja-bright.github.io/bst-planner/>.

Here is how the pieces fit together:
- Supabase Postgres is the source of truth.
- Every browser keeps a local cache and a queue of pending changes, so the app also works offline.
- Changes reach everyone else within about a second through Supabase Realtime.

---

## 1. Create the Supabase project
1. Go to <https://supabase.com/dashboard> and choose **New project**.
2. Pick a name (e.g. `bst-planner`), set a database password, and choose the region closest to your team (e.g. *Central EU (Frankfurt)* or *South Asia (Mumbai)*).
3. Wait about 2 minutes until the project is ready.

## 2. Set OWNER_EMAIL and run the SQL
1. Open [`setup.sql`](setup.sql) and check **section 0** near the top. It is the only place the owner is configured:
   ```sql
   create or replace function public.app_owner_email() returns text ... as $$
     select 'nikhil.ahuja@thebrights.in'::text          -- ◀◀ OWNER_EMAIL
   $$;
   ```
   **Only the person who signs in with exactly this address can create boards** (the comparison ignores upper/lower case). Everyone else, including the very first person to sign in, has to be invited. Change the address there if someone else should own the planner.
2. In your project, open **SQL Editor**, then **New query**.
3. Paste the whole content of `setup.sql` and click **Run**. It should end with "Success. No rows returned".

To change the owner later, edit that one line and run the whole script again (or run only the `create or replace function public.app_owner_email()` statement). Boards that already exist keep their owners. The new address can create boards from then on, and the old one can't create new ones.

The script creates everything the app needs:
- **Tables:** `boards`, `board_members` (roles: `owner`, `editor`, `viewer`), `buckets`, `tasks` (checklist, attachments and so on as `jsonb`, plus an `order` column), `labels` and `comments`.
- **Audit columns** on every table: `created_at`, `created_by`, `updated_at`, `updated_by`. Triggers fill them from `auth.uid()`. The same trigger enforces last-write-wins: an update that carries an older `updated_at` than the stored row is skipped.
- **Row Level Security:**
  - Only board members can read.
  - Owners and editors can write; viewers are read-only.
  - Only owners can invite people, change roles or remove people.
  - Users who are not signed in get nothing.
  - The helper functions are `security definer`, which avoids RLS recursion.
- **Owner-only board creation.** `create_board()` and a direct `insert` into `boards` both check `is_app_owner()`: the signed-in user's **confirmed** e-mail must equal `OWNER_EMAIL`. Anyone else gets a permission error (HTTP 403), in the app and through the API. A trigger makes whoever creates a board its `owner` in `board_members`.
- **Pending email invites.** An invite for someone who has never signed in stays *pending* and is linked to their account as soon as they confirm their e-mail (by clicking the invitation or sign-in link).
- **Realtime publication** for all six tables, with `replica identity full`.

The script is idempotent: you can run it again later (for example after an update) without losing data.

## 3. Copy the project URL and the public key
In **Project Settings**, find:
- **Project URL**: shown on **Data API** (or the project's **Connect** dialog), e.g. `https://abcdefghijklmnop.supabase.co`.
- **Public key**: on **API Keys**, use either the **publishable** key (`sb_publishable_…`) or the legacy **`anon` `public`** key (`eyJ…`). Both work.

This key is designed to be public. It ships inside the web page, and the RLS policies from step 2 are what protect the data. **Never** put the `service_role` / secret key into the app.

## 4. Put the values into the app
Open `index.html` in a text editor (or edit it on GitHub) and change the two lines at the very top:
```js
const SUPABASE_URL = 'https://abcdefghijklmnop.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_…';   // or the eyJ… anon key
```
Only the project URL and the **public** (publishable / anon) key go here. The `service_role` / secret key never goes into `index.html` or anywhere else in this repository; it lives only in the Supabase Edge Function secrets (step 8).

While the placeholders are still in place, the app shows a **"Backend not configured"** screen (German: *"Backend nicht konfiguriert"*). That screen also offers "Use without sync", which runs the old single-browser mode.

## 5. Deploy (GitHub Pages)
This repository is served by GitHub Pages from the `main` branch, folder `/ (root)` (**Settings → Pages → Source: Deploy from a branch**). The `.nojekyll` file makes Pages serve the files as-is.

- **Live URL:** <https://nikhilahuja-bright.github.io/bst-planner/> (this is `index.html`).
- **To update the app:** commit a changed `index.html` to `main`. Pages republishes within a minute or two.
- **To connect the backend:** edit the two constants in `index.html` (step 4), commit, and wait for the Pages build to finish.

## 6. Authentication → URL Configuration (important)
Magic links only redirect back to addresses that are on this list. In Supabase, open **Authentication → URL Configuration** and set:

| Field | Value |
|---|---|
| **Site URL** | `https://nikhilahuja-bright.github.io/bst-planner/` |
| **Redirect URLs** | Add `https://nikhilahuja-bright.github.io/bst-planner/**` (this also covers `.../bst-planner/index.html`). Add `http://localhost:8080/**` too if you also test locally (`python3 -m http.server 8080`). |

The app sends `emailRedirectTo` = the exact page it was opened from, so that address must match one of these entries. If it doesn't, Supabase falls back to the Site URL.

**Invitation links use the same settings.** When the owner invites someone, the app passes its own address as `redirect_to` to the `invite-member` function (step 8). The function hands it to Supabase (`inviteUserByEmail(..., { redirectTo })`). If that address is not on the **Redirect URLs** list, the invite link lands on the **Site URL** instead, so set the Site URL to the real app address, not `localhost`. The e-mail text comes from **Authentication → Emails → Invite user** (it must keep `{{ .ConfirmationURL }}`).

Also check **Authentication → Sign In / Providers → Email**: email sign-in must be enabled. Leave **"Allow new users to sign up"** **on** unless the `invite-member` function is deployed. Without the function, invited teammates get their account when they first sign in with a magic link. People who sign up without an invite can't see anything, because RLS hides it from them; they get a "not invited" screen.

Optional hardening once the function is deployed: the owner signs in once (so the owner's account exists), then you turn sign-ups **off**. From then on, accounts are only created by invitations from the function.

Optional: to let people type a 6-digit code instead of clicking the link (useful when the link opens in a different browser), add `{{ .Token }}` to the **Magic Link** and **Confirm signup** templates under **Authentication → Emails**. The app's "Check your email" screen already has a code field.

## 7. First sign-in: the owner creates the board
1. Open the app URL, enter the **OWNER_EMAIL** address and click **Send magic link**.
2. Click the link in the email. You come back signed in and see **Create your board**.
3. Click **Create board**. You are now its **owner**.

Anyone else who signs in before being invited sees: *"…this email hasn't been invited to a board yet. Only the planner owner can create boards, and everyone else joins by invitation…"* with a **Check again** button. They have no **Create board** button, and the database refuses the API calls as well.
4. Optional: if you used the app before in this browser (local-only mode), open **Board menu (…) → Import my local data**. It uploads your old board once. All IDs become UUIDs, and buckets and labels are merged by name.

## 8. Deploy the `invite-member` Edge Function (invitation e-mails)
The function in [`supabase/functions/invite-member/index.ts`](supabase/functions/invite-member/index.ts) lets the **Invite** button send a real invitation e-mail. It:
1. checks the caller's JWT (the signed-in user's session token, which `supabase.functions.invoke` sends automatically);
2. checks that the caller is an **owner** of that board (otherwise **403**);
3. adds or updates the `board_members` row as the caller, so RLS and the audit columns apply;
4. calls `auth.admin.inviteUserByEmail(email, { redirectTo })`. If the address already has an account, it sends a normal sign-in (magic) link instead. If no e-mail can be sent, the person is still added and the app says so.

The admin key it needs (`SUPABASE_SERVICE_ROLE_KEY`) is provided **only in the function's environment on Supabase**. Supabase injects it automatically, so you never type it anywhere, and it is never in `index.html` or any other file in this repository.

**Option 1: Supabase CLI**
```bash
npm i -g supabase            # or: npx supabase …  /  brew install supabase/tap/supabase
supabase login
supabase link --project-ref <your-project-ref>       # the abcdefghijklmnop part of the URL
supabase functions deploy invite-member --no-verify-jwt
```
`--no-verify-jwt` is intended: the function verifies the caller's token itself (`auth.getUser`), returns clear JSON errors (401 / 403) and answers the browser's CORS pre-flight request, which carries no token.

**Option 2: Dashboard, no CLI**
1. **Edge Functions → Deploy a new function → Via Editor**.
2. Name it exactly **`invite-member`**, replace the sample code with the content of `index.ts`, then click **Deploy function**.
3. In the function's **Details / Settings**, turn **off** "Enforce JWT verification" (wording varies: "Verify JWT"), then save.

Test it: as the owner, invite your own second address and check that the e-mail arrives.

**If the function is not deployed** (or unreachable), the app still works. **Invite** adds the person directly to `board_members` (owners only, via RLS) and shows *"Automatic invitation emails aren't set up, so share the app link with them."*, plus the **Copy link** hint, exactly as before.

## 9. Invite teammates
1. Go to **Settings → Share / Invite**, or click the **Synced** pill in the top bar.
2. Enter an email address, pick a role (**Editor** or **Viewer**), and click **Invite**. The person also becomes a member on the Members list, so tasks can be assigned to them.
3. With the function deployed, they receive an **invitation e-mail**, or a sign-in link if they already have an account. A toast confirms which one was sent. Clicking the link signs them in and opens the board. People who are still *pending* have a **Resend invitation email** button (envelope icon).
4. Without the function, send them the app link (**Copy link**). They sign in with their email (magic link), and their pending invite is linked on that first sign-in.
5. From the same list, owners can change roles or remove people. The last owner can't be removed or demoted.

## Everyday use
- **Status pill in the top bar:**
  - **Synced**: everything is saved in Supabase.
  - **Saving…**: changes are being sent.
  - **Offline (n pending)**: you keep working, and the changes are stored in this browser and sent automatically when you reconnect.
  - **View only**: shown next to the status for viewers.
- **Conflicts:** last write wins, per task, bucket, label or comment, and per whole object. The task panel shows **"Last edited by …, time"**.
- **Backups:**
  - **Download backup** (board menu or Settings → Data) saves the board and the access list as JSON.
  - **Export JSON / CSV** work as before.
  - **Import JSON** replaces the board's content for everyone, so keep a backup first.

---

## Free-tier caveats
- **Email limits (sign-in links *and* invitation e-mails).** Invitations from the `invite-member` function go through the same Supabase mailer and count against the same limits. Without your own SMTP server, Supabase's built-in mailer:
  - sends **only to addresses that are members of your Supabase organization** (Organization settings → Team); everyone else gets "Email address not authorized";
  - sends **about 2 emails per hour** for the whole project.

  For a real team, set up **custom SMTP** under **Authentication → Emails → SMTP Settings** (older dashboards: Project Settings → Authentication). Resend, Brevo, Postmark, SendGrid and Amazon SES all have free tiers. After that, the limit starts at 30 emails per hour, and you can raise it under **Authentication → Rate Limits**. Separately, each address can request a new link only once every 60 seconds.
- **Sessions:** sessions last a long time (the refresh token renews them), so people rarely need a new link. Signing out, or using a new browser or device, needs a new link.
- **Project pausing:** free projects with almost no database activity for **7 days** are paused. You get a warning email first. A few requests a day from the app prevent this. To resume, go to Dashboard → project → **Resume project** (possible for up to a year). While the project is paused, the app shows **Offline** and keeps working from its cache. Pending changes sync once the project is back. Upgrading to Pro removes pausing.
- **Limits:** the free plan has 500 MB of database storage and 200 concurrent Realtime connections, which is far more than this board needs.
- **Backups:** free projects get no point-in-time recovery, so use **Download backup** now and then.

## Troubleshooting
| Symptom | Fix |
|---|---|
| "Backend not configured" screen | The constants are still placeholders, or the key is empty (step 4). |
| The link opens `localhost:3000`, or there's a "redirect" error | Step 6: add your app URL to Redirect URLs and set the Site URL. |
| "Email address not authorized" / "rate limit exceeded" | Built-in mailer limits; see caveats and set up custom SMTP. |
| "Not invited" screen | The owner must invite that exact email (Settings → Share / Invite). Then click **Check again**. |
| The owner has no **Create board** button | The signed-in address must equal `OWNER_EMAIL` in `setup.sql` (section 0). Fix it there and re-run the script. |
| *"Automatic invitation emails aren't set up"* after **Invite** | The `invite-member` function isn't deployed or isn't reachable (step 8). The person was still added; share the link. |
| Invite says *"…couldn't be emailed"* | The mailer refused the message (limits or "not authorized", see caveats). The person is added; set up SMTP or share the link. |
| `Invite failed: Only owners…` | Only board owners can invite (HTTP 403 from the function). |
| Invite link opens the wrong site | The app URL is missing from **Redirect URLs**, so Supabase used the **Site URL** (step 6). |
| Stuck on **Offline** while online | The project may be paused (resume it), or the URL or key is wrong. Check the browser console. |
| Live updates missing | Re-run `setup.sql`: it (re)adds the tables to the `supabase_realtime` publication. |
