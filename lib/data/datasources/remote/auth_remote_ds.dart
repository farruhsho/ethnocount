import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/entities/enums.dart';

class AuthRemoteDataSource {
  final SupabaseClient _client;

  AuthRemoteDataSource(this._client);

  GoTrueClient get _auth => _client.auth;

  Stream<AppUser?> get authStateChanges {
    return _auth.onAuthStateChange.asyncMap((event) async {
      final session = event.session;
      if (session == null) return null;
      return _loadUserProfile(session.user);
    });
  }

  AppUser? get currentUser {
    final user = _auth.currentUser;
    // Синхронный best-effort из JWT (в БД не ходит) — это НЕ ghost-детекция,
    // а «профиль ещё не догружен». Сохраняем permissive-поведение; ghost
    // определяется только в _loadUserProfile по реальному отсутствию строки.
    return user == null ? null : _mapUserFallback(user, ghost: false);
  }

  /// Loads the authoritative profile (including role/permissions/branches)
  /// for the currently signed-in user from the `users` table. Returns null
  /// if there is no active session. Falls back to JWT-derived data only if
  /// the DB read fails.
  Future<AppUser?> fetchCurrentUserProfile() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return _loadUserProfile(user);
  }

  Future<AppUser> _loadUserProfile(User supaUser) async {
    try {
      final data = await _client
          .from('users')
          .select()
          .eq('id', supaUser.id)
          .maybeSingle();
      if (data != null) {
        return AppUser(
          id: supaUser.id,
          displayName: data['display_name'] ?? supaUser.userMetadata?['display_name'] ?? 'User',
          email: data['email'] ?? supaUser.email ?? '',
          photoUrl: data['photo_url'],
          phone: data['phone'] ?? supaUser.phone,
          role: _parseRole(data['role']),
          assignedBranchIds: List<String>.from(data['assigned_branch_ids'] ?? []),
          permissions: AccountantPermissions.fromMap(
            (data['permissions'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
          ),
          isActive: data['is_active'] ?? true,
          createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
        );
      }
      // Строки профиля НЕТ (запрос вернул 0 строк) при живой auth-сессии =
      // «призрак» (удалённый/полуудалённый пользователь) → безправный fallback.
      return _mapUserFallback(supaUser, ghost: true);
    } catch (_) {
      // Исключение (сеть/БД недоступны) — НЕ призрак: удалённый профиль дал бы
      // null выше, а не throw. Легитимного пользователя на транзиентном сбое
      // демотить нельзя → сохраняем прежнее permissive-поведение; настоящего
      // призрака всё равно добьёт сервер (миграция 087).
      return _mapUserFallback(supaUser, ghost: false);
    }
  }

  Future<AppUser> signInWithEmail(String email, String password) async {
    final response = await _auth.signInWithPassword(
      email: email,
      password: password,
    );
    return _loadUserProfile(response.user!);
  }

  Future<bool> isSystemInitialized() async {
    final data = await _client.from('users').select('id').limit(1);
    return (data as List).isNotEmpty;
  }

  Future<AppUser> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
    bool asCreator = false,
  }) async {
    // The public.users profile row is created automatically by the
    // on_auth_user_created trigger (migration 008). We pass display_name
    // and signup_role through user_metadata so the trigger can read them.
    // The trigger also enforces that only the first-ever user may become
    // 'creator'; subsequent signups are clamped to 'accountant'.
    final response = await _auth.signUp(
      email: email,
      password: password,
      data: {
        'display_name': displayName,
        'signup_role': asCreator ? 'creator' : 'accountant',
      },
    );

    final supaUser = response.user!;
    // If a session was returned (confirmation disabled), re-read the trigger-created
    // profile row for the authoritative role. Otherwise fall back to the intended role.
    if (response.session != null) {
      return _loadUserProfile(supaUser);
    }

    final systemRole = asCreator ? SystemRole.creator : SystemRole.accountant;
    return AppUser(
      id: supaUser.id,
      displayName: displayName,
      email: email,
      role: systemRole,
      assignedBranchIds: const [],
      isActive: true,
      createdAt: DateTime.now(),
    );
  }

  Future<void> resetPassword(String email) async {
    await _auth.resetPasswordForEmail(email);
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  Future<void> revokeAllSessions() async {
    // Supabase doesn't have direct session revocation from client.
    // Sign out is the closest equivalent.
    await _auth.signOut(scope: SignOutScope.global);
  }

  SystemRole _parseRole(dynamic role) {
    if (role == 'creator' || role == 'admin') return SystemRole.creator;
    if (role == 'director') return SystemRole.director;
    return SystemRole.accountant;
  }

  /// Fallback-профиль, когда строку public.users не удалось смапить.
  ///
  /// [ghost] = true — строки профиля НЕТ (запрос вернул null) при живой
  /// auth-сессии = удалённый/полуудалённый пользователь. Раньше fallback
  /// всегда давал permissions.all + isActive=true → призрак входил с полными
  /// клиентскими правами. Теперь для ghost — БЕЗПРАВНЫЙ и неактивный (UI
  /// ничего не даёт; сервер добивает миграцией 087).
  ///
  /// [ghost] = false — транзиентный сбой (сеть/БД бросили исключение). Это НЕ
  /// призрак (удалённый профиль даёт null, а не throw); демотить легитимного
  /// пользователя нельзя, поэтому сохраняем прежнее permissive-поведение.
  AppUser _mapUserFallback(User user, {required bool ghost}) {
    return AppUser(
      id: user.id,
      displayName: user.userMetadata?['display_name'] as String? ?? 'User',
      email: user.email ?? '',
      photoUrl: null,
      phone: user.phone,
      role: SystemRole.accountant,
      assignedBranchIds: const [],
      permissions: ghost ? AccountantPermissions.none : AccountantPermissions.all,
      isActive: !ghost,
      createdAt: DateTime.tryParse(user.createdAt) ?? DateTime.now(),
    );
  }
}
