-- =====================================================================
--  BST Planner – Supabase schema, security & realtime setup
--  1) Set OWNER_EMAIL in section 0 below.  2) Supabase Dashboard → SQL Editor →
--     New query → paste this file → Run.
--  It is idempotent: running it again is safe (it won't drop your data).
-- =====================================================================

create extension if not exists pgcrypto;

-- =====================================================================
--  0. CONFIGURATION ─ OWNER_EMAIL
--  The ONE account that may create boards (and so becomes their owner).
--  Everyone else gets access only by being invited (board_members).
--  Edit the e-mail on the marked line, then re-run this whole script.
--  The match is case-insensitive and needs a confirmed e-mail address.
-- =====================================================================
create or replace function public.app_owner_email()
returns text language sql immutable set search_path = '' as $$
  select 'nikhil.ahuja@thebrights.in'::text          -- ◀◀ OWNER_EMAIL
$$;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists public.boards (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'BST Board',
  members     jsonb not null default '[]'::jsonb,   -- assignable people (name, initials, color, email, avatar)
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_by  uuid references auth.users(id) on delete set null
);

create table if not exists public.board_members (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null references public.boards(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,   -- null = invite pending (not signed in yet)
  email       text not null,
  role        text not null default 'editor' check (role in ('owner','editor','viewer')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_by  uuid references auth.users(id) on delete set null,
  unique (board_id, email)
);
create index if not exists board_members_user_idx  on public.board_members(user_id);
create index if not exists board_members_email_idx on public.board_members(lower(email));

create table if not exists public.buckets (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null references public.boards(id) on delete cascade,
  name        text not null default '',
  sort_order  double precision not null default 0,
  color       text not null default '',
  collapsed   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_by  uuid references auth.users(id) on delete set null,
  unique (id, board_id)
);
create index if not exists buckets_board_idx on public.buckets(board_id);

create table if not exists public.labels (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null references public.boards(id) on delete cascade,
  name        text not null default '',
  color       text not null default '',
  sort_order  double precision not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_by  uuid references auth.users(id) on delete set null
);
create index if not exists labels_board_idx on public.labels(board_id);

create table if not exists public.tasks (
  id              uuid primary key default gen_random_uuid(),
  board_id        uuid not null references public.boards(id) on delete cascade,
  bucket_id       uuid,
  title           text not null default '',
  progress        text not null default 'notstarted',
  priority        text not null default 'medium',
  start_date      date,
  due_date        date,
  repeat          text not null default 'none',
  assignee_ids    jsonb not null default '[]'::jsonb,
  label_ids       jsonb not null default '[]'::jsonb,
  notes           text not null default '',
  checklist       jsonb not null default '[]'::jsonb,
  show_checklist  boolean not null default false,
  attachments     jsonb not null default '[]'::jsonb,
  sort_order      double precision not null default 0,
  completed_at    timestamptz,
  completed_by    text,           -- people id from boards.members
  creator_member  text,           -- people id from boards.members
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  updated_by      uuid references auth.users(id) on delete set null,
  unique (id, board_id),
  -- a task can only live in a bucket of the same board; deleting a bucket keeps the task
  foreign key (bucket_id, board_id) references public.buckets(id, board_id) on delete set null (bucket_id)
);
create index if not exists tasks_board_idx on public.tasks(board_id);

create table if not exists public.comments (
  id             uuid primary key default gen_random_uuid(),
  board_id       uuid not null references public.boards(id) on delete cascade,
  task_id        uuid not null,
  author_member  text,            -- people id from boards.members
  body           text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  updated_by     uuid references auth.users(id) on delete set null,
  foreign key (task_id, board_id) references public.tasks(id, board_id) on delete cascade
);
create index if not exists comments_board_idx on public.comments(board_id);
create index if not exists comments_task_idx  on public.comments(task_id);

-- ---------------------------------------------------------------------
-- 2. Audit + last-write-wins trigger (all tables)
--    * created_at / created_by are set on insert and never change
--    * updated_by = auth.uid() on every write
--    * updated_at: the client sends the (server-clock-corrected) time of the
--      edit; it is capped at now(). An UPDATE carrying an OLDER updated_at
--      than the stored row is silently skipped → last write wins, also for
--      edits that were queued while offline.
-- ---------------------------------------------------------------------
create or replace function public.bst_audit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.updated_at := least(coalesce(new.updated_at, now()), now());
    new.updated_by := coalesce(auth.uid(), new.updated_by);
    return new;
  end if;
  -- UPDATE
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  if new.updated_at is distinct from old.updated_at and new.updated_at < old.updated_at then
    return null;                      -- stale write: keep the newer row
  end if;
  if new.updated_at is not distinct from old.updated_at then
    new.updated_at := now();
  else
    new.updated_at := least(new.updated_at, now());
  end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['boards','board_members','buckets','labels','tasks','comments'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_audit', t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.bst_audit()', t || '_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Helper functions (SECURITY DEFINER → no RLS recursion on board_members)
-- ---------------------------------------------------------------------
create or replace function public.board_role(p_board uuid)
returns text language sql stable security definer set search_path = '' as $$
  select m.role from public.board_members m
  where m.board_id = p_board and m.user_id = auth.uid()
  limit 1
$$;

create or replace function public.is_board_member(p_board uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.board_members m
                 where m.board_id = p_board and m.user_id = auth.uid())
$$;

create or replace function public.can_edit_board(p_board uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.board_members m
                 where m.board_id = p_board and m.user_id = auth.uid()
                   and m.role in ('owner','editor'))
$$;

create or replace function public.is_board_owner(p_board uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.board_members m
                 where m.board_id = p_board and m.user_id = auth.uid()
                   and m.role = 'owner')
$$;

-- Is the signed-in user the configured OWNER_EMAIL (see section 0)?
create or replace function public.is_app_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users u
                 where u.id = auth.uid()
                   and u.email_confirmed_at is not null
                   and lower(trim(u.email)) = lower(trim(public.app_owner_email())))
$$;

-- Who may create a board? Only OWNER_EMAIL. Everyone else must be invited.
create or replace function public.can_create_board()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and public.is_app_owner()
$$;

-- Server clock (used by the app to correct client clock skew for last-write-wins)
create or replace function public.server_now()
returns timestamptz language sql stable as $$ select now() $$;

-- Link pending invites (user_id is null) to the signed-in user by e-mail.
create or replace function public.claim_invites()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_email text; n integer;
begin
  if auth.uid() is null then return 0; end if;
  select lower(u.email) into v_email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then return 0; end if;
  update public.board_members m set user_id = auth.uid()
   where m.user_id is null and lower(m.email) = v_email;
  get diagnostics n = row_count;
  return n;
end $$;

-- Create a board (OWNER_EMAIL only); the caller becomes its owner via the
-- boards_add_owner trigger below.
create or replace function public.create_board(p_id uuid, p_name text, p_members jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_create_board() then
    raise exception 'only the planner owner (OWNER_EMAIL) can create boards; ask them to invite you' using errcode = '42501';
  end if;
  insert into public.boards(id, name, members) values (coalesce(p_id, gen_random_uuid()), coalesce(nullif(p_name,''), 'BST Board'), coalesce(p_members, '[]'::jsonb))
  returning id into p_id;
  return p_id;
end $$;

-- Whoever inserts a board (create_board() or a direct insert allowed by the
-- boards_insert policy) becomes its owner.
create or replace function public.bst_boards_add_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_email text;
begin
  if auth.uid() is null then return new; end if;   -- service role / dashboard: no owner row
  select lower(u.email) into v_email from auth.users u where u.id = auth.uid();
  insert into public.board_members(board_id, user_id, email, role)
  values (new.id, auth.uid(), coalesce(v_email, ''), 'owner')
  on conflict (board_id, email) do update set role = 'owner', user_id = excluded.user_id;
  return new;
end $$;
drop trigger if exists boards_add_owner on public.boards;
create trigger boards_add_owner after insert on public.boards
  for each row execute function public.bst_boards_add_owner();

-- E-mails are stored lower-case; an invite for an existing, CONFIRMED account is
-- linked at once (accounts created by an invitation e-mail stay "pending" until
-- the person clicks the link and confirms their address).
create or replace function public.bst_board_members_before()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.email := lower(trim(new.email));
  if new.user_id is null then
    select u.id into new.user_id from auth.users u
     where lower(u.email) = new.email and u.email_confirmed_at is not null limit 1;
  end if;
  return new;
end $$;
drop trigger if exists board_members_link on public.board_members;
create trigger board_members_link before insert or update of email on public.board_members
  for each row execute function public.bst_board_members_before();

-- Never leave a board without an owner.
create or replace function public.bst_keep_one_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (tg_op = 'DELETE' and old.role = 'owner') or (tg_op = 'UPDATE' and old.role = 'owner' and new.role <> 'owner') then
    if exists (select 1 from public.boards b where b.id = old.board_id) -- board itself not being deleted
       and not exists (select 1 from public.board_members m
                       where m.board_id = old.board_id and m.role = 'owner' and m.id <> old.id) then
      raise exception 'a board needs at least one owner' using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists board_members_keep_owner on public.board_members;
create trigger board_members_keep_owner before update or delete on public.board_members
  for each row execute function public.bst_keep_one_owner();

-- Confirmed sign-ups (or e-mail changes) claim their pending invites automatically.
create or replace function public.bst_handle_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is not null and new.email_confirmed_at is not null then
    update public.board_members m set user_id = new.id
     where m.user_id is null and lower(m.email) = lower(new.email);
  end if;
  return new;
end $$;
drop trigger if exists bst_on_auth_user on auth.users;
create trigger bst_on_auth_user after insert or update of email, email_confirmed_at on auth.users
  for each row execute function public.bst_handle_auth_user();

-- ---------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------
alter table public.boards        enable row level security;
alter table public.board_members enable row level security;
alter table public.buckets       enable row level security;
alter table public.labels        enable row level security;
alter table public.tasks         enable row level security;
alter table public.comments      enable row level security;

-- boards: members read, owners/editors edit, owners delete; only OWNER_EMAIL creates
drop policy if exists boards_select on public.boards;
drop policy if exists boards_insert on public.boards;
drop policy if exists boards_update on public.boards;
drop policy if exists boards_delete on public.boards;
create policy boards_select on public.boards for select to authenticated using (public.is_board_member(id));
create policy boards_insert on public.boards for insert to authenticated with check (public.is_app_owner());
create policy boards_update on public.boards for update to authenticated using (public.can_edit_board(id)) with check (public.can_edit_board(id));
create policy boards_delete on public.boards for delete to authenticated using (public.is_board_owner(id));

-- board_members: members see the member list; only owners invite / change roles / remove
drop policy if exists bm_select on public.board_members;
drop policy if exists bm_insert on public.board_members;
drop policy if exists bm_update on public.board_members;
drop policy if exists bm_delete on public.board_members;
create policy bm_select on public.board_members for select to authenticated using (public.is_board_member(board_id));
create policy bm_insert on public.board_members for insert to authenticated with check (public.is_board_owner(board_id));
create policy bm_update on public.board_members for update to authenticated using (public.is_board_owner(board_id)) with check (public.is_board_owner(board_id));
create policy bm_delete on public.board_members for delete to authenticated using (public.is_board_owner(board_id));

-- content tables: members read, owners + editors write, viewers read-only
do $$
declare t text;
begin
  foreach t in array array['buckets','labels','tasks','comments'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_board_member(board_id))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_edit_board(board_id))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_edit_board(board_id)) with check (public.can_edit_board(board_id))', t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_edit_board(board_id))', t || '_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. Grants (anon gets nothing; signed-in users go through RLS)
-- ---------------------------------------------------------------------
revoke all on public.boards, public.board_members, public.buckets, public.labels, public.tasks, public.comments from anon;
grant select, insert, update, delete on public.boards, public.board_members, public.buckets, public.labels, public.tasks, public.comments to authenticated;
revoke execute on function public.board_role(uuid), public.is_board_member(uuid), public.can_edit_board(uuid), public.is_board_owner(uuid),
  public.can_create_board(), public.is_app_owner(), public.claim_invites(), public.create_board(uuid, text, jsonb), public.server_now() from public, anon;
grant execute on function public.board_role(uuid), public.is_board_member(uuid), public.can_edit_board(uuid), public.is_board_owner(uuid),
  public.can_create_board(), public.is_app_owner(), public.claim_invites(), public.create_board(uuid, text, jsonb), public.server_now() to authenticated;
revoke execute on function public.bst_handle_auth_user(), public.bst_board_members_before(), public.bst_keep_one_owner(), public.bst_boards_add_owner() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Realtime: publish all tables with full row images
-- ---------------------------------------------------------------------
alter table public.boards        replica identity full;
alter table public.board_members replica identity full;
alter table public.buckets       replica identity full;
alter table public.labels        replica identity full;
alter table public.tasks         replica identity full;
alter table public.comments      replica identity full;

do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['boards','board_members','buckets','labels','tasks','comments'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Done. Next: Authentication → URL Configuration (see SETUP.md).
