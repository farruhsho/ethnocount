-- ============================================================
-- 091: Гварды на деньги при архиве/смене валюты счёта (F4a + F5)
-- ============================================================
-- F5 (currency swap): admin_update_branch_account (048) позволяет сменить
-- валюту счёта с НЕНУЛЕВЫМ балансом — account_balances.currency
-- перезаписывается, число остаётся (5000 USD → «5000 EUR»), ledger в старой
-- валюте. Денежное искажение.
-- F4a (archive with money): admin_archive_branch (011) и
-- admin_archive_branch_account (048) НЕ проверяют баланс/in-flight (в отличие
-- от admin_archive_client 021, где zero-balance check). Архивный счёт с
-- деньгами исчезает из всех вью (branch_remote_ds фильтрует is_active=true).
--
-- РЕШЕНИЕ: перед сменой валюты / архивом требовать нулевой баланс
-- (порог abs > 0.005, как в admin_archive_client 021:274). Источник истины —
-- account_balances.balance. Разархивация (p_archive=false) не гейтится.
-- Тела воспроизводят 011/048 1:1; добавлены только guard-блоки. Идемпотентно.
--
-- ⚠️ F4b (видимость+восстановление архивных из UI) — отдельная фича
-- (branch_remote_ds includeInactive), НЕ входит в эту миграцию: сейчас
-- restore-UI мёртв. Данная миграция закрывает money-safety (не даёт
-- «спрятать» деньги архивом); показ архива — следующим шагом.
-- ============================================================

BEGIN;

