/// Supabase configuration constants.
/// Replace with your actual Supabase project URL and anon key.
class SupabaseConfig {
  SupabaseConfig._();

  /// Your Supabase project URL (e.g. https://xxxxx.supabase.co)
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://cunnaewtyosokfkwyujt.supabase.co',
  );

  /// Your Supabase anon (public) key
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN1bm5hZXd0eW9zb2tma3d5dWp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5MTcwMjUsImV4cCI6MjA5MTQ5MzAyNX0.ovMLJf_ZhTYeONwUTpkQEhX513VkFqHaaPz-qz_KiHk',
  );
}
