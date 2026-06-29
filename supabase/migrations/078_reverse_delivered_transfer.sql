-- ═══════════════════════════════════════════════════════════════════════════
-- 078  reverse_delivered_transfer → атомарный откат ошибочно ВЫДАННОГО
--      обычного (НЕ партнёрского) перевода
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ПРОБЛЕМА:
--   delete_transfer (миграция 070) ОТКАЗЫВАЕТСЯ удалять обычный перевод в
--   статусе delivered:
--     «Confirmed/withCourier/delivered (обычные) уже задели счёт получателя,
--      отмена требует ручного rollback директором».
--   Атомарного пути отката такого перевода НЕТ — директор вынужден руками
--   править балансы и журнал, что чревато ошибками и «печатью» денег.
--
--   Эта миграция добавляет ЕДИНСТВЕННЫЙ безопасный атомарный путь для случая
--   «перевод выдали по ошибке» — ровно для обычного delivered-перевода
--   (via_counterparty_id IS NULL). Партнёрские delivered уже умеет
--   delete_transfer (там откатывается saldo партнёра).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- АРИФМЕТИКА НАЛИЧНЫХ (что именно надо обратить):
--
--   Жизненный цикл обычного перевода (миграции 028 + create_transfer):
--     created    : debit  <amount(+commission)>  на СЧЁТ-ИСТОЧНИК
--                  (reference_type='transfer'/'commission', он же fromSender;
--                   при fromAccount комиссия — на commission_account_id).
--     toDelivery : только статус, БЕЗ денег.
--     withCourier: только статус, БЕЗ денег.
--     delivered  : credit  + debit  <converted_amount>  на СЧЁТ-ПОЛУЧАТЕЛЯ
--                  одной операцией (issue_transfer / issue_transfer_partial):
--                    credit reference_type='transfer'           (поступление),
--                    debit  reference_type='transfer_issuance'  (выдача клиенту).
--                  NET на счёте-получателе = 0 («появились и сразу выданы»).
--
--   Что «потеряли» реальные деньги в системе:
--     • счёт-источник         : нетто-дебет = тело(+комиссия), он отдал деньги;
--     • счёт-получателя        : нетто 0 — поступление мгновенно выдано клиенту;
--     • commission_account_id  : при fromAccount списана комиссия отдельно.
--
--   ЧТОБЫ ОБРАТИТЬ выдачу (без печати и без уничтожения денег) надо вернуть
--   ровно то, что КАЖДЫЙ счёт реально потерял по этому переводу — выводим из
--   ЖУРНАЛА, как 070, по каждому счёту отдельно:
--     net_per_account = Σ(debit) − Σ(credit)  по ledger_entries
--                       WHERE reference_id = transfer  AND account_id = X
--                       AND reference_type IN ('transfer','transfer_issuance',
--                                              'commission','partner_offset')
--     refund(X) = + net_per_account   (зеркалим ровно потерю).
--
--   ПРОВЕРКА (обычный перевод, fromSender, amount=100, commission=10,
--             converted_amount=100, разные счета источника и получателя):
--     • from_account   : debit 110 (тело+комиссия) → net=+110 → refund +110.
--     • to_account     : credit 100 + debit 100    → net=0    → refund 0.
--       Итог: 110 списанных со счёта-источника возвращены; у получателя как
--       было 0 нетто, так и осталось 0. Денег не печатаем, не уничтожаем. ✔
--
--   ПРОВЕРКА (fromAccount, комиссия 10 на отдельный commission_account_id):
--     • from_account       : debit 100 (только тело)         → net=+100 → refund +100.
--     • commission_account : credit 10 (доход от комиссии при
--                            оформлении) → net=−10 → reverse −10 (снимаем
--                            учтённый доход; ср. delete_transfer 070:145-152).
--     • to_account         : credit 100 + debit 100          → net=0    → refund 0.
--       Каждый счёт откатан ровно на свою проводку; доход по комиссии аннулирован. ✔
--
--   ВНИМАНИЕ: суммируем по account_id, поэтому даже если выдача шла на ТОТ ЖЕ
--   счёт, что и источник (теоретически), net по этому счёту учтёт и дебет
--   источника, и net-0 выдачи корректно. Перебор по всем затронутым счетам
--   гарантирует, что мы не пропустим commission_account и payout-счёт частичных
--   выдач (issue_transfer_partial мог писать на p_from_account_id).
--
-- ДЕЙСТВИЯ (атомарно, mirror delete_transfer):
--   1. Валидация: status='delivered' И via_counterparty_id IS NULL.
--   2. По каждому затронутому счёту вернуть его нетто-потерю на account_balances.
--   3. Записать аудит-строку в deleted_transfers (status_at_delete='delivered',
--      reason с пометкой REVERSAL, original_data — снимок перевода).
--   4. Удалить журнальные строки/комиссии/частичные выдачи/approvals и сам
--      перевод (hard-delete) — как delete_transfer.
--
-- ПОЧЕМУ HARD-DELETE, а не статус 'reversed'/'created':
--   CHECK transfers_status_check (миграция 022) допускает только
--   ('created','toDelivery','withCourier','delivered'); статуса 'reversed' нет,
--   а возврат в 'created' оставил бы перевод «живым» с уже снятым журналом —
--   рассинхрон. delete_transfer тоже хард-удаляет с аудитом, поэтому
--   повторяем его модель: запись в deleted_transfers = полный след отмены.
--
-- ДОСТУП: только creator/director (как ветка director у delete_transfer для
--   delivered). Accountant — нет.
--
-- РИСКИ / ДОПУЩЕНИЯ:
--   • НЕ протестировано на живой БД (она COLD/paused) — арифметика выверена
--     по журналу, но требует прогона на staging перед продакшеном.
--   • Допущение о наборе статусов: целевой статус строго 'delivered'; статуса
--     'reversed' в схеме нет, поэтому выбран hard-delete + аудит.
--   • Допущение: все денежные ledger-строки этого перевода имеют
--     reference_type ∈ ('transfer','transfer_issuance','commission',
--     'partner_offset'); иные типы (если появятся) в нетто НЕ войдут.
--   • via_counterparty_id IS NULL → партнёрского saldo тут нет, не трогаем.
--
-- Идемпотентно: CREATE OR REPLACE / DROP IF EXISTS. BEGIN/COMMIT.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION private.reverse_delivered_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_t transfers%ROWTYPE;
  v_snapshot jsonb;
  v_total_refunded double precision := 0;
  rec RECORD;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  -- ── Доступ: только creator/director (как delete_transfer для delivered) ──
  IF v_role NOT IN ('creator', 'director') THEN
    RAISE EXCEPTION 'Откат выданного перевода доступен только Creator/Director';
  END IF;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  -- ── Валидация: ровно обычный ВЫДАННЫЙ перевод ───────────────────────────
  IF v_t.status <> 'delivered' THEN
    RAISE EXCEPTION 'Откат выдачи возможен только для статуса «delivered» (текущий: %). '
                'Для «created» используйте delete_transfer.', v_t.status;
  END IF;
  IF v_t.via_counterparty_id IS NOT NULL THEN
    RAISE EXCEPTION 'Это партнёрский перевод — его откат выполняет delete_transfer '
                '(там откатывается saldo партнёра). reverse_delivered_transfer — '
                'только для обычных (via_counterparty_id IS NULL).';
  END IF;

  -- Снимок для аудита.
  v_snapshot := to_jsonb(v_t);

  -- ── REFUND по каждому затронутому счёту = нетто-потеря из журнала ────────
  -- net = Σ(debit) − Σ(credit) по этому переводу и счёту. Возвращаем + net:
  --   счёт-источник     → +тело(+комиссия)   (он реально отдал деньги);
  --   счёт-получателя   → +0  (credit+debit выдачи нетто-нейтральны);
  --   commission_account→ +комиссия (при fromAccount).
  -- Перебор по account_id гарантирует, что НИ ОДИН затронутый счёт (включая
  -- payout-счёт частичных выдач) не будет пропущен и НИ ОДИН не задвоится.
  FOR rec IN
    SELECT account_id,
           SUM(CASE WHEN type = 'debit' THEN amount ELSE -amount END) AS net
      FROM ledger_entries
     WHERE reference_id   = p_transfer_id::text
       AND account_id     IS NOT NULL
       AND reference_type IN ('transfer', 'transfer_issuance',
                              'commission', 'partner_offset')
     GROUP BY account_id
  LOOP
    IF rec.net IS NULL OR rec.net = 0 THEN
      CONTINUE;
    END IF;
    UPDATE account_balances
       SET balance    = balance + rec.net,
           updated_at = now()
     WHERE account_id = rec.account_id;
    v_total_refunded := v_total_refunded + rec.net;
  END LOOP;

  -- ── Аудит (mirror delete_transfer) ──────────────────────────────────────
  -- reason помечаем как REVERSAL, чтобы отличать откат выдачи от обычного
  -- удаления pending-перевода в той же таблице deleted_transfers.
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
    v_uid,
    '[REVERSAL выданного перевода] '
      || COALESCE(NULLIF(trim(coalesce(p_reason,'')), ''), '—'),
    v_snapshot
  );

  -- ── Удаление журнала / комиссий / выдач / approvals + самого перевода ───
  DELETE FROM ledger_entries
   WHERE reference_id = p_transfer_id::text
     AND reference_type IN ('transfer', 'commission', 'transfer_issuance', 'partner_offset');
  DELETE FROM commissions WHERE transfer_id = p_transfer_id;
  DELETE FROM transfer_issuances WHERE transfer_id = p_transfer_id;
  DELETE FROM pending_approvals WHERE target_id = p_transfer_id;

  DELETE FROM transfers WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'reversed', true,
    'refundedAmount', v_total_refunded,
    'refundedCurrency', v_t.currency
  );
END;
$$;

-- ── Публичная обёртка ────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.reverse_delivered_transfer(uuid, text);

CREATE FUNCTION public.reverse_delivered_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.reverse_delivered_transfer(p_transfer_id, p_reason);
$$;

GRANT EXECUTE ON FUNCTION public.reverse_delivered_transfer(uuid, text) TO authenticated;

COMMIT;
