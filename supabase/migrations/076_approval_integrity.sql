-- ============================================================
-- 076: целостность согласований — TOCTOU и устаревший снимок
-- ============================================================
-- Две дыры forensic-аудита в workflow согласований (021/052/074):
--
--   #14 (TOCTOU / двойное применение).
--     Защита от дублей в private.request_approval — это проверка
--     `IF EXISTS (... status='pending')` ВНУТРИ транзакции без
--     уникального ограничения. Две заявки на одну и ту же
--     (target_id, action), пришедшие одновременно, обе проходят
--     EXISTS-проверку (каждая ещё не видит чужой неподтверждённый
--     INSERT) и обе создаются. Дальше директор (или два директора)
--     одобряют ОБЕ → мутация применяется дважды (двойной reject,
--     двойная правка суммы и т.п.).
--     Вдобавок сам private.approve_request переводит статус в
--     'approved' ПОСЛЕ диспатча мутации. Значит два параллельных
--     approve одной заявки: оба берут FOR UPDATE по очереди, но
--     первый коммитит '_result_' и 'approved' лишь в конце — окно
--     невелико, но статус-флип не атомарен относительно диспатча.
--
--     Чиним:
--       (a) UNIQUE partial index на (target_id, action) WHERE
--           status='pending' — БД физически не даёт существовать
--           двум pending-заявкам на одну цель/действие. EXISTS-guard
--           в request_approval остаётся (даёт дружелюбную ошибку),
--           но теперь подстрахован ограничением на уровне БД.
--       (b) approve_request СНАЧАЛА перечитывает строку FOR UPDATE,
--           проверяет status='pending' и АТОМАРНО флипает её в
--           'approved' (UPDATE ... WHERE status='pending' RETURNING),
--           и только если флип реально затронул строку — диспатчит
--           мутацию. Второй параллельный approve увидит 0 строк во
--           флипе (либо дождётся блокировки и получит уже 'approved')
--           →RAISE, мутация не вызывается повторно.
--
--   #15 (устаревший снимок _before).
--     Снимок текущего состояния target кладётся в payload._before в
--     момент СОЗДАНИЯ заявки (request_approval). Между запросом и
--     approve цель могла измениться. Директор тогда сверяет diff
--     против устаревшего before и одобряет «вслепую».
--
--     Чиним в approve_request, перечитывая target НА МОМЕНТ approve:
--       • Денежные мутации (transfer_reject, transfer_amend_amount):
--         option (b) — если снимок отличается от текущего состояния,
--         RAISE с просьбой пересоздать заявку. Безопаснее отклонить,
--         чем применить деньги против устаревшего контекста.
--       • Неденежные (client_/branch_account_): option (a) — освежаем
--         payload._before до актуального состояния, чтобы аудит и
--         повторный просмотр показывали корректный diff. Аудит-след
--         сохраняется: пишем approval.snapshot_refreshed в audit_logs.
--
-- Идемпотентно. DROP+CREATE+GRANT (сигнатура approve_request не
-- меняется, но переписываем тело; index создаём IF NOT EXISTS).
-- Обёрнуто в BEGIN/COMMIT.
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. #14 — UNIQUE partial index против дублей pending-заявок
-- ─────────────────────────────────────────────────────────────
-- Максимум одна 'pending'-заявка на одну (target_id, action). Для
-- 'approved'/'rejected' дублей сколько угодно (история). Если в
-- таблице уже есть конфликтующие живые дубли (попавшие до этой
-- миграции через TOCTOU) — создание индекса упадёт; их нужно сначала
-- разрулить вручную (approve/reject лишних). На холодной БД дублей нет.
CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_approvals_target_action_pending
  ON public.pending_approvals (target_id, action)
  WHERE status = 'pending';

-- ─────────────────────────────────────────────────────────────
-- 2. #14 + #15 — approve_request: атомарный флип + проверка снимка
-- ─────────────────────────────────────────────────────────────
-- Сигнатура (uuid, text) не меняется. DROP перед CREATE, чтобы тело
-- гарантированно заменилось, затем повторный GRANT.
DROP FUNCTION IF EXISTS private.approve_request(uuid, text);

