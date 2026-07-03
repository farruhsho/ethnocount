-- ============================================================
-- 087: enforce_accountant_branch — блокировать «призрачную» сессию
-- ============================================================
-- ПРОБЛЕМА (F3-часть, ре-аудит 07.2026): enforce_accountant_branch (067:55)
-- при отсутствии строки в public.users для валидного auth.uid() оставляет
-- v_role = NULL и делает RETURN (без ограничений). Это «призрачная»/
-- «полуудалённая» сессия (профиль удалён, но auth-аккаунт жив): такой
-- пользователь проходит branch-guard насквозь и может двигать client_
-- transactions (и telegram, после 088). Комментарий 067 объяснял NULL как
-- «creator до promote», но триггер регистрации (008) создаёт строку users
-- с role='accountant' по умолчанию → легитимный пользователь ВСЕГДА имеет
-- строку. NULL-роль = именно призрак.
--
-- РЕШЕНИЕ: различать «строки нет» (NOT FOUND → RAISE 42501) и «строка есть,
-- роль не accountant» (creator/director → RETURN без ограничений). Легитимные
-- сервисные вызовы без auth.uid() по-прежнему пропускаются (v_uid IS NULL).
-- Тело 067 воспроизведено 1:1, изменён только блок определения роли.
-- Идемпотентно: CREATE OR REPLACE той же сигнатуры. Re-GRANT.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.enforce_accountant_branch(
  p_branch_id text,
  p_subject   text DEFAULT 'этой записи'
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_role     text;
  v_assigned text[];
BEGIN
  -- Сервисные вызовы без auth (миграции/бэкенд) пропускаем.
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role, assigned_branch_ids
    INTO v_role, v_assigned
  FROM public.users
  WHERE id = v_uid;

  -- 087: строки профиля НЕТ для валидной сессии → «призрак» (удалённый/
  -- рассинхронизированный пользователь). Ранее это трактовалось как пропуск
  -- (NULL → RETURN) — дыра. Теперь блокируем.
  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Профиль пользователя не найден — операция запрещена.';
  END IF;

  -- creator / director — без ограничений по филиалу.
  IF v_role <> 'accountant' THEN RETURN; END IF;

  IF p_branch_id IS NULL
     OR trim(p_branch_id) = ''
     OR v_assigned IS NULL
     OR array_length(v_assigned, 1) IS NULL
     OR NOT (p_branch_id = ANY(v_assigned)) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Нет доступа к ' || p_subject || ' другого филиала. '
            || 'Бухгалтер работает только со своим назначенным филиалом.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.enforce_accountant_branch(text, text) TO authenticated;

COMMIT;
