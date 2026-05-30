-- ============================================================
-- 035: update_counterparty + recent_partner_receivers
-- ============================================================
-- 1) Изменение данных партнёра: имя, город, телефон, заметки,
--    fee_percentage, home_branch_id. Любое поле можно прислать NULL —
--    тогда оно не меняется. Чтобы ЯВНО обнулить, шлём '' (empty string)
--    для текстовых и отдельный sentinel для uuid.
--    Бухгалтер может править только партнёров без home_branch_id или
--    привязанных к его филиалу — creator/director без ограничений.
--
-- 2) Последние получатели через конкретного партнёра — для быстрого
--    подставления в новый партнёрский перевод.
--    Возвращает уникальные receiver_phone (последние 10 по дате)
--    с агрегированными name/info/transfer_count.
--
-- Идемпотентно — CREATE OR REPLACE.
-- ============================================================

BEGIN;

-- Sentinel для «явно обнулить uuid».
-- '00000000-0000-0000-0000-000000000000' — клиент может его прислать,
-- чтобы сказать «убрать home_branch_id». NULL означает «не менять».
CREATE OR REPLACE FUNCTION private.update_counterparty(
  p_counterparty_id uuid,
  p_name text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_clear_home_branch boolean DEFAULT false,
  p_clear_fee boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_cp counterparties%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
  FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;

  -- Бухгалтер: только партнёры без home_branch_id или прикреплённые к
  -- его филиалу. Creator/director — без ограничений.
  IF v_role = 'accountant' THEN
    IF v_cp.home_branch_id IS NOT NULL
       AND NOT (v_cp.home_branch_id::text = ANY(COALESCE(v_assigned, ARRAY[]::text[]))) THEN
      RAISE EXCEPTION 'Этот партнёр привязан к чужому филиалу — править не можете';
    END IF;
    -- Бухгалтер не может менять home_branch_id и fee_percentage —
    -- это «политические» поля.
    IF p_home_branch_id IS NOT NULL OR p_clear_home_branch THEN
      RAISE EXCEPTION 'Привязку к филиалу меняет только Creator/Director';
    END IF;
    IF p_fee_percentage IS NOT NULL OR p_clear_fee THEN
      RAISE EXCEPTION 'Комиссию партнёра меняет только Creator/Director';
    END IF;
  END IF;

  -- Валидация имени — если передано.
  IF p_name IS NOT NULL THEN
    IF length(trim(p_name)) < 2 THEN
      RAISE EXCEPTION 'Имя должно быть длиннее 1 символа';
    END IF;
  END IF;

  -- Валидация fee_percentage.
  IF p_fee_percentage IS NOT NULL THEN
    IF p_fee_percentage < 0 THEN
      RAISE EXCEPTION 'Комиссия должна быть ≥ 0';
    END IF;
    IF p_fee_percentage > 50 THEN
      RAISE EXCEPTION 'Слишком большая комиссия: %', p_fee_percentage;
    END IF;
  END IF;

  -- Валидация home_branch_id.
  IF p_home_branch_id IS NOT NULL THEN
    PERFORM 1 FROM public.branches WHERE id = p_home_branch_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Филиал не найден: %', p_home_branch_id;
    END IF;
  END IF;

  UPDATE counterparties SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    city = CASE
      WHEN p_city IS NULL THEN city
      WHEN trim(p_city) = '' THEN NULL
      ELSE trim(p_city)
    END,
    phone = CASE
      WHEN p_phone IS NULL THEN phone
      WHEN trim(p_phone) = '' THEN NULL
      ELSE private.normalize_phone(p_phone)
    END,
    notes = CASE
      WHEN p_notes IS NULL THEN notes
      WHEN trim(p_notes) = '' THEN NULL
      ELSE trim(p_notes)
    END,
    fee_percentage = CASE
      WHEN p_clear_fee THEN NULL
      WHEN p_fee_percentage IS NULL THEN fee_percentage
      ELSE p_fee_percentage
    END,
    home_branch_id = CASE
      WHEN p_clear_home_branch THEN NULL
      WHEN p_home_branch_id IS NULL THEN home_branch_id
      ELSE p_home_branch_id
    END
  WHERE id = p_counterparty_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_counterparty(
  p_counterparty_id uuid,
  p_name text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_clear_home_branch boolean DEFAULT false,
  p_clear_fee boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.update_counterparty(
    p_counterparty_id, p_name, p_city, p_phone, p_notes,
    p_fee_percentage, p_home_branch_id, p_clear_home_branch, p_clear_fee
  );
$$;

GRANT EXECUTE ON FUNCTION public.update_counterparty(
  uuid, text, text, text, text, double precision, uuid, boolean, boolean
) TO authenticated;


-- ─── Последние получатели через конкретного партнёра ──────────
-- Дедуплицируем по receiver_phone, выбираем самый свежий transfer
-- для каждого. limit 10 — больше в UI не поместится визуально.
CREATE OR REPLACE FUNCTION private.recent_partner_receivers(
  p_counterparty_id uuid,
  p_limit int DEFAULT 10
) RETURNS TABLE (
  phone text,
  name text,
  info text,
  last_amount double precision,
  last_currency text,
  last_at timestamptz,
  transfer_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH ranked AS (
    SELECT
      t.receiver_phone AS phone,
      t.receiver_name  AS name,
      t.receiver_info  AS info,
      t.amount         AS amount,
      t.currency       AS currency,
      t.created_at     AS created_at,
      ROW_NUMBER() OVER (
        PARTITION BY COALESCE(t.receiver_phone, t.receiver_name)
        ORDER BY t.created_at DESC
      ) AS rn,
      COUNT(*) OVER (PARTITION BY COALESCE(t.receiver_phone, t.receiver_name))
        AS transfer_count
    FROM transfers t
    WHERE t.via_counterparty_id = p_counterparty_id
      AND (t.receiver_phone IS NOT NULL OR t.receiver_name IS NOT NULL)
  )
  SELECT phone, name, info, amount AS last_amount,
         currency AS last_currency, created_at AS last_at,
         transfer_count
  FROM ranked
  WHERE rn = 1
  ORDER BY created_at DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION public.recent_partner_receivers(
  p_counterparty_id uuid,
  p_limit int DEFAULT 10
) RETURNS TABLE (
  phone text,
  name text,
  info text,
  last_amount double precision,
  last_currency text,
  last_at timestamptz,
  transfer_count bigint
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.recent_partner_receivers(p_counterparty_id, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.recent_partner_receivers(uuid, int)
  TO authenticated;


-- ─── Экспорт операций партнёра ───────────────────────────────
-- Возвращает плоский список tx за период с расшифровкой kind →
-- человекочитаемый label. На клиенте сериализуется в CSV.
CREATE OR REPLACE FUNCTION private.counterparty_tx_export(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL
) RETURNS TABLE (
  created_at timestamptz,
  kind text,
  kind_label text,
  amount double precision,
  currency text,
  description text,
  payout_method text,
  exchange_rate double precision,
  cash_account_id uuid,
  transfer_id uuid,
  transaction_code text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cpt.created_at,
    cpt.kind,
    CASE cpt.kind
      WHEN 'paid_for_us'      THEN 'Он выплатил клиенту'
      WHEN 'we_paid_for_them' THEN 'Мы выплатили клиенту'
      WHEN 'settle_to_us'     THEN 'Он привёз нам нал'
      WHEN 'settle_from_us'   THEN 'Мы отдали ему нал'
      ELSE cpt.kind
    END AS kind_label,
    cpt.amount,
    cpt.currency,
    cpt.description,
    cpt.payout_method,
    cpt.exchange_rate,
    cpt.cash_account_id,
    cpt.transfer_id,
    t.transaction_code
  FROM counterparty_transactions cpt
  LEFT JOIN transfers t ON t.id = cpt.transfer_id
  WHERE cpt.counterparty_id = p_counterparty_id
    AND (p_start IS NULL OR cpt.created_at >= p_start)
    AND (p_end   IS NULL OR cpt.created_at <  p_end)
  ORDER BY cpt.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.counterparty_tx_export(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL
) RETURNS TABLE (
  created_at timestamptz,
  kind text,
  kind_label text,
  amount double precision,
  currency text,
  description text,
  payout_method text,
  exchange_rate double precision,
  cash_account_id uuid,
  transfer_id uuid,
  transaction_code text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparty_tx_export(p_counterparty_id, p_start, p_end);
$$;

GRANT EXECUTE ON FUNCTION public.counterparty_tx_export(uuid, timestamptz, timestamptz)
  TO authenticated;

COMMIT;
