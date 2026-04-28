-- ============================================================
-- PART 1: Tables + Indexes
-- Run this FIRST
-- ============================================================

CREATE SCHEMA IF NOT EXISTS private;

-- ─── Users ───
CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  photo_url text,
  phone text,
  role text NOT NULL DEFAULT 'accountant' CHECK (role IN ('creator', 'accountant')),
  assigned_branch_ids text[] NOT NULL DEFAULT '{}',
  permissions jsonb NOT NULL DEFAULT '{
    "canTransfers": true,
    "canPurchases": true,
    "canManageTransfers": false,
    "canManagePurchases": false,
    "canBranchTopUp": false,
    "canClients": true,
    "canLedger": true,
    "canAnalytics": true,
    "canReports": true,
    "canExchangeRates": true,
    "canBranchesView": true
  }'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Branches ───
CREATE TABLE IF NOT EXISTS public.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL DEFAULT '',
  code text NOT NULL DEFAULT '',
  base_currency text NOT NULL DEFAULT 'USD',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Branch Accounts ───
CREATE TABLE IF NOT EXISTS public.branch_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT '',
  type text NOT NULL DEFAULT 'cash' CHECK (type IN ('cash', 'card', 'reserve', 'transit')),
  currency text NOT NULL DEFAULT 'USD',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Account Balances ───
CREATE TABLE IF NOT EXISTS public.account_balances (
  account_id uuid PRIMARY KEY REFERENCES public.branch_accounts(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  balance double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Transfers ───
CREATE TABLE IF NOT EXISTS public.transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_code text,
  from_branch_id uuid NOT NULL REFERENCES public.branches(id),
  to_branch_id uuid NOT NULL REFERENCES public.branches(id),
  from_account_id uuid NOT NULL REFERENCES public.branch_accounts(id),
  to_account_id text NOT NULL DEFAULT '',
  amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  transfer_parts jsonb,
  to_currency text,
  exchange_rate double precision NOT NULL DEFAULT 1,
  converted_amount double precision NOT NULL DEFAULT 0,
  commission double precision NOT NULL DEFAULT 0,
  commission_currency text NOT NULL DEFAULT 'USD',
  commission_type text NOT NULL DEFAULT 'fixed' CHECK (commission_type IN ('fixed', 'percentage')),
  commission_value double precision NOT NULL DEFAULT 0,
  commission_mode text NOT NULL DEFAULT 'fromSender' CHECK (commission_mode IN ('fromSender', 'fromTransfer', 'toReceiver')),
  description text,
  client_id text,
  sender_name text,
  sender_phone text,
  sender_info text,
  receiver_name text,
  receiver_phone text,
  receiver_info text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'issued', 'rejected', 'cancelled')),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  confirmed_by uuid,
  issued_by uuid,
  rejected_by uuid,
  rejection_reason text,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancellation_reason text,
  idempotency_key text NOT NULL,
  amendment_history jsonb DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_at timestamptz,
  issued_at timestamptz,
  rejected_at timestamptz
);

-- ─── Ledger Entries ───
CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  account_id uuid NOT NULL REFERENCES public.branch_accounts(id),
  type text NOT NULL CHECK (type IN ('debit', 'credit')),
  amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  reference_type text NOT NULL DEFAULT 'adjustment',
  reference_id text NOT NULL DEFAULT '',
  transaction_code text,
  description text NOT NULL DEFAULT '',
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Purchases ───
CREATE TABLE IF NOT EXISTS public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_code text NOT NULL DEFAULT '',
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  client_id text,
  client_name text,
  description text NOT NULL DEFAULT '',
  category text,
  total_amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  payments jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Deleted Purchases ───
CREATE TABLE IF NOT EXISTS public.deleted_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  original_purchase_id text NOT NULL,
  transaction_code text,
  branch_id uuid,
  client_id text,
  client_name text,
  description text,
  category text,
  total_amount double precision,
  currency text,
  payments jsonb,
  created_by_user_id uuid,
  original_created_at timestamptz,
  deleted_by_user_id uuid NOT NULL REFERENCES auth.users(id),
  deleted_by_user_name text,
  reason text,
  original_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Clients ───
