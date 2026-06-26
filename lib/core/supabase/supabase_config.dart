import 'package:flutter/foundation.dart';

/// Supabase configuration.
///
/// Значения берутся из `--dart-define` (в CI/release — из GitHub Secrets
/// `SUPABASE_URL` / `SUPABASE_ANON_KEY`). Раньше реальные URL и anon-ключ
/// стояли как `defaultValue` и ЗАШИВАЛИСЬ в каждый публичный релизный
/// бинарник, из-за чего ключ невозможно было ротировать без пересборки всех
/// платформ. Теперь:
///   • release-сборки берут значения только из --dart-define;
///   • dev-fallback ниже работает ТОЛЬКО в debug (ветка `kDebugMode`
///     вырезается AOT-компилятором), поэтому в release-бинарник не попадает;
///   • если в release значения не заданы — быстрый понятный отказ, а не
///     молчаливый ship ключа.
///
/// ⚠️ Перед следующим релизом задайте секреты `SUPABASE_URL` и
/// `SUPABASE_ANON_KEY` в GitHub (Settings → Secrets and variables → Actions),
/// иначе release-сборка осознанно упадёт с понятной ошибкой.
class SupabaseConfig {
  SupabaseConfig._();

  static const String _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  // Dev-only fallback. Используется лишь в debug-сборках; в release ветка
  // kDebugMode мертва и вырезается, поэтому эти строки не зашиваются в
  // публичные бинарники. После ротации ключа обновите значения здесь для
  // локальной разработки (или перейдите на --dart-define-from-file).
  static const String _devUrl = 'https://cunnaewtyosokfkwyujt.supabase.co';
  static const String _devAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN1bm5hZXd0eW9zb2tma3d5dWp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5MTcwMjUsImV4cCI6MjA5MTQ5MzAyNX0.ovMLJf_ZhTYeONwUTpkQEhX513VkFqHaaPz-qz_KiHk';

  /// Your Supabase project URL.
  static String get url => _envUrl.isNotEmpty
      ? _envUrl
      : (kDebugMode ? _devUrl : _missing('SUPABASE_URL'));

  /// Your Supabase anon (public) key.
  static String get anonKey => _envAnonKey.isNotEmpty
      ? _envAnonKey
      : (kDebugMode ? _devAnonKey : _missing('SUPABASE_ANON_KEY'));

  static String _missing(String name) => throw StateError(
        'Не задан $name. Соберите релиз с '
        '--dart-define=$name=... (в CI — из GitHub Secrets).',
      );
}
