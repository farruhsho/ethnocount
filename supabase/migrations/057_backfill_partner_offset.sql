-- ============================================================
-- 057: Бэкфилл отката двойного дебета по партнёрским переводам (F1)
-- ============================================================
-- До миграции 056 attach_transfer_to_partner НЕ откатывал дебет
-- счёта-источника. Поэтому по уже существующим партнёрским
-- переводам касса была списана дважды (при оформлении и при
-- расчёте). Этот бэкфилл возвращает на счёт сумму дебета,
-- сделанного при оформлении (как теперь делает attach), и
-- ставит маркер partner_offset.
--
-- ВКЛЮЧАЮТСЯ только «чистые» партнёрские переводы:
--   • via_counterparty_id IS NOT NULL
--   • без выдачи (issued_amount = 0 И нет строк transfer_issuances)
--   • откат ещё не сделан (нет открытого partner_offset)
--
-- ИСКЛЮЧАЮТСЯ конфликтные переводы (есть И выдача из нашей кассы,
-- И долг партнёра) — их нельзя чинить автоматически, требуется
-- ручное решение (платил партнёр или мы). На момент миграции это
-- ELX-2026-000010 и ELX-2026-000019.
--
-- Идемпотентно: повторный запуск ничего не сделает (guard по
-- открытому partner_offset).
-- ============================================================

BEGIN;

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT
      t.id,
      t.from_account_id,
      t.from_branch_id,
      t.currency,
      t.transaction_code,
      t.created_by,
      (SELECT le.amount FROM ledger_entries le
         WHERE le.reference_type = 'transfer'
           AND le.type = 'debit'
           AND le.reference_id = t.id::text
         ORDER BY le.created_at
         LIMIT 1) AS creation_debit
    FROM transfers t
    WHERE t.via_counterparty_id IS NOT NULL
      AND COALESCE(t.issued_amount, 0) = 0
      AND NOT EXISTS (SELECT 1 FROM transfer_issuances ti WHERE ti.transfer_id = t.id)
      AND COALESCE((
            SELECT SUM(CASE WHEN le.type = 'credit' THEN le.amount ELSE -le.amount END)
            FROM ledger_entries le
            WHERE le.reference_type = 'partner_offset'
              AND le.reference_id = t.id::text), 0) = 0
      AND t.from_account_id IS NOT NULL
  LOOP
    IF r.creation_debit IS NULL OR r.creation_debit <= 0 THEN
      CONTINUE;
    END IF;

    UPDATE account_balances
       SET balance = round((balance + r.creation_debit)::numeric, 4),
           updated_at = now()
     WHERE account_id = r.from_account_id;

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES
      (r.from_branch_id, r.from_account_id, 'credit', r.creation_debit, r.currency,
       'partner_offset', r.id::text, r.transaction_code,
       'Бэкфилл 057: откат двойного дебета (оплату покрывает партнёр)',
       r.created_by);
  END LOOP;
END $$;

COMMIT;
