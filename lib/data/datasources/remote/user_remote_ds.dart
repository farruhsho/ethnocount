import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/user.dart';

/// Supabase data source for user management (Creator only).
///
/// Write operations are routed through the `public.admin_*` SECURITY DEFINER
/// RPCs introduced in migration 011. Direct `users` table updates are
/// blocked by the `trg_users_guard_self_edit` trigger for any column other
/// than `display_name / phone / photo_url` on own row.
class UserRemoteDataSource {
  final SupabaseClient _client;

  UserRemoteDataSource(this._client);

  /// Singleton-контроллер: один источник правды для всех подписчиков. После
  /// каждой админ-операции мы можем явно вызвать [refreshUsers] и список
  /// мгновенно обновится у всех экранов, не дожидаясь realtime.
  StreamController<List<AppUser>>? _controller;
  RealtimeChannel? _channel;
  int _listeners = 0;

  Stream<List<AppUser>> watchUsers() {
    _controller ??= StreamController<List<AppUser>>.broadcast(
      onListen: () {},
      onCancel: () {},
    );
    _listeners++;

    // Первая загрузка — сразу.
    fetchUsers().then((list) {
      final c = _controller;
      if (c != null && !c.isClosed) c.add(list);
    }).catchError((e) {
      final c = _controller;
      if (c != null && !c.isClosed) c.addError(e);
    });

    // Realtime — подписываемся один раз.
    _channel ??= _client
        .channel('users_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'users',
          callback: (payload) => refreshUsers(),
        )
        .subscribe();

    final base = _controller!.stream;
    // Когда последний слушатель отписался — гасим канал, чтобы не висел
    // realtime-сокет в фоне.
    return base.transform(StreamTransformer<List<AppUser>, List<AppUser>>.fromHandlers(
      handleDone: (sink) {
        _listeners--;
        if (_listeners <= 0) {
          if (_channel != null) {
            _client.removeChannel(_channel!);
            _channel = null;
          }
        }
        sink.close();
      },
    ));
  }

  /// Принудительно перечитать список пользователей и протолкнуть его
  /// в общий стрим. Зовётся после успешных update/delete/email-change,
  /// чтобы UI обновился мгновенно.
  Future<void> refreshUsers() async {
    try {
      final list = await fetchUsers();
      final c = _controller;
      if (c != null && !c.isClosed) c.add(list);
    } catch (_) {/* swallow — следующий тик realtime подтянет */}
  }

