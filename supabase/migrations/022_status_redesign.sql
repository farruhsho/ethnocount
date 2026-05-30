-- ============================================================
-- 022: Transfer status redesign
-- ============================================================
-- Меняем lifecycle переводов:
--   pending     → created
--   confirmed   → toDelivery
--   issued      → delivered
--   (новый)     → withCourier  (между toDelivery и delivered)
--   rejected    → УДАЛЕНО (вместе со связанными ledger/issuance строками)
--   cancelled   → УДАЛЕНО      (то же)
--
-- ⚠️ Принципиально важно: ВСЯ существующая бухгалтерская логика
-- (ledger, балансы, commissions, notifications) сохраняется. Меняются
-- только имена статусов в проверках и UPDATE.
--
-- Также:
--   * добавляет колонки courier_name, courier_phone, dispatched_by, dispatched_at
--   * удаляет колонки rejected_by, rejection_reason, rejected_at,
--                     cancelled_by, cancellation_reason, cancelled_at
--   * заменяет CHECK-constraint
--   * новый RPC dispatch_transfer_to_courier (toDelivery → withCourier)
--   * перезаписывает confirm_transfer (created → toDelivery, с балансом)
--   * перезаписывает issue_transfer / issue_transfer_partial
--     (теперь допускают `withCourier` и `toDelivery` как стартовый статус)
--   * удаляет старые RPC reject_transfer / cancel_transfer (public+private)
--
-- ⚠️ ВНИМАНИЕ: миграция уничтожает rejected/cancelled переводы и их
-- ledger-записи. Идемпотентна на повторных запусках.
-- ============================================================

BEGIN;

-- ─── 1. Удаляем rejected/cancelled данные ───
-- ledger_entries.reference_id хранится как text → нужен явный каст id::text.

DELETE FROM public.ledger_entries
 WHERE reference_type = 'transfer'
   AND reference_id IN (
     SELECT id::text FROM public.transfers
      WHERE status IN ('rejected', 'cancelled')
   );

DELETE FROM public.transfer_issuances
 WHERE transfer_id IN (
   SELECT id FROM public.transfers WHERE status IN ('rejected', 'cancelled')
 );

DELETE FROM public.pending_approvals
 WHERE target_id IN (
   SELECT id FROM public.transfers WHERE status IN ('rejected', 'cancelled')
 );

DELETE FROM public.transfers WHERE status IN ('rejected', 'cancelled');

-- ─── 2. Снимаем CHECK перед переименованием значений ───
ALTER TABLE public.transfers
  DROP CONSTRAINT IF EXISTS transfers_status_check;

-- ─── 3. Переименование статусов ───
UPDATE public.transfers SET status = 'created'    WHERE status = 'pending';
UPDATE public.transfers SET status = 'toDelivery' WHERE status = 'confirmed';
UPDATE public.transfers SET status = 'delivered'  WHERE status = 'issued';

-- ─── 4. Новый CHECK ───
ALTER TABLE public.transfers
  ADD CONSTRAINT transfers_status_check
  CHECK (status IN ('created', 'toDelivery', 'withCourier', 'delivered'));

ALTER TABLE public.transfers
  ALTER COLUMN status SET DEFAULT 'created';

-- ─── 5. Колонки курьера ───
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS dispatched_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS dispatched_at timestamptz,
  ADD COLUMN IF NOT EXISTS courier_name  text,
  ADD COLUMN IF NOT EXISTS courier_phone text;

-- ─── 6. Удаляем колонки rejection / cancellation ───
ALTER TABLE public.transfers
  DROP COLUMN IF EXISTS rejected_by,
  DROP COLUMN IF EXISTS rejection_reason,
  DROP COLUMN IF EXISTS rejected_at,
  DROP COLUMN IF EXISTS cancelled_by,
  DROP COLUMN IF EXISTS cancellation_reason,
  DROP COLUMN IF EXISTS cancelled_at;

