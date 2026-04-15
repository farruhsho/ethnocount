/// Supabase configuration constants.
/// Replace with your actual Supabase project URL and anon key.
class SupabaseConfig {
  SupabaseConfig._();

  /// Your Supabase project URL (e.g. https://xxxxx.supabase.co)
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://YOUR_PROJECT.supabase.co',
  );

  /// Your Supabase anon (public) key
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'YOUR_ANON_KEY',
  );
}