  Future<List<AppUser>> fetchUsers() async {
    final data = await _client.from('users').select().order('display_name');
    return (data as List)
        .map((e) => _mapUser(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<AppUser> getUser(String userId) async {
    final data =
        await _client.from('users').select().eq('id', userId).single();
    return _mapUser(data);
  }

  /// Create user via the `admin-create-user` Edge Function.
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
        final msg = (data is Map && data['error'] != null)
            ? data['error'].toString()
            : 'Ошибка создания пользователя';
        return {'success': false, 'error': _friendlyAuthError(msg)};
      }
      if (data['success'] == true) {
        await refreshUsers();
        return {'success': true, 'userId': data['userId']};
      }
      return {
        'success': false,
        'error': _friendlyAuthError(data['error']?.toString() ?? 'Ошибка')
      };
    } on FunctionException catch (e) {
      final detail = e.details?.toString() ?? e.reasonPhrase ?? 'Ошибка функции';
      return {'success': false, 'error': _friendlyAuthError(detail)};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Admin RPC wrappers (creator-only, audited) ─────────────────

  Future<void> setUserBranches(String userId, List<String> branchIds) async {
    await _client.rpc('admin_set_user_branches', params: {
      'p_user_id': userId,
      'p_branch_ids': branchIds,
    });
  }

  Future<void> updateUserPermissions(
      String userId, AccountantPermissions permissions) async {
    await _client.rpc('admin_update_user_permissions', params: {
      'p_user_id': userId,
      'p_permissions': permissions.toMap(),
    });
  }

  Future<void> setUserRole(String userId, String role) async {
    await _client.rpc('admin_set_user_role', params: {
      'p_user_id': userId,
      'p_role': role,
    });
  }

  Future<void> setUserActive(String userId, bool active,
      {String? reason}) async {
    await _client.rpc('admin_set_user_active', params: {
      'p_user_id': userId,
      'p_active': active,
      'p_reason': reason,
    });
  }

  Future<void> updateUserProfile(String userId,
      {String? displayName, String? phone, String? photoUrl}) async {
    await _client.rpc('admin_update_user_profile', params: {
      'p_user_id': userId,
      'p_display_name': displayName,
      'p_phone': phone,
      'p_photo_url': photoUrl,
    });
  }

  /// Меняет email через Edge Function `admin-update-user-email`.
  /// (auth.users менять обычным SQL нельзя — нужен service_role.)
  Future<Map<String, dynamic>> updateUserEmail({
    required String userId,
    required String email,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'admin-update-user-email',
        body: {'userId': userId, 'email': email.trim().toLowerCase()},
      );
      final data = res.data;
      if (res.status != 200 || data is! Map) {
        final msg = (data is Map && data['error'] != null)
            ? data['error'].toString()
            : 'Ошибка смены email';
        return {'success': false, 'error': _friendlyAuthError(msg)};
      }
      if (data['success'] == true) {
        return {'success': true};
      }
      return {
        'success': false,
        'error':
            _friendlyAuthError(data['error']?.toString() ?? 'Ошибка'),
      };
    } on FunctionException catch (e) {
      return {
        'success': false,
        'error': _friendlyAuthError(
            e.details?.toString() ?? e.reasonPhrase ?? 'Ошибка функции'),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Legacy dispatcher — keeps the old call-sites in `admin_panel_page.dart`
  /// working. Internally splits the update into dedicated admin_* RPC calls
  /// (each one writes an audit log row).
  Future<Map<String, dynamic>> updateUser({
    required String userId,
    String? role,
    List<String>? assignedBranchIds,
    AccountantPermissions? permissions,
    bool? isActive,
    String? displayName,
    String? email,
  }) async {
    try {
      if (role != null) {
        await setUserRole(userId, role);
      }
      if (assignedBranchIds != null) {
        await setUserBranches(userId, assignedBranchIds);
      }
      if (permissions != null) {
        await updateUserPermissions(userId, permissions);
      }
      if (isActive != null) {
        await setUserActive(userId, isActive);
      }
      if (displayName != null) {
        await updateUserProfile(userId, displayName: displayName);
      }
      if (email != null) {
        final r = await updateUserEmail(userId: userId, email: email);
        if (r['success'] != true) {
          // ВАЖНО: остальные изменения уже применены — не теряем их.
          // Возвращаем ошибку email отдельно, чтобы UI её показал.
          await refreshUsers();
          return {'success': false, 'error': r['error']};
        }
      }
      // Принудительное обновление списка — UI увидит изменения мгновенно.
      await refreshUsers();
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Delete user (profile + auth account) via the `admin-delete-user` Edge Function.
  ///
  /// Caller must be creator (any target) or director (accountant target only) —
  /// enforced server-side. The Edge Function uses the service_role key to call
  /// `auth.admin.deleteUser`, then removes the public.users row.
  Future<Map<String, dynamic>> deleteUser(String userId) async {
    try {
      final res = await _client.functions.invoke(
        'admin-delete-user',
        body: {'userId': userId},
      );
      final data = res.data;
      if (res.status != 200 || data is! Map) {
        final msg = (data is Map && data['error'] != null)
            ? data['error'].toString()
            : 'Ошибка удаления пользователя';
        return {'success': false, 'error': msg};
      }
      if (data['success'] == true) {
        await refreshUsers();
        return {'success': true};
      }
      return {
        'success': false,
        'error': data['error']?.toString() ?? 'Ошибка',
      };
    } on FunctionException catch (e) {
      return {
        'success': false,
        'error': e.details?.toString() ?? e.reasonPhrase ?? 'Ошибка функции',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
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
    if (role == 'director') return SystemRole.director;
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
