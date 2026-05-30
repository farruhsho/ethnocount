-- ============================================================
-- 038: Backfill buy/sell/base_currency on historical transfers
-- ============================================================
-- В 036 ввели дилерскую модель (buy_rate/sell_rate/spread_profit).
-- Старые переводы остались с NULL по этим полям → аналитика
-- spread = 0 для истории. Пользователь хочет вручную проставить
-- курсы для значимых исторических переводов.
--
-- Backfill только обновляет transfers.{buy_rate, sell_rate,
-- base_currency, spread_profit}. Не трогает saldo, ledger, account
-- balances — это уже зафиксировано (если был sell=12000, saldo
-- осталось как было). Бэкфил — ТОЛЬКО для аналитики.
--
-- Только creator/director может вызывать. Идемпотентно — можно
-- вызвать повторно с другими курсами (перезатирает).
--
-- Также добавляем `transfers_missing_rates_for_partner(p_counterparty_id)`
-- — список переводов где есть via_counterparty_id, но нет buy/sell.
-- Используется в UI как фильтр «нужно проставить курсы».
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.backfill_transfer_rates(
  p_transfer_id    uuid,
  p_buy_rate       double precision,
  p_sell_rate      double precision,
  p_base_currency  text,
  p_note           text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_t transfers%ROWTYPE;
  v_new_spread double precision;
  v_old_changes jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role NOT IN ('creator', 'director') THEN
    RAISE EXCEPTION 'Только Creator/Director может проставлять курсы';
  END IF;

  IF p_buy_rate IS NULL OR p_buy_rate <= 0 THEN
    RAISE EXCEPTION 'buy_rate должен быть > 0';
  END IF;
  IF p_sell_rate IS NULL OR p_sell_rate <= 0 THEN
    RAISE EXCEPTION 'sell_rate должен быть > 0';
  END IF;
  IF p_base_currency IS NULL OR length(trim(p_base_currency)) = 0 THEN
    RAISE EXCEPTION 'base_currency обязательна';
  END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  -- Защита от полного бессмысленного backfill-а: если base = currency,
  -- spread всегда 0, smysla bekfilа нет. Разрешаем, но spread = 0.
  IF trim(p_base_currency) = v_t.currency THEN
    v_new_spread := 0;
  ELSE
    v_new_spread := private.calc_spread_profit(
      v_t.amount, p_buy_rate, p_sell_rate);
  END IF;

  -- Фиксируем в amendment_history что было до изменения.
  v_old_changes := jsonb_build_object(
    'buy_rate',      jsonb_build_object('from', v_t.buy_rate,      'to', p_buy_rate),
    'sell_rate',     jsonb_build_object('from', v_t.sell_rate,     'to', p_sell_rate),
    'base_currency', jsonb_build_object('from', v_t.base_currency, 'to', trim(p_base_currency)),
    'spread_profit', jsonb_build_object('from', v_t.spread_profit, 'to', v_new_spread)
  );

  UPDATE transfers SET
    buy_rate       = p_buy_rate,
    sell_rate      = p_sell_rate,
    base_currency  = trim(p_base_currency),
    spread_profit  = v_new_spread,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at',      now(),
          'userId',  v_uid::text,
          'kind',    'backfill_rates',
          'note',    NULLIF(trim(coalesce(p_note,'')), ''),
          'changes', v_old_changes
        )
      )
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'spreadProfit', v_new_spread,
    'spreadCurrency', v_t.currency
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.backfill_transfer_rates(
  p_transfer_id    uuid,
  p_buy_rate       double precision,
  p_sell_rate      double precision,
  p_base_currency  text,
  p_note           text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.backfill_transfer_rates(
    p_transfer_id, p_buy_rate, p_sell_rate, p_base_currency, p_note);
$$;

GRANT EXECUTE ON FUNCTION public.backfill_transfer_rates(
  uuid, double precision, double precision, text, text
) TO authenticated;


-- ─── Список переводов без проставленных курсов ───────────────
-- Используется в UI карточки партнёра — показать пользователю
-- сколько исторических переводов ещё ждут backfill.
CREATE OR REPLACE FUNCTION private.transfers_missing_rates_for_partner(
  p_counterparty_id uuid,
  p_limit int DEFAULT 200
) RETURNS TABLE (
  id uuid,
  transaction_code text,
  amount double precision,
  currency text,
  to_currency text,
  receiver_name text,
  created_at timestamptz,
  status text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    t.id,
    t.transaction_code,
    t.amount,
    t.currency,
    t.to_currency,
    t.receiver_name,
    t.created_at,
    t.status::text
  FROM transfers t
  WHERE t.via_counterparty_id = p_counterparty_id
    AND (t.buy_rate IS NULL OR t.sell_rate IS NULL)
    AND t.status NOT IN ('cancelled', 'rejected')
  ORDER BY t.created_at DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION public.transfers_missing_rates_for_partner(
  p_counterparty_id uuid,
  p_limit int DEFAULT 200
) RETURNS TABLE (
  id uuid,
  transaction_code text,
  amount double precision,
  currency text,
  to_currency text,
  receiver_name text,
  created_at timestamptz,
  status text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.transfers_missing_rates_for_partner(p_counterparty_id, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.transfers_missing_rates_for_partner(uuid, int)
  TO authenticated;


-- ─── Детальная транзакция для UI tile (joined с transfer) ────
-- Расширенная замена counterparty_transactions select для карточки
-- партнёра — возвращает op + соответствующие buy/sell/spread с transfer-а.
CREATE OR REPLACE FUNCTION private.counterparty_tx_detail(
  p_counterparty_id uuid,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid,
  kind text,
  amount double precision,
  currency text,
  description text,
  created_at timestamptz,
  transfer_id uuid,
  transaction_code text,
  payout_method text,
  buy_rate double precision,
  sell_rate double precision,
  base_currency text,
  spread_profit double precision,
  transfer_amount double precision,
  transfer_currency text,
  via_counterparty boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cpt.id,
    cpt.kind,
    cpt.amount,
    cpt.currency,
    cpt.description,
    cpt.created_at,
    cpt.transfer_id,
    t.transaction_code,
    cpt.payout_method,
    t.buy_rate,
    t.sell_rate,
    t.base_currency,
    t.spread_profit,
    t.amount AS transfer_amount,
    t.currency AS transfer_currency,
    (t.via_counterparty_id IS NOT NULL) AS via_counterparty
  FROM counterparty_transactions cpt
  LEFT JOIN transfers t ON t.id = cpt.transfer_id
  WHERE cpt.counterparty_id = p_counterparty_id
  ORDER BY cpt.created_at DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION public.counterparty_tx_detail(
  p_counterparty_id uuid,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid,
  kind text,
  amount double precision,
  currency text,
  description text,
  created_at timestamptz,
  transfer_id uuid,
  transaction_code text,
  payout_method text,
  buy_rate double precision,
  sell_rate double precision,
  base_currency text,
  spread_profit double precision,
  transfer_amount double precision,
  transfer_currency text,
  via_counterparty boolean
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparty_tx_detail(p_counterparty_id, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.counterparty_tx_detail(uuid, int)
  TO authenticated;

COMMIT;
