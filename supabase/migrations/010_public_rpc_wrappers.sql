-- ============================================================
-- 010: Public RPC wrappers for PostgREST
-- ============================================================
-- PostgREST (supabase-js / supabase-flutter `client.rpc(...)`) resolves
-- function names in the `public` schema. All business-logic RPCs live in
-- `private` (see part3_functions.sql, 005, 006, 007). Until now the only
-- thing exposed in `public` were the signup trigger helpers, so every
-- client-side `rpc('<name>')` failed with PGRST202.
--
-- This migration adds one thin `public.<name>` wrapper per RPC that the
-- Dart client calls (`lib/data/datasources/remote/*_remote_ds.dart`). Each
-- wrapper is SECURITY DEFINER so callers never need direct access to the
-- `private` schema — `authenticated` and `service_role` only get EXECUTE
-- on the public wrappers, and authorization / business rules continue to
-- run inside `private.*`.
--
-- Idempotent — safe to re-run.
-- ============================================================

-- ─── clients ───
CREATE OR REPLACE FUNCTION public.create_client(
  p_name text, p_phone text, p_country text, p_currency text, p_branch_id text
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.create_client(p_name, p_phone, p_country, p_currency, p_branch_id) $$;

CREATE OR REPLACE FUNCTION public.deposit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Пополнение счёта',
  p_currency text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.deposit_client(p_client_id, p_amount, p_description, p_currency) $$;

CREATE OR REPLACE FUNCTION public.debit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Списание со счёта',
  p_currency text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.debit_client(p_client_id, p_amount, p_description, p_currency) $$;

-- ─── exchange rate ───
CREATE OR REPLACE FUNCTION public.set_exchange_rate(
  p_from_currency text, p_to_currency text, p_rate double precision
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.set_exchange_rate(p_from_currency, p_to_currency, p_rate) $$;

-- ─── ledger / balances ───
CREATE OR REPLACE FUNCTION public.adjust_balance(
  p_branch_id uuid,
  p_account_id uuid,
  p_amount double precision,
  p_currency text,
  p_type text,
  p_reference_type text,
  p_reference_id text DEFAULT '',
  p_transaction_code text DEFAULT NULL,
  p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.adjust_balance(
  p_branch_id, p_account_id, p_amount, p_currency, p_type,
  p_reference_type, p_reference_id, p_transaction_code, p_description
) $$;

CREATE OR REPLACE FUNCTION public.import_bank_transactions(
  p_branch_id uuid, p_account_id uuid, p_entries jsonb
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.import_bank_transactions(p_branch_id, p_account_id, p_entries) $$;

-- ─── purchases ───
CREATE OR REPLACE FUNCTION public.create_purchase(
  p_branch_id uuid,
  p_description text,
  p_total_amount double precision,
  p_currency text,
  p_payments jsonb,
  p_client_id text DEFAULT NULL,
  p_client_name text DEFAULT NULL,
  p_category text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.create_purchase(
  p_branch_id, p_description, p_total_amount, p_currency,
  p_payments, p_client_id, p_client_name, p_category
) $$;

CREATE OR REPLACE FUNCTION public.update_purchase(
  p_purchase_id uuid,
  p_total_amount double precision DEFAULT NULL,
  p_payments jsonb DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_category text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.update_purchase(
  p_purchase_id, p_total_amount, p_payments, p_description, p_category
) $$;

CREATE OR REPLACE FUNCTION public.delete_purchase(
  p_purchase_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.delete_purchase(p_purchase_id, p_reason) $$;

-- ─── transfers ───
CREATE OR REPLACE FUNCTION public.create_transfer(
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
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.create_transfer(
  p_from_branch_id, p_to_branch_id, p_from_account_id, p_to_account_id,
  p_to_currency, p_amount, p_currency, p_exchange_rate,
  p_commission_type, p_commission_value, p_commission_currency, p_commission_mode,
  p_idempotency_key, p_description, p_client_id,
  p_sender_name, p_sender_phone, p_sender_info,
  p_receiver_name, p_receiver_phone, p_receiver_info
) $$;

CREATE OR REPLACE FUNCTION public.confirm_transfer(
  p_transfer_id uuid,
  p_to_account_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.confirm_transfer(p_transfer_id, p_to_account_id) $$;

CREATE OR REPLACE FUNCTION public.reject_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT ''
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.reject_transfer(p_transfer_id, p_reason) $$;

CREATE OR REPLACE FUNCTION public.issue_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.issue_transfer(p_transfer_id) $$;

CREATE OR REPLACE FUNCTION public.cancel_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT ''
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.cancel_transfer(p_transfer_id, p_reason) $$;

CREATE OR REPLACE FUNCTION public.update_transfer_amount(
  p_transfer_id uuid,
  p_new_amount double precision,
  p_new_exchange_rate double precision DEFAULT NULL,
  p_amendment_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.update_transfer_amount(
  p_transfer_id, p_new_amount, p_new_exchange_rate, p_amendment_note
) $$;

-- ─── permissions: public API available only to signed-in clients ───
DO $$
DECLARE
  fn text;
  names text[] := ARRAY[
    'create_client(text,text,text,text,text)',
    'deposit_client(uuid,double precision,text,text)',
    'debit_client(uuid,double precision,text,text)',
    'set_exchange_rate(text,text,double precision)',
    'adjust_balance(uuid,uuid,double precision,text,text,text,text,text,text)',
    'import_bank_transactions(uuid,uuid,jsonb)',
    'create_purchase(uuid,text,double precision,text,jsonb,text,text,text)',
    'update_purchase(uuid,double precision,jsonb,text,text)',
    'delete_purchase(uuid,text)',
    'create_transfer(uuid,uuid,uuid,text,text,double precision,text,double precision,text,double precision,text,text,text,text,text,text,text,text,text,text,text)',
    'confirm_transfer(uuid,text)',
    'reject_transfer(uuid,text)',
    'issue_transfer(uuid)',
    'cancel_transfer(uuid,text)',
    'update_transfer_amount(uuid,double precision,double precision,text)'
  ];
BEGIN
  FOREACH fn IN ARRAY names LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', fn);
  END LOOP;
END
$$;
