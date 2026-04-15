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
    return user == null ? null : _mapUserFallback(user);
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
      return _mapUserFallback(supaUser);
    } catch (_) {
      return _mapUserFallback(supaUser);
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
    final response = await _auth.signUp(
      email: email,
      password: password,
      data: {'display_name': displayName},
    );

    final uid = response.user!.id;
    final role = asCreator ? 'creator' : 'accountant';

    await _client.from('users').insert({
      'id': uid,
      'display_name': displayName,
      'email': email,
      'role': role,
      'assigned_branch_ids': <String>[],
      'is_active': true,
    });

    final systemRole = asCreator ? SystemRole.creator : SystemRole.accountant;

    return AppUser(
      id: uid,
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
    return SystemRole.accountant;
  }

  AppUser _mapUserFallback(User user) {
    return AppUser(
      id: user.id,
      displayName: user.userMetadata?['display_name'] as String? ?? 'User',
      email: user.email ?? '',
      photoUrl: null,
      phone: user.phone,
      role: SystemRole.accountant,
      assignedBranchIds: const [],
      permissions: AccountantPermissions.all,
      isActive: true,
      createdAt: DateTime.tryParse(user.createdAt) ?? DateTime.now(),
    );
  }
}
