-- ============================================================
-- 023: Per-user grid preferences
-- ============================================================
-- Хранит настройки таблиц для каждого пользователя:
--   * скрытые колонки
--   * ширины колонок
--   * порядок колонок
--   * текущая сортировка
--
-- Синхронизировано между устройствами (RLS: own row only).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_grid_preferences (
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  grid_id    text        NOT NULL,
  hidden     jsonb       NOT NULL DEFAULT '[]'::jsonb,
  widths     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  col_order  jsonb       NOT NULL DEFAULT '[]'::jsonb,
  sort_field text,
  sort_asc   boolean,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, grid_id)
);

ALTER TABLE public.user_grid_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users own grid prefs select" ON public.user_grid_preferences;
CREATE POLICY "users own grid prefs select"
  ON public.user_grid_preferences FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "users own grid prefs upsert" ON public.user_grid_preferences;
CREATE POLICY "users own grid prefs upsert"
  ON public.user_grid_preferences FOR INSERT
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "users own grid prefs update" ON public.user_grid_preferences;
CREATE POLICY "users own grid prefs update"
  ON public.user_grid_preferences FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "users own grid prefs delete" ON public.user_grid_preferences;
CREATE POLICY "users own grid prefs delete"
  ON public.user_grid_preferences FOR DELETE
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.user_grid_preferences TO authenticated;

-- Удобный RPC для upsert одной snapshot'ы прямо из клиента.
CREATE OR REPLACE FUNCTION public.save_grid_preferences(
  p_grid_id    text,
  p_hidden     jsonb,
  p_widths     jsonb,
  p_col_order  jsonb,
  p_sort_field text,
  p_sort_asc   boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  INSERT INTO public.user_grid_preferences
    (user_id, grid_id, hidden, widths, col_order, sort_field, sort_asc, updated_at)
  VALUES (v_uid, p_grid_id, COALESCE(p_hidden, '[]'::jsonb),
          COALESCE(p_widths, '{}'::jsonb),
          COALESCE(p_col_order, '[]'::jsonb), p_sort_field, p_sort_asc, now())
  ON CONFLICT (user_id, grid_id) DO UPDATE SET
    hidden     = EXCLUDED.hidden,
    widths     = EXCLUDED.widths,
    col_order  = EXCLUDED.col_order,
    sort_field = EXCLUDED.sort_field,
    sort_asc   = EXCLUDED.sort_asc,
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_grid_preferences(text, jsonb, jsonb, jsonb, text, boolean) TO authenticated;
