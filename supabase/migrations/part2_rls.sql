-- ============================================================
-- PART 2: Helper Functions + RLS Policies
-- Run this SECOND (after Part 1)
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
-- ROW LEVEL SECURITY
-- ============================================================

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