-- ── F5: admin_update_branch_account + currency-lock ──────────
CREATE OR REPLACE FUNCTION private.admin_update_branch_account(
  p_account_id uuid,
  p_name text DEFAULT NULL,
  p_type text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_card_number text DEFAULT NULL,
  p_clear_card_number boolean DEFAULT false,
  p_cardholder_name text DEFAULT NULL,
  p_bank_name text DEFAULT NULL,
  p_expiry_month smallint DEFAULT NULL,
  p_expiry_year smallint DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_acc public.branch_accounts%ROWTYPE;
  v_bal double precision;
BEGIN
  SELECT * INTO v_acc FROM public.branch_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

  IF NOT private.user_can_manage_branch_account(v_acc.branch_id) THEN
    RAISE EXCEPTION 'Нет прав на изменение счетов в этом филиале';
  END IF;

  IF p_type IS NOT NULL AND p_type NOT IN ('cash','card','reserve','transit') THEN
    RAISE EXCEPTION 'Неверный тип счёта: %', p_type;
  END IF;

  -- ── 091 (F5): нельзя менять валюту счёта с ненулевым балансом ──
  IF p_currency IS NOT NULL AND p_currency <> v_acc.currency THEN
    SELECT balance INTO v_bal FROM public.account_balances
      WHERE account_id = p_account_id FOR UPDATE;
    IF abs(COALESCE(v_bal, 0)) > 0.005 THEN
      RAISE EXCEPTION 'Нельзя менять валюту счёта с ненулевым балансом (%). Сначала обнулите/выведите остаток или проведите конвертацию.', v_bal;
    END IF;
  END IF;

  UPDATE public.branch_accounts SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    type = COALESCE(p_type, type),
    currency = COALESCE(p_currency, currency),
    card_number = CASE
                    WHEN p_clear_card_number THEN NULL
                    WHEN p_card_number IS NOT NULL THEN NULLIF(trim(p_card_number), '')
                    ELSE card_number
                  END,
    cardholder_name = CASE WHEN p_cardholder_name IS NULL THEN cardholder_name ELSE NULLIF(trim(p_cardholder_name), '') END,
    bank_name = CASE WHEN p_bank_name IS NULL THEN bank_name ELSE NULLIF(trim(p_bank_name), '') END,
    expiry_month = COALESCE(p_expiry_month, expiry_month),
    expiry_year = COALESCE(p_expiry_year, expiry_year),
    notes = CASE WHEN p_notes IS NULL THEN notes ELSE NULLIF(trim(p_notes), '') END,
    sort_order = COALESCE(p_sort_order, sort_order)
  WHERE id = p_account_id;

  IF p_currency IS NOT NULL AND p_currency <> v_acc.currency THEN
    UPDATE public.account_balances SET currency = p_currency, updated_at = now()
    WHERE account_id = p_account_id;
  END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('account.updated', 'branch_account', p_account_id::text, v_uid,
          jsonb_build_object('cardNumberChanged',
            (p_clear_card_number OR (p_card_number IS NOT NULL AND NULLIF(trim(p_card_number), '') IS DISTINCT FROM v_acc.card_number))));

  RETURN jsonb_build_object('success', true);
END
$$;

-- ── F4a: admin_archive_branch_account + zero-balance guard ────
CREATE OR REPLACE FUNCTION private.admin_archive_branch_account(
  p_account_id uuid,
  p_archive boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_branch_id uuid;
  v_bal double precision;
BEGIN
  SELECT branch_id INTO v_branch_id FROM public.branch_accounts WHERE id = p_account_id;
  IF v_branch_id IS NULL THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

  IF NOT private.user_can_manage_branch_account(v_branch_id) THEN
    RAISE EXCEPTION 'Нет прав на архивирование счетов в этом филиале';
  END IF;

  -- ── 091 (F4a): нельзя архивировать счёт с ненулевым балансом ──
  -- FOR UPDATE — как admin_archive_client в 079 (#23): сериализуем против
  -- параллельного депозита/перевода (те берут FOR UPDATE на account_balances),
  -- иначе TOCTOU: проверка нуля → конкурентный кредит → архив с деньгами.
  IF p_archive THEN
    SELECT balance INTO v_bal FROM public.account_balances WHERE account_id = p_account_id FOR UPDATE;
    IF abs(COALESCE(v_bal, 0)) > 0.005 THEN
      RAISE EXCEPTION 'Нельзя архивировать счёт с ненулевым балансом (%). Сначала обнулите/выведите остаток.', v_bal;
    END IF;
  END IF;

  UPDATE public.branch_accounts SET
    is_active = NOT p_archive,
    archived_at = CASE WHEN p_archive THEN now() ELSE NULL END
  WHERE id = p_account_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_archive THEN 'account.archived' ELSE 'account.unarchived' END,
          'branch_account', p_account_id::text, v_uid, '{}'::jsonb);

  RETURN jsonb_build_object('success', true);
END
$$;

-- ── F4a: admin_archive_branch + zero-balance/in-flight guard ──
CREATE OR REPLACE FUNCTION private.admin_archive_branch(
  p_branch_id uuid,
  p_archive boolean,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может архивировать филиалы'; END IF;

  -- ── 091 (F4a): нельзя архивировать филиал с деньгами / in-flight ──
  IF p_archive THEN
    IF EXISTS (
      SELECT 1 FROM public.account_balances ab
      JOIN public.branch_accounts ba ON ba.id = ab.account_id
      WHERE ba.branch_id = p_branch_id AND abs(ab.balance) > 0.005
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать филиал с ненулевыми счетами. Сначала обнулите/выведите остатки.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.transfers
      WHERE (from_branch_id = p_branch_id OR to_branch_id = p_branch_id)
        AND status IN ('created','toDelivery','withCourier')
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать филиал с незавершёнными переводами.';
    END IF;
  END IF;

  UPDATE public.branches SET
    is_active = NOT p_archive,
    archived_at = CASE WHEN p_archive THEN now() ELSE NULL END
  WHERE id = p_branch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Филиал не найден'; END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_archive THEN 'branch.archived' ELSE 'branch.unarchived' END,
          'branch', p_branch_id::text, v_uid,
          jsonb_build_object('reason', p_reason));

  RETURN jsonb_build_object('success', true);
END
$$;

COMMIT;
