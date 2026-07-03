-- ============================================================
-- 089: update_transfer_amount — серверный branch-guard (F1)
-- ============================================================
-- ПРОБЛЕМА (F1, ре-аудит 07.2026): private.update_transfer_amount (082)
-- проверяет только auth.uid() IS NULL, без role/branch/ownership. Функция
-- SECURITY DEFINER (обходит RLS transfers), public-обёртка грантована
-- authenticated → бухгалтер филиала A прямым REST-вызовом переписывает
-- сумму/курс/converted_amount перевода филиала B, минуя approve-workflow и
-- границу assignedBranchIds. (Переписать можно только недоставленный
-- перевод без выдач — деньги ещё не покинули кассу, поэтому это нарушение
-- изоляции филиалов + обход аудита, а не прямая кража; HIGH.)
--
-- РЕШЕНИЕ: добавить branch-guard сразу после чтения перевода (когда известны
-- from_branch_id/to_branch_id) и ДО любых мутаций. creator/director — всегда;
-- accountant — только если перевод его филиала (from или to). Диспатч из
-- private.approve_request (вызывается апрувером-директором, auth.uid()=director)
-- проходит guard через is_creator_or_director(). Приватный 3-арг шим (082)
-- не трогаем — он делегирует в эту защищённую каноничную функцию.
--
-- Тело воспроизводит 082 1:1; добавлен ТОЛЬКО guard-блок (после NOT FOUND).
-- Идемпотентно: CREATE OR REPLACE той же сигнатуры. Re-GRANT.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.update_transfer_amount(
  p_transfer_id uuid,
  p_new_amount double precision,
  p_new_exchange_rate double precision DEFAULT NULL,
  p_amendment_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_t transfers%ROWTYPE;
  v_old_total double precision;
  v_new_commission double precision;
  v_new_total double precision;
  v_eff_rate double precision;
  v_receiver double precision;
  v_balance double precision;
  v_delta double precision;
  v_code text;
  v_actor_name text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_new_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;

  -- ── 089: branch-guard (изоляция филиалов + обход approve-workflow) ──
  -- creator/director — всегда; accountant — только свой филиал (from/to).
  -- branch_allowed() покрывает только creator+branch, поэтому director
  -- добавлен явно через is_creator_or_director().
  IF NOT (private.is_creator_or_director()
          OR private.branch_allowed(v_t.from_branch_id)
          OR private.branch_allowed(v_t.to_branch_id)) THEN
    RAISE EXCEPTION 'Недостаточно прав: перевод относится к другому филиалу';
  END IF;

  IF v_t.status = 'delivered' THEN
    RAISE EXCEPTION 'Изменять сумму выданного перевода нельзя';
  END IF;
  IF v_t.status NOT IN ('created', 'toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Изменение суммы недоступно для статуса %', v_t.status;
  END IF;
  IF COALESCE(v_t.issued_amount, 0) > 0 THEN
    RAISE EXCEPTION 'По переводу уже есть выдачи — изменение суммы недоступно';
  END IF;
  IF v_t.via_counterparty_id IS NOT NULL THEN
    RAISE EXCEPTION 'Перевод привязан к партнёру — сумму меняйте через отвязку (detach), правку и повторную привязку';
  END IF;

  v_old_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN v_t.amount + v_t.commission
                      ELSE v_t.amount END;

  v_new_commission := private.normalize_commission(
    v_t.commission_type, v_t.commission_value, v_t.commission_currency, p_new_amount, v_t.currency
  );

  v_new_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN p_new_amount + v_new_commission
                      ELSE p_new_amount END;

  v_eff_rate := COALESCE(p_new_exchange_rate, v_t.exchange_rate);
  v_receiver := CASE v_t.commission_mode
    WHEN 'fromTransfer' THEN p_new_amount - v_new_commission
    WHEN 'toReceiver'   THEN p_new_amount + v_new_commission
    ELSE p_new_amount
  END;

  v_delta := v_old_total - v_new_total;
  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  SELECT balance INTO v_balance FROM account_balances WHERE account_id = v_t.from_account_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_t.from_account_id, v_t.from_branch_id, v_delta, v_t.currency, now());
  ELSE
    IF v_balance + v_delta < 0 THEN
      RAISE EXCEPTION 'Недостаточно средств на счёте отправителя';
    END IF;
    UPDATE account_balances
      SET balance = balance + v_delta, updated_at = now()
      WHERE account_id = v_t.from_account_id;
  END IF;

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'credit', v_old_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code, 'Сторно (изменён): ' || v_code, v_user_id);

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'debit', v_new_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (изменён, ожидает подтверждения)', v_user_id);

  UPDATE transfers SET
    amount = p_new_amount,
    commission = v_new_commission,
    exchange_rate = v_eff_rate,
    converted_amount = v_receiver * v_eff_rate,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object(
        'at', now(),
        'userId', v_user_id::text,
        'note', p_amendment_note,
        'changes', jsonb_build_object(
          'amount', jsonb_build_object('from', v_t.amount, 'to', p_new_amount),
          'commission', jsonb_build_object('from', v_t.commission, 'to', v_new_commission),
          'exchangeRate', jsonb_build_object('from', v_t.exchange_rate, 'to', v_eff_rate)
        )
      )
    )
  WHERE id = p_transfer_id;

  -- ─── Уведомления — второму бухгалтеру (другой филиал) и принимающему. ───
  SELECT display_name INTO v_actor_name FROM users WHERE id = v_user_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_t.to_branch_id::text,
      'transfer_amended',
      'Перевод ' || v_code || ' изменён',
      COALESCE(v_actor_name, 'Бухгалтер')
        || ' изменил сумму перевода: '
        || to_char(v_t.amount::numeric, 'FM999G999G990D00') || ' → '
        || to_char(p_new_amount::numeric, 'FM999G999G990D00') || ' ' || v_t.currency
        || COALESCE('. Заметка: ' || NULLIF(trim(p_amendment_note), ''), ''),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'oldAmount', v_t.amount,
        'newAmount', p_new_amount,
        'currency', v_t.currency,
        'amendedBy', v_user_id::text,
        'note', p_amendment_note
      )
    ),
    (
      v_t.from_branch_id::text,
      'transfer_amended',
      'Перевод ' || v_code || ' изменён',
      'Сумма перевода обновлена: '
        || to_char(v_t.amount::numeric, 'FM999G999G990D00') || ' → '
        || to_char(p_new_amount::numeric, 'FM999G999G990D00') || ' ' || v_t.currency,
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'oldAmount', v_t.amount,
        'newAmount', p_new_amount,
        'currency', v_t.currency,
        'amendedBy', v_user_id::text,
        'note', p_amendment_note
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION
  private.update_transfer_amount(uuid, double precision, double precision, text)
  TO authenticated;

COMMIT;
