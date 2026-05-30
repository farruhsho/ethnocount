-- ============================================================
-- 055: Деньги в numeric вместо double precision (F2)
-- ============================================================
-- Все денежные суммы и курсы хранились в double precision (float8).
-- При делении (amount / buy_rate) и накоплении saldo копилась
-- двоичная погрешность → сальдо не сходилось «в ноль» на копейки.
--
-- Решение: денежные колонки → numeric с фиксированной шкалой.
--   • суммы денег      → numeric(20,4)  (auto-округление при записи)
--   • курсы            → numeric(20,8)
--   • fee_percentage   → numeric(9,4)
-- Шкала колонки сама округляет «хвост» float при сохранении,
-- даже если внутри функции расчёт всё ещё идёт в double precision.
--
-- saldo_by_currency / client_balances.balances — JSONB; их округляем
-- в самих функциях (см. миграцию 056).
--
-- USING round(col::numeric, scale) — конвертирует существующие данные.
-- Повторное применение безопасно (numeric → numeric).
-- ============================================================

BEGIN;

-- ── Денежные суммы → numeric(20,4) ───────────────────────────
ALTER TABLE public.account_balances
  ALTER COLUMN balance TYPE numeric(20,4) USING round(balance::numeric, 4);

ALTER TABLE public.client_balances
  ALTER COLUMN balance TYPE numeric(20,4) USING round(balance::numeric, 4);

ALTER TABLE public.client_transactions
  ALTER COLUMN amount        TYPE numeric(20,4) USING round(amount::numeric, 4),
  ALTER COLUMN balance_after TYPE numeric(20,4) USING round(balance_after::numeric, 4);

ALTER TABLE public.commissions
  ALTER COLUMN amount TYPE numeric(20,4) USING round(amount::numeric, 4);

ALTER TABLE public.counterparty_transactions
  ALTER COLUMN amount            TYPE numeric(20,4) USING round(amount::numeric, 4),
  ALTER COLUMN closes_amount     TYPE numeric(20,4) USING round(closes_amount::numeric, 4),
  ALTER COLUMN settlement_profit TYPE numeric(20,4) USING round(settlement_profit::numeric, 4);

ALTER TABLE public.deleted_purchases
  ALTER COLUMN total_amount TYPE numeric(20,4) USING round(total_amount::numeric, 4);

ALTER TABLE public.deleted_transfers
  ALTER COLUMN amount TYPE numeric(20,4) USING round(amount::numeric, 4);

ALTER TABLE public.ledger_entries
  ALTER COLUMN amount TYPE numeric(20,4) USING round(amount::numeric, 4);

ALTER TABLE public.purchases
  ALTER COLUMN total_amount TYPE numeric(20,4) USING round(total_amount::numeric, 4);

ALTER TABLE public.transfer_issuances
  ALTER COLUMN amount TYPE numeric(20,4) USING round(amount::numeric, 4);

ALTER TABLE public.transfers
  ALTER COLUMN amount           TYPE numeric(20,4) USING round(amount::numeric, 4),
  ALTER COLUMN commission       TYPE numeric(20,4) USING round(commission::numeric, 4),
  ALTER COLUMN commission_value TYPE numeric(20,4) USING round(commission_value::numeric, 4),
  ALTER COLUMN converted_amount TYPE numeric(20,4) USING round(converted_amount::numeric, 4),
  ALTER COLUMN issued_amount    TYPE numeric(20,4) USING round(issued_amount::numeric, 4),
  ALTER COLUMN spread_profit    TYPE numeric(20,4) USING round(spread_profit::numeric, 4);

-- ── Курсы → numeric(20,8) ────────────────────────────────────
ALTER TABLE public.counterparty_transactions
  ALTER COLUMN exchange_rate TYPE numeric(20,8) USING round(exchange_rate::numeric, 8),
  ALTER COLUMN expected_rate TYPE numeric(20,8) USING round(expected_rate::numeric, 8);

ALTER TABLE public.exchange_rates
  ALTER COLUMN rate TYPE numeric(20,8) USING round(rate::numeric, 8);

ALTER TABLE public.transfers
  ALTER COLUMN buy_rate      TYPE numeric(20,8) USING round(buy_rate::numeric, 8),
  ALTER COLUMN sell_rate     TYPE numeric(20,8) USING round(sell_rate::numeric, 8),
  ALTER COLUMN exchange_rate TYPE numeric(20,8) USING round(exchange_rate::numeric, 8);

-- ── Процент комиссии партнёра → numeric(9,4) ────────────────
ALTER TABLE public.counterparties
  ALTER COLUMN fee_percentage TYPE numeric(9,4) USING round(fee_percentage::numeric, 4);

COMMIT;
