-- ============================================================
-- 088: Telegram-привязка клиента — branch-guard + аудит
-- ============================================================
-- ПРОБЛЕМА (F11, ре-аудит 07.2026): set_client_telegram_chat_id и
-- send_telegram_test (015) — SECURITY DEFINER с единственным guard
-- `auth.uid() IS NULL`. Любой аутентифицированный (в т.ч. бухгалтер чужого
-- филиала) может перепривязать Telegram ЛЮБОГО клиента (сменить chat_id на
-- свою группу → перехват уведомлений клиента) мимо branch-RLS 068 и без
-- аудита. UPDATE clients не проходит триггер 067 (тот на client_transactions).
--
-- РЕШЕНИЕ: зеркалим модель 067 — вычисляем филиал клиента и зовём
-- private.enforce_accountant_branch (creator/director свободно, accountant
-- только свой филиал; 087 уже блокирует призрачные сессии). Для set_ пишем
-- аудит-запись со сменой chat_id. Денежные пути не трогаем.
-- Идемпотентно: CREATE OR REPLACE, те же сигнатуры. Public-шимы (015) не
-- трогаем — они делегируют в private по имени.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.set_client_telegram_chat_id(
  p_client_id uuid,
  p_chat_id text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch text;
  v_old_chat text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT branch_id, telegram_chat_id INTO v_branch, v_old_chat
    FROM public.clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

  -- 088: бухгалтер может менять telegram только своих клиентов.
  PERFORM private.enforce_accountant_branch(v_branch, 'клиента');

  UPDATE public.clients
     SET telegram_chat_id = NULLIF(trim(p_chat_id), '')
   WHERE id = p_client_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('client.telegram_chat_id_changed', 'client', p_client_id::text, auth.uid(),
          jsonb_build_object(
            'oldChatId', v_old_chat,
            'newChatId', NULLIF(trim(p_chat_id), '')
          ));
END $$;

CREATE OR REPLACE FUNCTION private.send_telegram_test(p_client_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_chat_id text;
  v_name text;
  v_branch text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  SELECT telegram_chat_id, name, branch_id INTO v_chat_id, v_name, v_branch
    FROM public.clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

  -- 088: тест-сообщение только по своим клиентам.
  PERFORM private.enforce_accountant_branch(v_branch, 'клиента');

  IF v_chat_id IS NULL OR v_chat_id = '' THEN
    RAISE EXCEPTION 'У клиента не указан telegram_chat_id';
  END IF;
  PERFORM private.tg_send(
    v_chat_id,
    '✅ <b>Тестовое сообщение</b>' || E'\n' ||
    'Группа клиента «' || private.html_escape(coalesce(v_name, '')) || '» успешно подключена.'
  );
END $$;

COMMIT;
