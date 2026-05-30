-- ============================================================
-- 063: Ручное разрешение конфликтных партнёрских переводов (F1, follow-up к 057)
-- ============================================================
-- Миграция 057 исключила из бэкфилла два «конфликтных» перевода —
-- по ним была И выдача из нашей кассы (issued_amount > 0 /
-- transfer_issuances), И долг партнёра (paid_for_us в saldo).
-- Это взаимоисключающие записи: либо платил партнёр, либо мы.
--
-- Разбор фактических данных показал, что в ОБОИХ случаях платили МЫ
-- из своей кассы, а прикрепление к партнёру — ошибка оператора:
--
--   • ELX-2026-000010 (farruh, RUB→UZS, delivered): получателю
--     полностью выдано 255 200 000 UZS тремя выдачами 12.05.
--     Прикреплён к партнёру 26.05 — через 2 недели после доставки.
--     Фантомный долг saldo RUB −20000.
--   • ELX-2026-000019 (Xayrullo, USD, toDelivery): из нашей кассы
--     уже выдано 7000 USD из 10000. Прикреплён к партнёру через
--     3 минуты после начала выдачи. Фантомный долг saldo USD −10100.
--
-- Лечение = корректная отвязка (как private.detach_transfer_from_partner):
--   1) вернуть saldo по каждой paid_for_us (+amount), ключ-валюту
--      удалить, если обнулилась;
--   2) удалить paid_for_us counterparty_transactions перевода;
--   3) снять via_counterparty_id, обнулить spread_profit, записать
--      в amendment_history.
--
-- Кассу НЕ трогаем: partner_offset по этим переводам = 0 (откат при
-- привязке не делался, оформлены до миграции 056), поэтому исходное
-- списание счёта-источника остаётся как корректная стоимость
-- операции «платим мы». saldo других валют партнёра (например
-- farruh UZS −500000 из ELX-2026-000017) НЕ затрагивается.
--
-- Идемпотентно: повторный запуск ничего не делает (guard по
-- via_counterparty_id IS NOT NULL).
-- ============================================================

BEGIN;

DO $$
DECLARE
  r RECORD;
  op RECORD;
  v_curr_saldo numeric;
  v_new_saldo  numeric;
  v_offset_outstanding numeric;
BEGIN
  FOR r IN
    SELECT t.id, t.via_counterparty_id, t.transaction_code, t.status
    FROM transfers t
    WHERE t.transaction_code IN ('ELX-2026-000010', 'ELX-2026-000019')
      AND t.via_counterparty_id IS NOT NULL
      -- только конфликтные: есть реальная выдача из нашей кассы
      AND (COALESCE(t.issued_amount, 0) > 0
           OR EXISTS (SELECT 1 FROM transfer_issuances ti WHERE ti.transfer_id = t.id))
  LOOP
    -- Safety: если по переводу был откат кассы (partner_offset <> 0),
    -- это другой сценарий — пропускаем, чтобы не потерять деньги.
    SELECT COALESCE(SUM(CASE WHEN type = 'credit' THEN amount ELSE -amount END), 0)
      INTO v_offset_outstanding
      FROM ledger_entries
      WHERE reference_type = 'partner_offset' AND reference_id = r.id::text;

    IF v_offset_outstanding <> 0 THEN
      RAISE NOTICE '063: пропуск % — есть partner_offset=%, нужна ручная проверка',
        r.transaction_code, v_offset_outstanding;
      CONTINUE;
    END IF;

    -- 1) Возврат saldo по каждой paid_for_us операции.
    FOR op IN
      SELECT amount, currency FROM counterparty_transactions
      WHERE transfer_id = r.id AND kind = 'paid_for_us'
    LOOP
      SELECT round(COALESCE((saldo_by_currency->>op.currency)::numeric, 0), 4)
        INTO v_curr_saldo
        FROM counterparties WHERE id = r.via_counterparty_id;
      v_new_saldo := round((v_curr_saldo + op.amount)::numeric, 4);

      UPDATE counterparties
         SET saldo_by_currency = CASE
               WHEN v_new_saldo = 0
                 THEN saldo_by_currency - op.currency
               ELSE saldo_by_currency || jsonb_build_object(op.currency, v_new_saldo)
             END
       WHERE id = r.via_counterparty_id;
    END LOOP;

    -- 2) Удаляем фантомные paid_for_us транзакции перевода.
    DELETE FROM counterparty_transactions
      WHERE transfer_id = r.id AND kind = 'paid_for_us';

    -- 3) Снимаем привязку к партнёру (платим мы), обнуляем партнёрский
    --    spread_profit и фиксируем в истории.
    UPDATE transfers SET
      via_counterparty_id = NULL,
      spread_profit = NULL,
      amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
        jsonb_build_array(jsonb_build_object(
          'at', now(),
          'kind', 'detach_from_partner',
          'reason', 'migration_063_conflict_resolution',
          'note', 'Выплата сделана из нашей кассы (issuances); фантомный долг партнёра убран',
          'status_at_detach', r.status::text))
    WHERE id = r.id;
  END LOOP;
END $$;

COMMIT;
