-- =====================================================================
--  BST Planner – migration v3 (Microsoft To Do / Planner upgrade)
--
--  ADDITIVE ONLY. This script never drops, renames or recreates a table
--  or column and never updates or deletes existing rows. It is
--  idempotent: running it twice is safe.
--
--  What it adds:
--    1. tasks.is_important  – the shared "star / Mark as important" flag
--    2. public.my_day       – each person's own "My Day" list (per user,
--                             per day; only the owner of a row can see it)
--    3. Row Level Security, grants, audit trigger and Realtime for my_day
--
--  NOT needed (already in your schema, reused as-is):
--    * subtasks          → the existing tasks.checklist jsonb items
--                          (optional due date / assignee are stored inside
--                          each item, so old checklist items show up as-is)
--    * subtask display   → the existing boards.settings jsonb
--    * bucket colour     → the existing buckets.color column
--    * created / creator → the existing tasks.created_at, created_by,
--                          creator_member and updated_at, updated_by
--
--  How to run: Supabase Dashboard → SQL Editor → New query → paste this
--  whole file → Run. Expected result: "Success. No rows returned".
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. tasks.is_important (new column, default false for every task)
-- ---------------------------------------------------------------------
alter table public.tasks add column if not exists is_important boolean not null default false;

-- ---------------------------------------------------------------------
-- 2. my_day: which tasks a person put on "My Day" for a given date
--    The app only shows rows for today's date, so the list "resets" daily
--    by itself (no cron job needed; old rows are simply ignored).
-- ---------------------------------------------------------------------
create table if not exists public.my_day (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null references public.boards(id) on delete cascade,
  task_id     uuid not null,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day         date not null default current_date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_by  uuid references auth.users(id) on delete set null,
  unique (user_id, task_id, day),
  -- the task must be on the same board; deleting a task removes it from My Day
  foreign key (task_id, board_id) references public.tasks(id, board_id) on delete cascade
);
create index if not exists my_day_user_day_idx on public.my_day(user_id, day);
create index if not exists my_day_board_idx    on public.my_day(board_id);
create index if not exists my_day_task_idx     on public.my_day(task_id);

-- Same audit trigger as every other table (created_*/updated_* columns)
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'my_day_audit' and tgrelid = 'public.my_day'::regclass) then
    create trigger my_day_audit before insert or update on public.my_day
      for each row execute function public.bst_audit();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Row Level Security for my_day
--    Same membership rule as the other tables (public.is_board_member),
--    plus: a person only ever sees and changes their OWN My Day rows.
--    Viewers may use My Day too (it is personal and changes no task).
-- ---------------------------------------------------------------------
alter table public.my_day enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'my_day' and policyname = 'my_day_select') then
    create policy my_day_select on public.my_day for select to authenticated
      using (user_id = auth.uid() and public.is_board_member(board_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'my_day' and policyname = 'my_day_insert') then
    create policy my_day_insert on public.my_day for insert to authenticated
      with check (user_id = auth.uid() and public.is_board_member(board_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'my_day' and policyname = 'my_day_update') then
    create policy my_day_update on public.my_day for update to authenticated
      using (user_id = auth.uid() and public.is_board_member(board_id))
      with check (user_id = auth.uid() and public.is_board_member(board_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'my_day' and policyname = 'my_day_delete') then
    create policy my_day_delete on public.my_day for delete to authenticated
      using (user_id = auth.uid() and public.is_board_member(board_id));
  end if;
end $$;

-- Grants: anon gets nothing; signed-in users go through RLS (as for the other tables)
revoke all on public.my_day from anon;
grant select, insert, update, delete on public.my_day to authenticated;

-- ---------------------------------------------------------------------
-- 4. Realtime: publish my_day, skip if already added. (Default replica
--    identity on purpose: a DELETE event then only carries the row id, so
--    nobody can see which tasks another person had on their My Day.)
-- ---------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'my_day') then
    alter publication supabase_realtime add table public.my_day;
  end if;
end $$;

-- Make the API (PostgREST) see the new column and table right away
notify pgrst, 'reload schema';

-- Done. Optional check (run separately):
--   select
--     (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'is_important') as is_important_column,
--     (select count(*) from information_schema.tables  where table_schema = 'public' and table_name = 'my_day') as my_day_table,
--     (select count(*) from pg_policies where schemaname = 'public' and tablename = 'my_day') as my_day_policies,
--     (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'my_day') as my_day_realtime,
--     (select count(*) from public.tasks) as tasks_still_there;
--   Expected: 1 | 1 | 4 | 1 | <your number of tasks, unchanged>