-- ─── 7. Удаляем старые RPC reject/cancel ───
DROP FUNCTION IF EXISTS public.reject_transfer(uuid, text);
DROP FUNCTION IF EXISTS public.cancel_transfer(uuid, text);
DROP FUNCTION IF EXISTS private.reject_transfer(uuid, text);
DROP FUNCTION IF EXISTS private.cancel_transfer(uuid, text);

-- ─── 8. Чистим pending_approvals: action='transfer_reject' больше не валиден ───
DELETE FROM public.pending_approvals
 WHERE action = 'transfer_reject'::public.approval_action_t;

-- ─── 9. Перезаписываем confirm_transfer ───
-- Сохраняем ВСЮ исходную логику (ledger, балансы, commission,
-- notifications), меняем только имена статусов: pending→created,
-- confirmed→toDelivery. Возвращаем {'success': true} как и раньше,
-- чтобы Dart-репозиторий продолжал корректно парсить ответ.
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
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'created' THEN
    RAISE EXCEPTION 'Transfer not in created state (current: %)', v_transfer.status;
  END IF;

  v_effective_to := CASE
    WHEN v_transfer.to_account_id IS NOT NULL AND v_transfer.to_account_id <> ''
      THEN v_transfer.to_account_id
    ELSE COALESCE(p_to_account_id, '')
  END;
  IF v_effective_to = '' THEN
    RAISE EXCEPTION 'Счёт получателя не указан';
  END IF;

  v_to_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);

  SELECT currency INTO v_acc_currency
    FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_transfer.to_currency IS NOT NULL
     AND v_transfer.to_currency <> ''
     AND v_acc_currency <> v_transfer.to_currency THEN
    RAISE EXCEPTION 'Счёт получателя в валюте %, перевод оформлен в %',
      v_acc_currency, v_transfer.to_currency;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

  UPDATE transfers SET
    status        = 'toDelivery',
    confirmed_by  = v_user_id,
    confirmed_at  = now(),
    to_account_id = CASE
      WHEN to_account_id IS NULL OR to_account_id = '' THEN v_effective_to
      ELSE to_account_id
    END,
    to_currency   = COALESCE(v_to_currency, to_currency)
  WHERE id = p_transfer_id;

  -- Credit receiver
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_effective_to::uuid, v_transfer.to_branch_id,
          v_transfer.converted_amount,
          COALESCE(v_acc_currency, v_to_currency), now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance + v_transfer.converted_amount,
        updated_at = now();

  -- Ledger credit
  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency, reference_type,
     reference_id, transaction_code, description, created_by)
  VALUES (v_transfer.to_branch_id, v_effective_to::uuid, 'credit',
          v_transfer.converted_amount,
          COALESCE(v_acc_currency, v_to_currency),
          'transfer', p_transfer_id::text, v_code,
          'Перевод ' || v_code || ' принят (к выдаче)', v_user_id);

  -- Sync pending sender ledger descriptions
  UPDATE ledger_entries
     SET description = 'Перевод ' || v_code || ' принят (к выдаче)'
   WHERE reference_type = 'transfer'
     AND reference_id = p_transfer_id::text
     AND branch_id = v_transfer.from_branch_id
     AND type = 'debit';

  -- Commission
  IF v_transfer.commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (p_transfer_id, v_transfer.from_branch_id, v_transfer.commission,
            COALESCE(NULLIF(v_transfer.commission_currency, ''), v_transfer.currency),
            COALESCE(v_transfer.commission_type, 'fixed'), now());
  END IF;

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_transfer.from_branch_id::text,
      'transfer_confirmed',
      'Перевод ' || v_code || ' к выдаче',
      'Ваш перевод '
        || to_char(v_transfer.amount::numeric, 'FM999G999G990D00') || ' ' || v_transfer.currency
        || ' → ' || COALESCE((SELECT name FROM branches WHERE id = v_transfer.to_branch_id), '—')
        || ' принят получателем и переведён в статус «к выдаче».',
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'amount', v_transfer.amount,
        'currency', v_transfer.currency
      )
    ),
    (
      v_transfer.to_branch_id::text,
      'transfer_confirmed',
      'Перевод ' || v_code || ' к выдаче',
      'Зачислено '
        || to_char(v_transfer.converted_amount::numeric, 'FM999G999G990D00')
        || ' ' || COALESCE(v_transfer.to_currency, v_transfer.currency)
        || ' от ' || COALESCE((SELECT name FROM branches WHERE id = v_transfer.from_branch_id), '—'),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'amount', v_transfer.converted_amount,
        'currency', COALESCE(v_transfer.to_currency, v_transfer.currency)
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.confirm_transfer(uuid, text) TO authenticated;

-- ─── 10. dispatch_transfer_to_courier (toDelivery → withCourier) ───
CREATE OR REPLACE FUNCTION private.dispatch_transfer_to_courier(
  p_transfer_id  uuid,
  p_courier_name text DEFAULT NULL,
  p_courier_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_member  uuid;
  v_code    text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'toDelivery' THEN
    RAISE EXCEPTION 'Курьеру можно отдать только перевод «к выдаче» (текущий: %)', v_transfer.status;
  END IF;

  -- Только бухгалтер отправляющего филиала (creator/director всегда могут).
  SELECT user_id INTO v_member
    FROM public.users
   WHERE user_id = v_user_id
     AND (branch_id = v_transfer.from_branch_id
          OR system_role IN ('creator', 'director'));
  IF v_member IS NULL THEN
    RAISE EXCEPTION 'Только бухгалтер отправляющего филиала может отдать перевод курьеру';
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET
    status        = 'withCourier',
    dispatched_by = v_user_id,
    dispatched_at = now(),
    courier_name  = NULLIF(trim(coalesce(p_courier_name,'')), ''),
    courier_phone = NULLIF(trim(coalesce(p_courier_phone,'')), '')
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_transfer.to_branch_id::text,
      'transfer_dispatched',
      'Перевод ' || v_code || ' у курьера',
      'Деньги переданы курьеру'
        || COALESCE(' (' || NULLIF(trim(p_courier_name),'') || ')', ''),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'courierName', NULLIF(trim(coalesce(p_courier_name,'')), ''),
        'courierPhone', NULLIF(trim(coalesce(p_courier_phone,'')), '')
      )
    ),
    (
      v_transfer.from_branch_id::text,
      'transfer_dispatched',
      'Перевод ' || v_code || ' отправлен курьером',
      'Вы передали наличные курьеру для доставки в '
        || COALESCE((SELECT name FROM branches WHERE id = v_transfer.to_branch_id), '—'),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.dispatch_transfer_to_courier(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.dispatch_transfer_to_courier(
  p_transfer_id   uuid,
  p_courier_name  text DEFAULT NULL,
  p_courier_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT private.dispatch_transfer_to_courier(p_transfer_id, p_courier_name, p_courier_phone);
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_transfer_to_courier(uuid, text, text) TO authenticated;

-- ─── 11. issue_transfer — теперь разрешает withCourier (и toDelivery как fast-path) ───
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
  IF v_transfer.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_transfer.status;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET
    status    = 'delivered',
    issued_by = v_user_id,
    issued_at = now()
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_transfer.from_branch_id::text,
      'transfer_issued',
      'Перевод ' || v_code || ' выдан',
      'Перевод '
        || to_char(v_transfer.amount::numeric, 'FM999G999G990D00') || ' ' || v_transfer.currency
        || ' выдан получателю в ' || COALESCE((SELECT name FROM branches WHERE id = v_transfer.to_branch_id), '—'),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'amount', v_transfer.amount,
        'currency', v_transfer.currency
      )
    ),
    (
      v_transfer.to_branch_id::text,
      'transfer_issued',
      'Перевод ' || v_code || ' выдан',
      'Деньги по переводу '
        || to_char(v_transfer.amount::numeric, 'FM999G999G990D00') || ' ' || v_transfer.currency
        || ' переданы получателю.',
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'amount', v_transfer.amount,
        'currency', v_transfer.currency
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.issue_transfer(uuid) TO authenticated;

-- ─── 12. issue_transfer_partial — обновляем status-check и финальный set ───
-- Полностью повторяем тело из 020_issue_transfer_debits_payout_account.sql,
-- меняем только два места:
--   IN ('confirmed') → IN ('toDelivery', 'withCourier')
--   status = 'issued' → status = 'delivered'
CREATE OR REPLACE FUNCTION private.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL,
  p_from_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_remaining double precision;
  v_new_total double precision;
  v_code text;
  v_currency text;
  v_branch_name text;
  v_account_name text;
  v_acc_branch uuid;
  v_payout_account uuid;
  v_payout_currency text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_transfer.status;
  END IF;

  v_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);
  v_remaining := v_transfer.converted_amount - COALESCE(v_transfer.issued_amount, 0);

  IF p_amount > v_remaining + 1e-6 THEN
    RAISE EXCEPTION 'Сумма выдачи (%) превышает остаток к выдаче (%)',
      round(p_amount::numeric, 2), round(v_remaining::numeric, 2);
  END IF;
  IF abs(p_amount - v_remaining) < 1e-6 THEN
    p_amount := v_remaining;
  END IF;

  IF p_from_account_id IS NOT NULL THEN
    v_payout_account := p_from_account_id;
  ELSIF v_transfer.to_account_id IS NOT NULL AND v_transfer.to_account_id <> '' THEN
    v_payout_account := v_transfer.to_account_id::uuid;
  ELSE
    RAISE EXCEPTION 'Не указан счёт выдачи и у перевода нет to_account_id';
  END IF;

  SELECT branch_id, name, currency
    INTO v_acc_branch, v_account_name, v_payout_currency
    FROM branch_accounts WHERE id = v_payout_account;
  IF v_acc_branch IS NULL THEN
    RAISE EXCEPTION 'Счёт выдачи не найден';
  END IF;
  IF v_acc_branch <> v_transfer.to_branch_id THEN
    RAISE EXCEPTION 'Счёт выдачи должен принадлежать филиалу получателя';
  END IF;
  IF v_payout_currency <> v_currency THEN
    RAISE EXCEPTION 'Валюта счёта выдачи (%) не совпадает с валютой перевода (%)',
      v_payout_currency, v_currency;
  END IF;

  v_new_total := COALESCE(v_transfer.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), v_payout_account);

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_payout_account, v_acc_branch, -p_amount, v_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - p_amount,
        updated_at = now();

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES
    (v_acc_branch, v_payout_account, 'debit', p_amount, v_currency,
     'transfer_issuance', p_transfer_id::text, v_code,
     'Выдача по переводу ' || v_code
       || COALESCE(' (' || v_account_name || ')', ''),
     v_user_id);

  IF v_new_total >= v_transfer.converted_amount - 1e-6 THEN
    UPDATE transfers SET
      status        = 'delivered',
      issued_amount = v_transfer.converted_amount,
      issued_by     = v_user_id,
      issued_at     = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_transfer.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' выдан',
        'Перевод выдан полностью в ' || COALESCE(v_branch_name, '—'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code
        )
      );

    RETURN jsonb_build_object('success', true, 'fullyIssued', true);
  ELSE
    UPDATE transfers SET issued_amount = v_new_total WHERE id = p_transfer_id;
    RETURN jsonb_build_object('success', true, 'fullyIssued', false);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.issue_transfer_partial(uuid, double precision, text, uuid) TO authenticated;

-- ─── 13. Триггер-страж переходов статусов ───
-- Защита от случайных «скачков» через прямой UPDATE (минуя RPC).
CREATE OR REPLACE FUNCTION private.tg_transfers_status_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF (OLD.status = 'created'     AND NEW.status = 'toDelivery')  OR
     (OLD.status = 'toDelivery'  AND NEW.status = 'withCourier') OR
     (OLD.status = 'withCourier' AND NEW.status = 'delivered')   OR
     (OLD.status = 'toDelivery'  AND NEW.status = 'delivered')
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Запрещённый переход статуса перевода: % → %', OLD.status, NEW.status;
END;
$$;

DROP TRIGGER IF EXISTS transfers_status_guard ON public.transfers;
CREATE TRIGGER transfers_status_guard
  BEFORE UPDATE OF status ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION private.tg_transfers_status_guard();

COMMIT;
