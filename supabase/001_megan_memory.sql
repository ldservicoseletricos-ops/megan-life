create table if not exists public.megan_memories (
  id bigserial primary key,
  user_id text not null,
  role text not null,
  content text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_megan_memories_user_created
on public.megan_memories (user_id, created_at desc);

create table if not exists public.megan_feedback (
  id bigserial primary key,
  user_id text not null,
  feedback text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_megan_feedback_user_created
on public.megan_feedback (user_id, created_at desc);