CREATE FUNCTION private.approve_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req public.pending_approvals%ROWTYPE;
  v_result jsonb;
  v_payload jsonb;
  v_now_before jsonb;       -- актуальный снимок target на момент approve
  v_flipped uuid;           -- id строки, реально переведённой в approved
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может одобрять заявки';
  END IF;

  -- Блокируем строку заявки и читаем её. FOR UPDATE сериализует
  -- параллельные approve по одной заявке.
  SELECT * INTO v_req
    FROM public.pending_approvals
    WHERE id = p_approval_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Заявка не найдена'; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'Заявка уже % раннее', v_req.status;
  END IF;

  v_payload := COALESCE(v_req.payload, '{}'::jsonb);

  -- ── #15: перечитываем target НА МОМЕНТ approve тем же набором полей,
  -- что и снимок _before в request_approval (021/052/074). Если цели
  -- больше нет — RAISE.
  CASE v_req.action
    WHEN 'transfer_reject', 'transfer_amend_amount' THEN
      SELECT jsonb_build_object(
        'amount', amount,
        'currency', currency,
        'to_currency', to_currency,
        'exchange_rate', exchange_rate,
        'commission', commission,
        'description', description,
        'receiver_name', receiver_name,
        'receiver_phone', receiver_phone,
        'status', status::text
      )
        INTO v_now_before
        FROM public.transfers
        WHERE id = v_req.target_id
        FOR UPDATE;
      IF v_now_before IS NULL THEN
        RAISE EXCEPTION 'Перевод изменился или удалён — пересоздайте заявку';
      END IF;

    WHEN 'client_update', 'client_archive' THEN
      SELECT jsonb_build_object(
        'name', name,
        'phone', phone,
        'country', country,
        'currency', currency,
        'branch_id', branch_id,
        'wallet_currencies', wallet_currencies,
        'is_active', is_active,
        'telegram_chat_id', telegram_chat_id
      )
        INTO v_now_before
        FROM public.clients
        WHERE id = v_req.target_id;
      IF v_now_before IS NULL THEN
        RAISE EXCEPTION 'Клиент изменился или удалён — пересоздайте заявку';
      END IF;

    WHEN 'branch_account_update', 'branch_account_archive' THEN
      SELECT jsonb_build_object(
        'name', name,
        'type', type,
        'currency', currency,
        -- маскируем PAN так же, как снимок в 074 — иначе diff всегда
        -- «отличался бы» (mask vs raw).
        'card_number', private.mask_pan(card_number),
        'cardholder_name', cardholder_name,
        'bank_name', bank_name,
        'expiry_month', expiry_month,
        'expiry_year', expiry_year,
        'notes', notes,
        'is_active', is_active,
        'sort_order', sort_order
      )
        INTO v_now_before
        FROM public.branch_accounts
        WHERE id = v_req.target_id;
      IF v_now_before IS NULL THEN
        RAISE EXCEPTION 'Счёт изменился или удалён — пересоздайте заявку';
      END IF;
  END CASE;

  -- ── #15: реакция на расхождение снимка.
  CASE v_req.action
    -- Денежные мутации → option (b): расхождение = отказ с просьбой
    -- пересоздать заявку. Безопаснее, чем применить деньги вслепую.
    WHEN 'transfer_reject', 'transfer_amend_amount' THEN
      IF (v_payload->'_before') IS DISTINCT FROM v_now_before THEN
        RAISE EXCEPTION
          'Перевод изменился с момента запроса — пересмотрите и пересоздайте заявку';
      END IF;

    -- Неденежные → option (a): освежаем _before до актуального
    -- состояния, чтобы аудит/просмотр показывали корректный diff.
    WHEN 'client_update', 'client_archive',
         'branch_account_update', 'branch_account_archive' THEN
      IF (v_payload->'_before') IS DISTINCT FROM v_now_before THEN
        v_payload := v_payload || jsonb_build_object('_before', v_now_before);
        UPDATE public.pending_approvals
          SET payload = v_payload
          WHERE id = p_approval_id;

        INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
        VALUES ('approval.snapshot_refreshed', 'pending_approval', p_approval_id::text, v_uid,
                jsonb_build_object(
                  'action', v_req.action::text,
                  'targetId', v_req.target_id::text,
                  'refreshedBefore', v_now_before
                ));
      END IF;
  END CASE;

  -- ── #14: АТОМАРНЫЙ флип статуса ПЕРЕД диспатчем мутации.
  -- UPDATE ... WHERE status='pending' RETURNING — если строку уже
  -- увёл параллельный approve (после нашего FOR UPDATE такого быть не
  -- должно, но это второй пояс безопасности), RETURNING вернёт 0 строк
  -- → RAISE и мутация НЕ диспатчится.
  UPDATE public.pending_approvals SET
    status = 'approved',
    reviewed_by = v_uid,
    reviewed_at = now(),
    review_note = NULLIF(trim(p_note), '')
  WHERE id = p_approval_id
    AND status = 'pending'
  RETURNING id INTO v_flipped;

  IF v_flipped IS NULL THEN
    RAISE EXCEPTION 'Заявка уже обработана другим одобрением';
  END IF;

  -- Диспатч по action — выполняется ровно один раз, т.к. статус уже
  -- переведён в 'approved' под блокировкой строки.
  CASE v_req.action
    WHEN 'transfer_reject' THEN
      v_result := private.reject_transfer(
        v_req.target_id,
        v_payload->>'reason'
      );

    WHEN 'transfer_amend_amount' THEN
      v_result := private.update_transfer_amount(
        v_req.target_id,
        (v_payload->>'amount')::double precision,
        v_payload->>'note'
      );

    WHEN 'client_update' THEN
      v_result := private.admin_update_client(
        v_req.target_id,
        v_payload->>'name',
        v_payload->>'phone',
        v_payload->>'country',
        v_payload->>'currency',
        v_payload->>'branch_id',
        CASE WHEN v_payload ? 'wallet_currencies'
             THEN ARRAY(SELECT jsonb_array_elements_text(v_payload->'wallet_currencies'))
             ELSE NULL END,
        v_payload->>'counterparty_id',
        v_payload->>'telegram_chat_id',
        COALESCE((v_payload->>'clear_telegram')::boolean, false)
      );

    WHEN 'client_archive' THEN
      v_result := private.admin_archive_client(
        v_req.target_id,
        COALESCE((v_payload->>'archive')::boolean, true)
      );

    WHEN 'branch_account_update' THEN
      v_result := private.admin_update_branch_account(
        v_req.target_id,
        v_payload->>'name',
        v_payload->>'type',
        v_payload->>'currency',
        v_payload->>'card_number',
        COALESCE((v_payload->>'clear_card_number')::boolean, false),
        v_payload->>'cardholder_name',
        v_payload->>'bank_name',
        NULLIF(v_payload->>'expiry_month', '')::smallint,
        NULLIF(v_payload->>'expiry_year', '')::smallint,
        v_payload->>'notes',
        NULLIF(v_payload->>'sort_order', '')::int
      );

    WHEN 'branch_account_archive' THEN
      v_result := private.admin_archive_branch_account(
        v_req.target_id,
        COALESCE((v_payload->>'archive')::boolean, true)
      );
  END CASE;

  -- Дописываем результат исполнения в уже переведённую строку.
  UPDATE public.pending_approvals SET
    execution_result = v_result
  WHERE id = p_approval_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('approval.approved', 'pending_approval', p_approval_id::text, v_uid,
          jsonb_build_object(
            'action', v_req.action::text,
            'targetId', v_req.target_id::text
          ));

  -- Уведомление инициатору
  INSERT INTO public.notifications (target_user_id, type, title, body, data) VALUES (
    v_req.requested_by::text,
    'approval_approved',
    'Заявка одобрена',
    'Ваш запрос на ' || v_req.action::text || ' одобрен.',
    jsonb_build_object(
      'approvalId', p_approval_id::text,
      'action', v_req.action::text,
      'targetId', v_req.target_id::text
    )
  );

  RETURN jsonb_build_object('success', true, 'execution', v_result);
END
$$;

-- public-обёртка (sql) сигнатуру не меняла и продолжает указывать на
-- private.approve_request(uuid, text) по имени — пересоздавать её не
-- нужно, но GRANT на private-функцию восстанавливаем после DROP.
GRANT EXECUTE ON FUNCTION private.approve_request(uuid, text) TO authenticated;

-- public.approve_request пересоздаём на всякий случай (DROP private мог
-- инвалидировать зависимость в некоторых версиях PG) и заново грантуем.
CREATE OR REPLACE FUNCTION public.approve_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT private.approve_request(p_approval_id, p_note) $$;

REVOKE EXECUTE ON FUNCTION public.approve_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_request(uuid, text) TO authenticated;

COMMIT;
