-- ============================================================
-- EthnoCount: Firebase → Supabase Migration
-- Full PostgreSQL Schema + RLS + Functions
-- ============================================================

-- ─── Private schema for security definer functions ───
CREATE SCHEMA IF NOT EXISTS private;


-- ============================================================
-- TABLES
-- ============================================================

-- ─── Users ───
CREATE TABLE public.users (
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
CREATE TABLE public.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL DEFAULT '',
  code text NOT NULL DEFAULT '',
  base_currency text NOT NULL DEFAULT 'USD',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Branch Accounts ───
CREATE TABLE public.branch_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT '',
  type text NOT NULL DEFAULT 'cash' CHECK (type IN ('cash', 'card', 'reserve', 'transit')),
  currency text NOT NULL DEFAULT 'USD',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Account Balances (denormalized) ───
CREATE TABLE public.account_balances (
  account_id uuid PRIMARY KEY REFERENCES public.branch_accounts(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  balance double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Transfers ───
CREATE TABLE public.transfers (
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
  idempotency_key text NOT NULL,
  amendment_history jsonb DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_at timestamptz,
  issued_at timestamptz,
  rejected_at timestamptz
);

-- ─── Ledger Entries ───
CREATE TABLE public.ledger_entries (
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
CREATE TABLE public.purchases (
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
CREATE TABLE public.deleted_purchases (
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
CREATE TABLE public.clients (
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
CREATE TABLE public.client_balances (
  client_id uuid PRIMARY KEY REFERENCES public.clients(id) ON DELETE CASCADE,
  balances jsonb NOT NULL DEFAULT '{}'::jsonb,
  balance double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Client Transactions ───
CREATE TABLE public.client_transactions (
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
CREATE TABLE public.exchange_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency text NOT NULL,
  to_currency text NOT NULL,
  rate double precision NOT NULL DEFAULT 0,
  set_by uuid NOT NULL REFERENCES auth.users(id),
  effective_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Notifications ───
CREATE TABLE public.notifications (
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
CREATE TABLE public.audit_logs (
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
CREATE TABLE public.system_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL DEFAULT '',
  entity_type text NOT NULL DEFAULT '',
  entity_id text NOT NULL DEFAULT '',
  performed_by uuid NOT NULL REFERENCES auth.users(id),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Commissions ───
CREATE TABLE public.commissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid REFERENCES public.transfers(id),
  branch_id uuid,
  amount double precision NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  type text NOT NULL DEFAULT 'fixed',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─── Counters ───
CREATE TABLE public.counters (
  id text PRIMARY KEY,
  data jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ─── System Settings ───
CREATE TABLE public.system_settings (
  id text PRIMARY KEY DEFAULT 'general',
  session_duration_days int NOT NULL DEFAULT 7,
  data jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ─── User Sessions ───
CREATE TABLE public.user_sessions (
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
-- HELPER FUNCTIONS (must come after tables)
-- ============================================================

-- ─── Helper: get current user role ───
CREATE OR REPLACE FUNCTION private.get_user_role()
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN (SELECT role FROM public.users WHERE id = auth.uid());
END;
$$;

-- ─── Helper: next transaction code ───
CREATE OR REPLACE FUNCTION private.next_transaction_code(prefix text, counter_key text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  yr int := extract(year FROM now())::int;
  field_key text := 'count_' || yr;
  next_val int;
BEGIN
  INSERT INTO public.counters (id, data)
  VALUES (counter_key, jsonb_build_object(field_key, 1))
  ON CONFLICT (id) DO UPDATE
    SET data = counters.data || jsonb_build_object(
      field_key,
      COALESCE((counters.data->>field_key)::int, 0) + 1
    );

  SELECT (data->>field_key)::int INTO next_val
  FROM public.counters WHERE id = counter_key;

  RETURN prefix || '-' || yr || '-' || lpad(next_val::text, 6, '0');
END;
$$;


-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_branches_active_name ON public.branches (is_active, name);
CREATE INDEX idx_branch_accounts_branch ON public.branch_accounts (branch_id, is_active, name);
CREATE INDEX idx_account_balances_branch ON public.account_balances (branch_id);

CREATE INDEX idx_transfers_from_branch ON public.transfers (from_branch_id, created_at DESC);
CREATE INDEX idx_transfers_to_branch ON public.transfers (to_branch_id, created_at DESC);
CREATE INDEX idx_transfers_status ON public.transfers (status, created_at DESC);
CREATE INDEX idx_transfers_from_status ON public.transfers (from_branch_id, status, created_at DESC);
CREATE INDEX idx_transfers_idempotency ON public.transfers (idempotency_key);

CREATE INDEX idx_ledger_branch ON public.ledger_entries (branch_id, created_at DESC);
CREATE INDEX idx_ledger_account ON public.ledger_entries (account_id, created_at DESC);
CREATE INDEX idx_ledger_branch_account ON public.ledger_entries (branch_id, account_id, created_at DESC);
CREATE INDEX idx_ledger_branch_reftype ON public.ledger_entries (branch_id, reference_type, created_at DESC);
CREATE INDEX idx_ledger_ref ON public.ledger_entries (reference_type, reference_id);

CREATE INDEX idx_purchases_branch ON public.purchases (branch_id, created_at DESC);
CREATE INDEX idx_purchases_client ON public.purchases (client_id, created_at DESC);

CREATE INDEX idx_clients_active_name ON public.clients (is_active, name);

CREATE INDEX idx_client_transactions_client ON public.client_transactions (client_id, created_at DESC);

CREATE INDEX idx_exchange_rates_pair ON public.exchange_rates (from_currency, to_currency, effective_at DESC);
CREATE INDEX idx_exchange_rates_from ON public.exchange_rates (from_currency, effective_at DESC);

CREATE INDEX idx_notifications_branch ON public.notifications (target_branch_id, created_at DESC);
CREATE INDEX idx_notifications_branch_unread ON public.notifications (target_branch_id, is_read, created_at DESC);

CREATE INDEX idx_audit_logs_entity ON public.audit_logs (entity_type, created_at DESC);
CREATE INDEX idx_audit_logs_performer ON public.audit_logs (performed_by, created_at DESC);

CREATE INDEX idx_user_sessions_user ON public.user_sessions (user_id, last_seen DESC);


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

-- Enable RLS on all tables
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deleted_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_sessions ENABLE ROW LEVEL SECURITY;

-- ─── Users ───
CREATE POLICY "users_select" ON public.users FOR SELECT TO authenticated USING (true);
CREATE POLICY "users_insert" ON public.users FOR INSERT TO authenticated
  WITH CHECK (
    id = auth.uid()
    OR private.get_user_role() IN ('creator', 'admin')
  );
CREATE POLICY "users_update" ON public.users FOR UPDATE TO authenticated
  USING (
    private.get_user_role() IN ('creator', 'admin')
    OR id = auth.uid()
  );
CREATE POLICY "users_delete" ON public.users FOR DELETE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin'));

-- ─── Branches ───
CREATE POLICY "branches_select" ON public.branches FOR SELECT TO authenticated USING (true);
CREATE POLICY "branches_insert" ON public.branches FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin'));
CREATE POLICY "branches_update" ON public.branches FOR UPDATE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin'));

-- ─── Branch Accounts ───
CREATE POLICY "branch_accounts_select" ON public.branch_accounts FOR SELECT TO authenticated USING (true);
CREATE POLICY "branch_accounts_insert" ON public.branch_accounts FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin'));
CREATE POLICY "branch_accounts_update" ON public.branch_accounts FOR UPDATE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin'));

-- ─── Account Balances ───
CREATE POLICY "account_balances_select" ON public.account_balances FOR SELECT TO authenticated USING (true);
CREATE POLICY "account_balances_all" ON public.account_balances FOR ALL TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin', 'accountant'));

-- ─── Transfers ───
CREATE POLICY "transfers_select" ON public.transfers FOR SELECT TO authenticated USING (true);
CREATE POLICY "transfers_insert" ON public.transfers FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin', 'accountant'));
CREATE POLICY "transfers_update" ON public.transfers FOR UPDATE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin', 'accountant'));

-- ─── Ledger Entries ───
CREATE POLICY "ledger_select" ON public.ledger_entries FOR SELECT TO authenticated USING (true);
CREATE POLICY "ledger_insert" ON public.ledger_entries FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin', 'accountant'));
CREATE POLICY "ledger_update" ON public.ledger_entries FOR UPDATE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin', 'accountant'));

-- ─── Purchases ───
CREATE POLICY "purchases_select" ON public.purchases FOR SELECT TO authenticated USING (true);
CREATE POLICY "purchases_insert" ON public.purchases FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin', 'accountant'));
CREATE POLICY "purchases_delete" ON public.purchases FOR DELETE TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin', 'accountant'));

-- ─── Deleted Purchases ───
CREATE POLICY "deleted_purchases_select" ON public.deleted_purchases FOR SELECT TO authenticated USING (true);
CREATE POLICY "deleted_purchases_insert" ON public.deleted_purchases FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'admin', 'accountant'));

-- ─── Clients ───
CREATE POLICY "clients_select" ON public.clients FOR SELECT TO authenticated USING (true);
CREATE POLICY "clients_insert" ON public.clients FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'accountant'));
CREATE POLICY "clients_update" ON public.clients FOR UPDATE TO authenticated
  USING (private.get_user_role() IN ('creator', 'accountant'));

-- ─── Client Balances ───
CREATE POLICY "client_balances_select" ON public.client_balances FOR SELECT TO authenticated USING (true);
CREATE POLICY "client_balances_all" ON public.client_balances FOR ALL TO authenticated
  USING (private.get_user_role() IN ('creator', 'accountant'));

-- ─── Client Transactions ───
CREATE POLICY "client_tx_select" ON public.client_transactions FOR SELECT TO authenticated USING (true);
CREATE POLICY "client_tx_insert" ON public.client_transactions FOR INSERT TO authenticated
  WITH CHECK (private.get_user_role() IN ('creator', 'accountant'));

-- ─── Exchange Rates ───
CREATE POLICY "rates_select" ON public.exchange_rates FOR SELECT TO authenticated USING (true);
CREATE POLICY "rates_insert" ON public.exchange_rates FOR INSERT TO authenticated WITH CHECK (true);

-- ─── Notifications ───
CREATE POLICY "notif_select" ON public.notifications FOR SELECT TO authenticated USING (true);
CREATE POLICY "notif_insert" ON public.notifications FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "notif_update" ON public.notifications FOR UPDATE TO authenticated USING (true);

-- ─── Audit Logs ───
CREATE POLICY "audit_select" ON public.audit_logs FOR SELECT TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin'));
CREATE POLICY "audit_insert" ON public.audit_logs FOR INSERT TO authenticated WITH CHECK (true);

-- ─── System Audit Logs ───
CREATE POLICY "sys_audit_select" ON public.system_audit_logs FOR SELECT TO authenticated
  USING (private.get_user_role() IN ('creator', 'admin'));

-- ─── Commissions ───
CREATE POLICY "commissions_select" ON public.commissions FOR SELECT TO authenticated USING (true);

-- ─── Counters ───
CREATE POLICY "counters_select" ON public.counters FOR SELECT TO authenticated USING (true);
CREATE POLICY "counters_all" ON public.counters FOR ALL TO authenticated USING (true);

-- ─── System Settings ───
CREATE POLICY "settings_select" ON public.system_settings FOR SELECT TO authenticated USING (true);
CREATE POLICY "settings_write" ON public.system_settings FOR ALL TO authenticated
  USING (private.get_user_role() = 'creator');

-- ─── User Sessions ───
CREATE POLICY "sessions_own" ON public.user_sessions FOR ALL TO authenticated
  USING (user_id = auth.uid());


-- ============================================================
-- RPC FUNCTIONS (replace Cloud Functions)
-- ============================================================

-- ─── Create Transfer (atomic) ───
CREATE OR REPLACE FUNCTION private.create_transfer(
  p_from_branch_id uuid,
  p_to_branch_id uuid,
  p_from_account_id uuid,
  p_to_account_id text DEFAULT '',
  p_to_currency text DEFAULT NULL,
  p_amount double precision DEFAULT 0,
  p_currency text DEFAULT 'USD',
  p_exchange_rate double precision DEFAULT 1,
  p_commission_type text DEFAULT 'fixed',
  p_commission_value double precision DEFAULT 0,
  p_commission_currency text DEFAULT 'USD',
  p_commission_mode text DEFAULT 'fromSender',
  p_idempotency_key text DEFAULT '',
  p_description text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_sender_phone text DEFAULT NULL,
  p_sender_info text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL,
  p_receiver_phone text DEFAULT NULL,
  p_receiver_info text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_commission double precision;
  v_total_debit double precision;
  v_from_balance double precision;
  v_code text;
  v_transfer_id uuid;
  v_resolved_to_currency text;
  v_receiver_amount double precision;
  v_converted double precision;
  v_dup_count int;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User must be authenticated';
  END IF;

  -- Check duplicate
  SELECT count(*) INTO v_dup_count FROM transfers WHERE idempotency_key = p_idempotency_key;
  IF v_dup_count > 0 THEN
    RAISE EXCEPTION 'Duplicate transfer — already exists';
  END IF;

  -- Compute commission
  IF p_commission_type = 'percentage' THEN
    v_commission := p_amount * p_commission_value / 100;
  ELSE
    v_commission := p_commission_value;
  END IF;

  IF p_commission_mode = 'fromSender' THEN
    v_total_debit := p_amount + v_commission;
  ELSE
    v_total_debit := p_amount;
  END IF;

  -- Check balance
  SELECT balance INTO v_from_balance FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  IF v_from_balance IS NULL THEN v_from_balance := 0; END IF;
  IF v_from_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %', round(v_from_balance::numeric, 0), round(v_total_debit::numeric, 0);
  END IF;

  -- Resolve to_currency
  v_resolved_to_currency := p_currency;
  IF p_to_account_id IS NOT NULL AND p_to_account_id != '' THEN
    SELECT currency INTO v_resolved_to_currency FROM branch_accounts WHERE id = p_to_account_id::uuid;
  ELSIF p_to_currency IS NOT NULL THEN
    v_resolved_to_currency := p_to_currency;
  END IF;

  -- Compute receiver amount
  IF p_commission_mode = 'fromTransfer' THEN
    v_receiver_amount := p_amount - v_commission;
  ELSIF p_commission_mode = 'toReceiver' THEN
    v_receiver_amount := p_amount + v_commission;
  ELSE
    v_receiver_amount := p_amount;
  END IF;
  v_converted := v_receiver_amount * p_exchange_rate;

  -- Generate code
  v_code := private.next_transaction_code('ELX', 'transactionCodes');

  -- Insert transfer
  v_transfer_id := gen_random_uuid();
  INSERT INTO transfers (
    id, transaction_code, from_branch_id, to_branch_id, from_account_id, to_account_id,
    amount, currency, to_currency, exchange_rate, converted_amount,
    commission, commission_currency, commission_type, commission_value, commission_mode,
    description, client_id,
    sender_name, sender_phone, sender_info,
    receiver_name, receiver_phone, receiver_info,
    status, created_by, idempotency_key, created_at
  ) VALUES (
    v_transfer_id, v_code, p_from_branch_id, p_to_branch_id, p_from_account_id, COALESCE(p_to_account_id, ''),
    p_amount, p_currency, v_resolved_to_currency, p_exchange_rate, v_converted,
    v_commission, p_commission_currency, p_commission_type, p_commission_value, p_commission_mode,
    p_description, p_client_id,
    p_sender_name, p_sender_phone, p_sender_info,
    p_receiver_name, p_receiver_phone, p_receiver_info,
    'pending', v_user_id, p_idempotency_key, now()
  );

  -- Debit sender
  UPDATE account_balances SET balance = balance - v_total_debit, updated_at = now()
  WHERE account_id = p_from_account_id;

  -- Ledger debit
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (p_from_branch_id, p_from_account_id, 'debit', v_total_debit, p_currency, 'transfer', v_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (ожидает подтверждения)', v_user_id);

  -- Notification
  INSERT INTO notifications (target_branch_id, type, title, body, data)
  VALUES (p_to_branch_id::text, 'incoming_transfer', 'Новый входящий перевод',
          'Перевод ' || v_code || ': ' || p_amount || ' ' || p_currency || ' ожидает подтверждения.',
          jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code));

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;

-- ─── Confirm Transfer ───
CREATE OR REPLACE FUNCTION private.confirm_transfer(
  p_transfer_id uuid,
  p_to_account_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_effective_to text;
  v_to_currency text;
  v_acc_currency text;
  v_current_balance double precision;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'pending' THEN RAISE EXCEPTION 'Transfer not in pending state'; END IF;

  v_effective_to := CASE
    WHEN v_transfer.to_account_id != '' THEN v_transfer.to_account_id
    ELSE COALESCE(p_to_account_id, '')
  END;
  IF v_effective_to = '' THEN
    RAISE EXCEPTION 'Счёт получателя не указан';
  END IF;

  v_to_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);

  -- Validate account currency
  SELECT currency INTO v_acc_currency FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_transfer.to_currency IS NOT NULL AND v_transfer.to_currency != '' AND v_acc_currency != v_transfer.to_currency THEN
    RAISE EXCEPTION 'Счёт получателя в валюте %, перевод оформлен в %', v_acc_currency, v_transfer.to_currency;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

  -- Update transfer
  UPDATE transfers SET
    status = 'confirmed',
    confirmed_by = v_user_id,
    confirmed_at = now(),
    to_account_id = CASE WHEN to_account_id = '' THEN v_effective_to ELSE to_account_id END,
    to_currency = COALESCE(v_to_currency, to_currency)
  WHERE id = p_transfer_id;

  -- Credit receiver
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_effective_to::uuid, v_transfer.to_branch_id, v_transfer.converted_amount, COALESCE(v_acc_currency, v_to_currency), now())
  ON CONFLICT (account_id) DO UPDATE SET balance = account_balances.balance + v_transfer.converted_amount, updated_at = now();

  -- Ledger credit
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_transfer.to_branch_id, v_effective_to::uuid, 'credit', v_transfer.converted_amount, COALESCE(v_acc_currency, v_to_currency),
          'transfer', p_transfer_id::text, v_code, 'Перевод ' || v_code || ' (подтверждён)', v_user_id);

  -- Update sender ledger description
  UPDATE ledger_entries SET description = 'Перевод ' || v_code || ' (подтверждён)'
  WHERE ctid = (
    SELECT ctid FROM ledger_entries
    WHERE reference_type = 'transfer' AND reference_id = p_transfer_id::text
      AND branch_id = v_transfer.from_branch_id
    LIMIT 1
  );

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_confirmed', 'Перевод подтверждён',
     'Ваш перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' подтверждён.',
     jsonb_build_object('transferId', p_transfer_id::text)),
    (v_transfer.to_branch_id::text, 'transfer_confirmed', 'Перевод подтверждён',
     'Перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' подтверждён.',
     jsonb_build_object('transferId', p_transfer_id::text));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Reject Transfer ───
CREATE OR REPLACE FUNCTION private.reject_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_total double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'pending' THEN RAISE EXCEPTION 'Transfer not in pending state'; END IF;

  IF v_transfer.commission_mode = 'fromSender' THEN
    v_total := v_transfer.amount + v_transfer.commission;
  ELSE
    v_total := v_transfer.amount;
  END IF;

  -- Update status
  UPDATE transfers SET status = 'rejected', rejected_by = v_user_id, rejection_reason = p_reason, rejected_at = now()
  WHERE id = p_transfer_id;

  -- Refund
  UPDATE account_balances SET balance = balance + v_total, updated_at = now()
  WHERE account_id = v_transfer.from_account_id;

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_rejected', 'Перевод отклонён',
     'Ваш перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' отклонён. Причина: ' || p_reason,
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason)),
    (v_transfer.to_branch_id::text, 'transfer_rejected', 'Перевод отклонён',
     'Перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' отклонён.',
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Issue Transfer ───
CREATE OR REPLACE FUNCTION private.issue_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'confirmed' THEN RAISE EXCEPTION 'Transfer must be confirmed first'; END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET status = 'issued', issued_by = v_user_id, issued_at = now()
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_issued', 'Перевод выдан',
     'Перевод ' || v_code || ' (' || v_transfer.amount || ' ' || v_transfer.currency || ') выдан получателю.',
     jsonb_build_object('transferId', p_transfer_id::text)),
    (v_transfer.to_branch_id::text, 'transfer_issued', 'Перевод выдан',
     'Перевод ' || v_code || ' (' || v_transfer.amount || ' ' || v_transfer.currency || ') выдан получателю.',
     jsonb_build_object('transferId', p_transfer_id::text));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Create Purchase (atomic) ───
CREATE OR REPLACE FUNCTION private.create_purchase(
  p_branch_id uuid,
  p_description text,
  p_total_amount double precision,
  p_currency text,
  p_payments jsonb,
  p_client_id text DEFAULT NULL,
  p_client_name text DEFAULT NULL,
  p_category text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text;
  v_purchase_id uuid;
  v_payment jsonb;
  v_account_id uuid;
  v_amount double precision;
  v_cur_balance double precision;
  v_acc_currency text;
  v_acc_branch uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_code := private.next_transaction_code('ETH-TX', 'transactionCodes');
  v_purchase_id := gen_random_uuid();

  INSERT INTO purchases (id, transaction_code, branch_id, client_id, client_name, description, category, total_amount, currency, payments, created_by)
  VALUES (v_purchase_id, v_code, p_branch_id, p_client_id, p_client_name, p_description, p_category, p_total_amount, p_currency, p_payments, v_user_id);

  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    v_account_id := (v_payment->>'accountId')::uuid;
    v_amount := (v_payment->>'amount')::double precision;

    SELECT balance INTO v_cur_balance FROM account_balances WHERE account_id = v_account_id FOR UPDATE;
    IF v_cur_balance IS NULL THEN v_cur_balance := 0; END IF;
    IF v_cur_balance < v_amount THEN
      RAISE EXCEPTION 'Insufficient balance in account %', v_payment->>'accountName';
    END IF;

    SELECT currency, branch_id INTO v_acc_currency, v_acc_branch FROM branch_accounts WHERE id = v_account_id;

    UPDATE account_balances SET balance = balance - v_amount, updated_at = now() WHERE account_id = v_account_id;

    INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
    VALUES (COALESCE(v_acc_branch, p_branch_id), v_account_id, 'debit', v_amount, COALESCE(v_acc_currency, p_currency),
            'purchase', v_purchase_id::text, v_code, 'Покупка ' || v_code || ': ' || p_description, v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'purchaseId', v_purchase_id::text);
END;
$$;

-- ─── Create Client ───
CREATE OR REPLACE FUNCTION private.create_client(
  p_name text,
  p_phone text,
  p_country text,
  p_currency text,
  p_branch_id text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text;
  v_client_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_code := private.next_transaction_code('CL', 'clientCodes');
  v_client_id := gen_random_uuid();

  INSERT INTO clients (id, client_code, name, phone, country, currency, branch_id, wallet_currencies, is_active, created_by)
  VALUES (v_client_id, v_code, trim(p_name), trim(p_phone), COALESCE(trim(p_country), ''), trim(p_currency), trim(p_branch_id), ARRAY[trim(p_currency)], true, v_user_id);

  INSERT INTO client_balances (client_id, balances, balance, currency)
  VALUES (v_client_id, jsonb_build_object(trim(p_currency), 0), 0, trim(p_currency));

  RETURN jsonb_build_object('success', true, 'clientId', v_client_id::text);
END;
$$;

-- ─── Deposit Client ───
CREATE OR REPLACE FUNCTION private.deposit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Пополнение счёта',
  p_currency text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client clients%ROWTYPE;
  v_target_cur text;
  v_balances jsonb;
  v_cur_bal double precision;
  v_primary_bal double precision;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Client not found'; END IF;
  IF NOT v_client.is_active THEN RAISE EXCEPTION 'Client account is inactive'; END IF;

  v_target_cur := COALESCE(NULLIF(trim(p_currency), ''), v_client.currency);

  SELECT balances INTO v_balances FROM client_balances WHERE client_id = p_client_id FOR UPDATE;
  IF v_balances IS NULL THEN v_balances := '{}'::jsonb; END IF;

  v_cur_bal := COALESCE((v_balances->>v_target_cur)::double precision, 0);
  v_balances := v_balances || jsonb_build_object(v_target_cur, round((v_cur_bal + p_amount)::numeric, 2));
  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  v_code := private.next_transaction_code('ETH-TX', 'transactionCodes');

  UPDATE client_balances SET balances = v_balances, balance = round(v_primary_bal::numeric, 2), currency = v_client.currency, updated_at = now()
  WHERE client_id = p_client_id;

  UPDATE clients SET wallet_currencies = array_append(wallet_currencies, v_target_cur) WHERE id = p_client_id AND NOT (v_target_cur = ANY(wallet_currencies));

  INSERT INTO client_transactions (client_id, transaction_code, type, amount, currency, balance_after, description, created_by)
  VALUES (p_client_id, v_code, 'deposit', round(p_amount::numeric, 2), v_target_cur, round((v_cur_bal + p_amount)::numeric, 2),
          COALESCE(NULLIF(trim(p_description), ''), 'Пополнение счёта'), v_user_id);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Debit Client ───
CREATE OR REPLACE FUNCTION private.debit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Списание со счёта',
  p_currency text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client clients%ROWTYPE;
  v_target_cur text;
  v_balances jsonb;
  v_cur_bal double precision;
  v_primary_bal double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Client not found'; END IF;
  IF NOT v_client.is_active THEN RAISE EXCEPTION 'Client account is inactive'; END IF;

  v_target_cur := COALESCE(NULLIF(trim(p_currency), ''), v_client.currency);

  SELECT balances INTO v_balances FROM client_balances WHERE client_id = p_client_id FOR UPDATE;
  IF v_balances IS NULL THEN v_balances := '{}'::jsonb; END IF;

  v_cur_bal := COALESCE((v_balances->>v_target_cur)::double precision, 0);
  IF v_cur_bal < p_amount THEN RAISE EXCEPTION 'Insufficient client balance'; END IF;

  v_balances := v_balances || jsonb_build_object(v_target_cur, round((v_cur_bal - p_amount)::numeric, 2));
  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  UPDATE client_balances SET balances = v_balances, balance = round(v_primary_bal::numeric, 2), updated_at = now()
  WHERE client_id = p_client_id;

  INSERT INTO client_transactions (client_id, type, amount, currency, balance_after, description, created_by)
  VALUES (p_client_id, 'debit', round(p_amount::numeric, 2), v_target_cur, round((v_cur_bal - p_amount)::numeric, 2),
          COALESCE(NULLIF(trim(p_description), ''), 'Списание со счёта'), v_user_id);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Set Exchange Rate ───
CREATE OR REPLACE FUNCTION private.set_exchange_rate(
  p_from_currency text,
  p_to_currency text,
  p_rate double precision
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_rate_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_rate_id := gen_random_uuid();
  INSERT INTO exchange_rates (id, from_currency, to_currency, rate, set_by, effective_at)
  VALUES (v_rate_id, p_from_currency, p_to_currency, p_rate, v_user_id, now());

  INSERT INTO audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('set_exchange_rate', 'exchangeRate', v_rate_id::text, v_user_id,
          jsonb_build_object('fromCurrency', p_from_currency, 'toCurrency', p_to_currency, 'rate', p_rate));

  RETURN jsonb_build_object('success', true);
END;
$$;


-- ============================================================
-- Enable Realtime for key tables
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.transfers;
ALTER PUBLICATION supabase_realtime ADD TABLE public.branches;
ALTER PUBLICATION supabase_realtime ADD TABLE public.branch_accounts;
ALTER PUBLICATION supabase_realtime ADD TABLE public.account_balances;
ALTER PUBLICATION supabase_realtime ADD TABLE public.ledger_entries;
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
ALTER PUBLICATION supabase_realtime ADD TABLE public.clients;
ALTER PUBLICATION supabase_realtime ADD TABLE public.exchange_rates;
ALTER PUBLICATION supabase_realtime ADD TABLE public.purchases;
