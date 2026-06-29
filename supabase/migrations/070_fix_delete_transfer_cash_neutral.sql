-- ═══════════════════════════════════════════════════════════════════════════
-- 070  delete_transfer → cash-neutral (net-0) refund
-- ═══════════════════════════════════════════════════════════════════════════
--
-- БАГ (CRITICAL #1 + #2, forensic-audit 06.2026):
--   private.delete_transfer (миграция 039, строки 233-244) при удалении
--   БЕЗУСЛОВНО возвращал на счёт-источник v_total_debit
--     = amount [+ commission, если commission_mode='fromSender'].
--   Это печатает деньги в двух сценариях:
--
--   (a) Партнёрский перевод, созданный через create_partner_transfer (056):
--       тело перевода со счёта НИКОГДА не списывалось («платит партнёр»),
--       поэтому возврат v_total_debit — это чистая эмиссия на счёт.
--
--   (b) Обычный перевод, ПРИВЯЗАННЫЙ к партнёру через
--       attach_transfer_to_partner (056, строки 300-327): привязка уже
--       откатила исходный дебет, запостив CREDIT 'partner_offset' на тот же
--       from_account_id. Возврат v_total_debit поверх этого — двойной кредит.
--       Вдобавок DELETE ledger_entries в 039 (строки 281-283) удалял только
--       reference_type IN ('transfer','commission','transfer_issuance') —
--       строка 'partner_offset' оставалась сиротой в журнале.
--
-- ИСПРАВЛЕНИЕ (выбранная бизнес-модель — net-0, согласованная с миграцией 069):
--   1. Возврат на счёт-источник теперь ВЫВОДИТСЯ ИЗ ЖУРНАЛА — это чистый
--      нетто-дебет именно этого счёта по этому переводу:
--        v_source_net_debit
--          = Σ(debit) − Σ(credit) по ledger_entries
--              WHERE reference_id = p_transfer_id AND account_id = from_account_id
--      Тогда возврат «зеркалит» ровно то, что счёт реально потерял.
--   2. В DELETE ledger_entries добавлен reference_type 'partner_offset',
--      чтобы offset-строки уходили вместе с переводом (не сиротели).
--
--   Реверс комиссии fromAccount (commission_account_id — ДРУГОЙ счёт) и
--   реверс партнёрского saldo НЕ ТРОГАЕМ — иначе двойной учёт.
--
-- ПРОВЕРКА АРИФМЕТИКИ (три сценария):
--
--   Сценарий 1 — обычный перевод, amount=100, commission=10 (fromSender):
--     При оформлении: debit 110 на from_account (reference_type='transfer'/
--     'commission', reference_id=transfer_id).
--     v_source_net_debit = Σdebit(110) − Σcredit(0) = 110.
--     Возврат = 110. Совпадает со старым v_total_debit. ✔ Корректно.
--
--   Сценарий 2 — партнёрский перевод (create_partner_transfer, 056):
--     При оформлении тело НЕ списывалось → на from_account нет debit-строк.
--     v_source_net_debit = 0 − 0 = 0.
--     Возврат = 0. Денег не печатаем. ✔ Исправлено (раньше печатали v_total_debit).
--
--   Сценарий 3 — обычный перевод, ПРИВЯЗАННЫЙ к партнёру (attach_…, 056):
--     debit 110 при оформлении + credit 110 'partner_offset' при привязке.
--     v_source_net_debit = Σdebit(110) − Σcredit(110) = 0.
--     Возврат = 0. Счёт уже получил свои деньги при привязке. ✔ Исправлено
--     (раньше: +110 поверх уже возвращённых 110 = двойной кредит).
--     partner_offset-строка теперь тоже удаляется. ✔
--
-- Сигнатура не меняется → CREATE OR REPLACE. GRANT EXECUTE сохранён.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION private.delete_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_source_net_debit double precision;
  v_op_amount double precision;
  v_op_currency text;
  v_curr_saldo double precision;
  v_snapshot jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  -- ── Проверка прав ────────────────────────────────────────
  IF v_role = 'accountant' THEN
    IF v_t.status <> 'created' OR v_t.via_counterparty_id IS NOT NULL THEN
      RAISE EXCEPTION 'Бухгалтер может удалить только свой созданный (pending) перевод. '
                  'Партнёрские и confirmed-переводы — только Director/Creator.';
    END IF;
    -- Свой филиал.
    IF v_assigned IS NULL
       OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно удалить только переводы из своего филиала';
    END IF;
  END IF;

  -- ── Какие статусы разрешены ─────────────────────────────
  -- created                       — обычный pending, всегда можно
  -- delivered + via_counterparty  — партнёрский (только director/creator)
  IF NOT (
       v_t.status = 'created'
       OR (v_t.status = 'delivered' AND v_t.via_counterparty_id IS NOT NULL)
     ) THEN
    RAISE EXCEPTION 'Удаление возможно для статуса «created» или для партнёрских «delivered». '
                'Текущий: %. '
                'Confirmed/withCourier/delivered (обычные) уже задели счёт получателя, '
                'отмена требует ручного rollback директором.', v_t.status;
  END IF;

  -- Snapshot для аудита.
  v_snapshot := to_jsonb(v_t);

  -- ── REFUND: основной счёт-источник (net-0, выведено из журнала) ──────────
  -- ВНИМАНИЕ (070): раньше тут безусловно возвращался v_total_debit, что
  -- печатало деньги для партнёрских/привязанных переводов (см. шапку файла).
  -- Теперь возвращаем РОВНО чистый нетто-дебет этого счёта по переводу:
  --   обычный    →  amount(+commission) − 0           = полный дебет;
  --   партнёрский→  0 − 0                              = 0 (тело не списывали);
  --   привязанный→  amount(+commission) − offset_credit = 0.
  -- ВНИМАНИЕ (070-fix): фильтруем по reference_type тела/привязки. Иначе в
  -- режиме fromAccount, когда комиссия списана с ТОГО ЖЕ счёта-источника,
  -- её 'credit'-строка попала бы в нетто, а блок реверса комиссии ниже вычел
  -- бы её повторно — счёт потерял бы ровно commission. Комиссию обрабатывает
  -- ТОЛЬКО отдельный блок ниже; transfer_issuance — это debit на счёте выдачи
  -- (получателя), на from_account его нет, исключение безопасно.
  v_source_net_debit := COALESCE((
    SELECT SUM(CASE WHEN type = 'debit' THEN amount ELSE -amount END)
      FROM ledger_entries
     WHERE reference_id   = p_transfer_id::text
       AND account_id     = v_t.from_account_id
       AND reference_type IN ('transfer', 'partner_offset')
  ), 0);

  IF v_t.from_account_id IS NOT NULL THEN
    UPDATE account_balances
       SET balance    = balance + v_source_net_debit,
           updated_at = now()
     WHERE account_id = v_t.from_account_id;
  END IF;

  -- ── REVERSE: commission credit (если fromAccount) ───────
  -- ДРУГОЙ счёт (commission_account_id) — учитывается отдельно, не входит в
  -- v_source_net_debit выше, поэтому двойного учёта нет.
  IF v_t.commission_mode = 'fromAccount'
     AND v_t.commission_account_id IS NOT NULL
     AND COALESCE(v_t.commission, 0) > 0 THEN
    UPDATE account_balances
       SET balance    = balance - v_t.commission,
           updated_at = now()
     WHERE account_id = v_t.commission_account_id;
  END IF;

  -- ── REVERSE: partner saldo (если via_counterparty_id) ───
  IF v_t.via_counterparty_id IS NOT NULL THEN
    -- Находим paid_for_us op, чтобы знать ровно ту валюту/сумму
    -- которой мы двигали saldo. Их может быть несколько (теоретически),
    -- — берём все и откатываем.
    FOR v_op_amount, v_op_currency IN
      SELECT amount, currency FROM counterparty_transactions
       WHERE transfer_id = p_transfer_id
         AND kind = 'paid_for_us'
    LOOP
      v_curr_saldo := COALESCE(
        ((SELECT saldo_by_currency->>v_op_currency
            FROM counterparties WHERE id = v_t.via_counterparty_id)::double precision),
        0);
      -- paid_for_us изначально делал saldo -= amount → откатываем += amount.
      UPDATE counterparties
         SET saldo_by_currency = saldo_by_currency
             || jsonb_build_object(v_op_currency, v_curr_saldo + v_op_amount)
       WHERE id = v_t.via_counterparty_id;
    END LOOP;

    DELETE FROM counterparty_transactions WHERE transfer_id = p_transfer_id;
  END IF;

  -- ── DELETE: ledger entries + commissions + approvals ────
  -- (070): добавлен 'partner_offset', иначе offset-кредит привязки оставался
  -- сиротой в журнале после удаления перевода.
  DELETE FROM ledger_entries
   WHERE reference_id = p_transfer_id::text
     AND reference_type IN ('transfer', 'commission', 'transfer_issuance', 'partner_offset');
  DELETE FROM commissions WHERE transfer_id = p_transfer_id;
  DELETE FROM transfer_issuances WHERE transfer_id = p_transfer_id;
  DELETE FROM pending_approvals WHERE target_id = p_transfer_id;

  -- ── Аудит ────────────────────────────────────────────────
  INSERT INTO deleted_transfers (
    original_id, transaction_code,
    from_branch_id, to_branch_id, from_account_id,
    amount, currency, to_currency,
    status_at_delete, via_counterparty_id,
    deleted_by, reason, original_data
  ) VALUES (
    v_t.id, v_t.transaction_code,
    v_t.from_branch_id, v_t.to_branch_id, v_t.from_account_id,
    v_t.amount, v_t.currency, v_t.to_currency,
    v_t.status, v_t.via_counterparty_id,
    v_uid, NULLIF(trim(coalesce(p_reason,'')), ''), v_snapshot
  );

  -- ── Hard delete ──────────────────────────────────────────
  DELETE FROM transfers WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'refundedAmount', v_source_net_debit,
    'refundedCurrency', v_t.currency
  );
END;
$$;

-- Публичная обёртка не меняется (сигнатура та же), но GRANT повторяем
-- на случай чистого наката этой миграции отдельно.
GRANT EXECUTE ON FUNCTION public.delete_transfer(uuid, text) TO authenticated;

COMMIT;
