import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/user.dart';

/// Supabase data source for user management (Creator only).
class UserRemoteDataSource {
  final SupabaseClient _client;

  UserRemoteDataSource(this._client);

  Stream<List<AppUser>> watchUsers() {
    final controller = StreamController<List<AppUser>>.broadcast();

    _fetchUsers().then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((e) {
      if (!controller.isClosed) controller.addError(e);
    });

    final channel = _client
        .channel('users_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'users',
          callback: (payload) {
            _fetchUsers().then((list) {
              if (!controller.isClosed) controller.add(list);
            });
          },
        )
        .subscribe();

    controller.onCancel = () {
      _client.removeChannel(channel);
    };

    return controller.stream;
  }

  Future<List<AppUser>> _fetchUsers() async {
    final data = await _client.from('users').select().order('display_name');
    return (data as List).map((e) => _mapUser(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<AppUser> getUser(String userId) async {
    final data = await _client.from('users').select().eq('id', userId).single();
    return _mapUser(data);
  }

  /// Create user via the `admin-create-user` Edge Function (service_role on server).
  /// This avoids: (a) SMTP rate limit from confirmation emails,
  /// (b) the creator's client session being swapped to the new user,
  /// (c) duplicate insert conflicts with the on_auth_user_created trigger.
  Future<Map<String, dynamic>> createUser({
    required String email,
    required String password,
    required String displayName,
    required String role,
    List<String> assignedBranchIds = const [],
    AccountantPermissions permissions = AccountantPermissions.all,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'admin-create-user',
        body: {
          'email': email.trim().toLowerCase(),
          'password': password,
          'displayName': displayName.trim(),
          'role': role,
          'assignedBranchIds': assignedBranchIds,
          'permissions': permissions.toMap(),
        },
      );

      final data = res.data;
      if (res.status != 200 || data is! Map) {
        final msg = (data is Map && data['error'] != null) ? data['error'].toString() : 'Ошибка создания пользователя';
        return {'success': false, 'error': _friendlyAuthError(msg)};
      }
      if (data['success'] == true) {
        return {'success': true, 'userId': data['userId']};
      }
      return {'success': false, 'error': _friendlyAuthError(data['error']?.toString() ?? 'Ошибка')};
    } on FunctionException catch (e) {
      final detail = e.details?.toString() ?? e.reasonPhrase ?? 'Ошибка функции';
      return {'success': false, 'error': _friendlyAuthError(detail)};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Update user profile.
  Future<Map<String, dynamic>> updateUser({
    required String userId,
    String? role,
    List<String>? assignedBranchIds,
    AccountantPermissions? permissions,
    bool? isActive,
    String? displayName,
  }) async {
    final updates = <String, dynamic>{};
    if (role != null) updates['role'] = role;
    if (assignedBranchIds != null) updates['assigned_branch_ids'] = assignedBranchIds;
    if (permissions != null) updates['permissions'] = permissions.toMap();
    if (isActive != null) updates['is_active'] = isActive;
    if (displayName != null) updates['display_name'] = displayName.trim();

    if (updates.isEmpty) return {'success': true};

    await _client.from('users').update(updates).eq('id', userId);
    return {'success': true};
  }

  /// Delete user profile (auth account would need admin API).
  Future<Map<String, dynamic>> deleteUser(String userId) async {
    await _client.from('users').delete().eq('id', userId);
    return {
      'success': true,
      'note': 'Profile deleted; auth account persists without Admin API',
    };
  }

  String _friendlyAuthError(String raw) {
    if (raw.contains('already registered') || raw.contains('EMAIL_EXISTS')) {
      return 'Пользователь с таким email уже существует';
    }
    if (raw.contains('weak') || raw.contains('WEAK_PASSWORD')) {
      return 'Пароль слишком слабый (мин. 6 символов)';
    }
    if (raw.contains('invalid') || raw.contains('INVALID_EMAIL')) {
      return 'Некорректный email';
    }
    return raw;
  }

  SystemRole _parseRole(dynamic role) {
    if (role == 'creator' || role == 'admin') return SystemRole.creator;
    return SystemRole.accountant;
  }

  AppUser _mapUser(Map<String, dynamic> data) {
    return AppUser(
      id: data['id'] ?? '',
      displayName: data['display_name'] ?? '',
      email: data['email'] ?? '',
      photoUrl: data['photo_url'],
      phone: data['phone'],
      role: _parseRole(data['role']),
      assignedBranchIds: List<String>.from(data['assigned_branch_ids'] ?? []),
      permissions: AccountantPermissions.fromMap(
        (data['permissions'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
      ),
      isActive: data['is_active'] ?? true,
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
