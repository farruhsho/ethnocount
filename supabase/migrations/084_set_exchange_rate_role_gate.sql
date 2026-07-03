-- ============================================================
-- 084: set_exchange_rate — ролевой гейт + санити курса
-- ============================================================
-- ПРОБЛЕМА (ре-аудит 07.2026, MEDIUM): private.set_exchange_rate (065)
-- проверяет ТОЛЬКО auth.uid() IS NOT NULL. Любой аутентифицированный
-- пользователь (в т.ч. «полуудалённый» с fallback-профилем, или бухгалтер
-- без права на курсы) может прямым RPC поставить любой курс — а курс
-- определяет сумму получателю по всем переводам. Плюс нет никакой санити:
-- нулевой/отрицательный/NaN/фантастический курс (1e61) принимался.
--
-- РЕШЕНИЕ:
--   • Гейт: разрешаем creator/director ИЛИ пользователю с правом
--     permissions->>'canExchangeRates'=true. Это ТО ЖЕ право, что гейтит
--     доступ к экрану курсов (app_router — canExchangeRates), поэтому:
--       – действующие бухгалтеры, ставящие курсы из UI, НЕ ломаются
--         (canExchangeRates по дефолту true, 001:33);
--       – «полуудалённый»/без строки в users отсекается (нет строки →
--         permission NULL → false, и не creator/director);
--       – RPC-гейт теперь совпадает с UI-гейтом страницы — нет рассинхрона
--         «кнопка видна, а БД отказывает».
--     (Если бизнес захочет сузить круг ставящих курс — вводится отдельное
--     canManageExchangeRates и гейт меняется на него; сейчас, по факту UI,
--     право на установку = право на экран курсов.)
--     ⚠️ Табличная политика rates_insert (WITH CHECK true) закрывается
--        отдельно в 085 — иначе прямой REST-INSERT в exchange_rates обходит
--        этот RPC-гейт целиком.
--   • Санити курса: > 0, конечное число (не NaN/Inf), в разумных пределах
--     (< 1e12) — та же паранойя и тот же порог, что 053 для клиентских
--     сумм (был инцидент с 1e61, ломавшим UI). 1e12 заведомо выше любого
--     реального курса поддерживаемых пар (самая слабая — UZS, ~1e4).
--
-- Тело 065 воспроизведено 1:1; добавлены только гейт и санити в начале.
-- Сигнатура и public-обёртка (010) сохранены → привилегии тоже.
-- Идемпотентно: CREATE OR REPLACE.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.set_exchange_rate(
  p_from_currency text,
  p_to_currency text,
  p_rate double precision
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_rate_id uuid;
  v_old_rate double precision;
  v_can_rates boolean;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  -- ── 084: ролевой гейт (creator/director ИЛИ canExchangeRates) ──
  SELECT COALESCE((permissions->>'canExchangeRates')::boolean, false)
    INTO v_can_rates
    FROM public.users WHERE id = v_user_id;

  IF NOT (private.is_creator_or_director() OR COALESCE(v_can_rates, false)) THEN
    RAISE EXCEPTION 'Недостаточно прав для установки курса (нужна роль creator/director или право доступа к курсам)';
  END IF;

  -- ── 084: санити курса ──
  IF p_rate IS NULL OR p_rate <> p_rate THEN            -- NaN не равен сам себе
    RAISE EXCEPTION 'Курс должен быть числом';
  END IF;
  IF p_rate <= 0 THEN
    RAISE EXCEPTION 'Курс должен быть больше нуля';
  END IF;
  IF p_rate >= 1e12 THEN
    RAISE EXCEPTION 'Курс вне разумных пределов (%). Проверьте ввод.', p_rate;
  END IF;

  -- Последний установленный курс той же пары ДО вставки нового ряда.
  SELECT rate INTO v_old_rate
    FROM exchange_rates
   WHERE from_currency = p_from_currency
     AND to_currency   = p_to_currency
   ORDER BY effective_at DESC, created_at DESC
   LIMIT 1;

  v_rate_id := gen_random_uuid();
  INSERT INTO exchange_rates (id, from_currency, to_currency, rate, set_by, effective_at)
  VALUES (v_rate_id, p_from_currency, p_to_currency, p_rate, v_user_id, now());

  INSERT INTO audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('set_exchange_rate', 'exchangeRate', v_rate_id::text, v_user_id,
          jsonb_build_object(
            'fromCurrency', p_from_currency,
            'toCurrency',   p_to_currency,
            'rate',         p_rate,
            'oldRate',      v_old_rate,
            'newRate',      p_rate
          ));

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMIT;