CREATE TABLE IF NOT EXISTS public.clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_code text NOT NULL DEFAULT '',
  name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  country text NOT NULL DEFAULT '',
  currency text NOT NULL DEFAULT 'USD',
  branch_id text,
  wallet_currencies text[] NOT NULL DEFAULT '{}',
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Client Balances ───
CREATE TABLE IF NOT EXISTS public.client_balances (
  client_id uuid PRIMARY KEY REFERENCES public.clients(id) ON DELETE CASCADE,
  balances jsonb NOT NULL DEFAULT '{}'::jsonb,
  balance double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Client Transactions ───
CREATE TABLE IF NOT EXISTS public.client_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  transaction_code text,
  type text NOT NULL DEFAULT 'deposit' CHECK (type IN ('deposit', 'debit')),
  amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  balance_after double precision,
  description text,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Exchange Rates ───
CREATE TABLE IF NOT EXISTS public.exchange_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency text NOT NULL,
  to_currency text NOT NULL,
  rate double precision NOT NULL DEFAULT 0,
  set_by uuid NOT NULL REFERENCES auth.users(id),
  effective_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Notifications ───
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_branch_id text NOT NULL DEFAULT '',
  target_user_id uuid,
  type text NOT NULL DEFAULT 'systemAlert',
  title text NOT NULL DEFAULT '',
  body text NOT NULL DEFAULT '',
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Audit Logs ───
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL DEFAULT '',
  entity_type text NOT NULL DEFAULT '',
  entity_id text NOT NULL DEFAULT '',
  performed_by uuid NOT NULL REFERENCES auth.users(id),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip_address text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── System Audit Logs ───
CREATE TABLE IF NOT EXISTS public.system_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL DEFAULT '',
  entity_type text NOT NULL DEFAULT '',
  entity_id text NOT NULL DEFAULT '',
  performed_by uuid NOT NULL REFERENCES auth.users(id),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Commissions ───
CREATE TABLE IF NOT EXISTS public.commissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid REFERENCES public.transfers(id),
  branch_id uuid,
  amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  type text NOT NULL DEFAULT 'fixed',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Counters ───
CREATE TABLE IF NOT EXISTS public.counters (
  id text PRIMARY KEY,
  data jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ─── System Settings ───
CREATE TABLE IF NOT EXISTS public.system_settings (
  id text PRIMARY KEY DEFAULT 'general',
  session_duration_days int NOT NULL DEFAULT 7,
  data jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ─── User Sessions ───
CREATE TABLE IF NOT EXISTS public.user_sessions (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform text NOT NULL DEFAULT 'Unknown',
  device_type text NOT NULL DEFAULT 'Unknown',
  ip text,
  last_seen timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, id)
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_branches_active_name ON public.branches (is_active, name);
CREATE INDEX IF NOT EXISTS idx_branch_accounts_branch ON public.branch_accounts (branch_id, is_active, name);
CREATE INDEX IF NOT EXISTS idx_account_balances_branch ON public.account_balances (branch_id);

CREATE INDEX IF NOT EXISTS idx_transfers_from_branch ON public.transfers (from_branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_transfers_to_branch ON public.transfers (to_branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_transfers_status ON public.transfers (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_transfers_from_status ON public.transfers (from_branch_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_transfers_idempotency ON public.transfers (idempotency_key);

CREATE INDEX IF NOT EXISTS idx_ledger_branch ON public.ledger_entries (branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_account ON public.ledger_entries (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_branch_account ON public.ledger_entries (branch_id, account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_branch_reftype ON public.ledger_entries (branch_id, reference_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_ref ON public.ledger_entries (reference_type, reference_id);

CREATE INDEX IF NOT EXISTS idx_purchases_branch ON public.purchases (branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_purchases_client ON public.purchases (client_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_clients_active_name ON public.clients (is_active, name);

CREATE INDEX IF NOT EXISTS idx_client_transactions_client ON public.client_transactions (client_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_exchange_rates_pair ON public.exchange_rates (from_currency, to_currency, effective_at DESC);
CREATE INDEX IF NOT EXISTS idx_exchange_rates_from ON public.exchange_rates (from_currency, effective_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_branch ON public.notifications (target_branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_branch_unread ON public.notifications (target_branch_id, is_read, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON public.audit_logs (entity_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_performer ON public.audit_logs (performed_by, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON public.user_sessions (user_id, last_seen DESC);
