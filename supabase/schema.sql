-- PromptBattle production schema (Supabase / PostgreSQL)
-- Double-entry wallets: balances live on wallets, every move appends to ledger.
-- Money in integer cents. Escrow: entry locked (state='escrow') then settled.

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  email text,
  deposited_cents int default 0,   -- lifetime deposits (Sybil weight signal)
  matches_played int default 0,
  created_at timestamptz default now()
);

create table if not exists wallets (
  user_id uuid primary key references profiles(id) on delete cascade,
  credits_cents int not null default 0,  -- entry credits (Stripe/Bizum/ApplePay)
  cash_cents int not null default 0,     -- withdrawable winnings
  updated_at timestamptz default now(),
  constraint non_negative check (credits_cents >= 0 and cash_cents >= 0)
);

create table if not exists ledger (
  id bigserial primary key,
  user_id uuid references profiles(id),
  kind text not null,       -- deposit, escrow_lock, escrow_refund, prize, platform_fee, withdrawal, generation
  amount_cents int not null,-- signed: + credit, - debit; separate columns per wallet below
  wallet text not null,     -- 'credits' | 'cash' | 'platform'
  state text not null default 'settled', -- escrow | settled | paid
  room_id bigint,
  meta jsonb default '{}',
  created_at timestamptz default now()
);

create table if not exists rooms (
  id bigserial primary key,
  size int not null check (size in (5, 25)),
  entry_cents int not null check (entry_cents between 200 and 1000),
  kind text not null default 'prompt', -- prompt | design
  theme text not null,                  -- revealed only when state='live'
  state text not null default 'lobby',  -- lobby | live | voting | settled
  starts_at timestamptz, ends_at timestamptz, voting_ends_at timestamptz,
  pool_cents int default 0, rake_cents int default 0, prizes_cents int default 0,
  created_at timestamptz default now()
);

create table if not exists entries (
  id bigserial primary key,
  room_id bigint references rooms(id) on delete cascade,
  user_id uuid references profiles(id),
  escrow_cents int not null,
  votes_cast int default 0,
  qualified boolean default false,  -- votes_cast >= 10 at settlement
  unique(room_id, user_id)
);

create table if not exists submissions (
  id bigserial primary key,
  room_id bigint references rooms(id) on delete cascade,
  user_id uuid references profiles(id),
  image_url text not null,   -- Supabase Storage path
  prompt text,
  generations_used int default 1 check (generations_used <= 3),
  elo int default 1500,
  wins int default 0, losses int default 0,
  created_at timestamptz default now(),
  unique(room_id, user_id)
);

create table if not exists votes (
  id bigserial primary key,
  room_id bigint references rooms(id) on delete cascade,
  voter uuid references profiles(id),
  a_id bigint references submissions(id) on delete cascade,
  b_id bigint references submissions(id) on delete cascade,
  winner_id bigint references submissions(id),
  weight numeric not null default 0.5, -- 1.0 if verified (deposit or matches>0)
  created_at timestamptz default now(),
  check (a_id <> b_id)
  -- anti-self-vote + 10-vote rule enforced in API (not just RLS)
);

create table if not exists payouts (
  id bigserial primary key,
  room_id bigint references rooms(id),
  user_id uuid references profiles(id),
  place int check (place between 1 and 3),
  amount_cents int not null,
  rail text, -- sepa | paypal | tremendous
  status text default 'credited', -- credited | paid
  created_at timestamptz default now()
);

-- Example settlement math (run in a SERIALIZABLE transaction, server-side):
-- pool = size * entry; rake = round(pool*0.20); prizes = pool - rake;
-- p1 = round(prizes*0.50); p2 = round(prizes*0.30); p3 = round(prizes*0.20);
-- Bradley-Terry/Elo from votes ordered by created_at, K=24*weight.
-- Only entries with votes_cast>=10 are eligible; others forfeit.
-- Credit wallets.cash_cents, insert ledger rows (prize + platform_fee), payouts rows.

-- Storage: create bucket `submissions` (public read, authenticated insert, 5MB limit, png/jpeg only).
-- Auth: enable Google provider in Supabase Auth; 1-click Gmail login.
-- Cron: pg_cron job to close rooms (ends_at -> voting, voting_ends_at -> settle via edge function).
