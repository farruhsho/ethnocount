import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final _userDs = sl<UserRemoteDataSource>();
  late final StreamSubscription<List<AppUser>> _sub;
  List<AppUser> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _sub = _userDs.watchUsers().listen((users) {
      if (mounted) {
        setState(() {
          _users = users;
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  /// Director не должен видеть creators и других директоров — даже если RLS на
  /// сервере вдруг пропустит их. Дублируем фильтр на клиенте.
  List<AppUser> _visibleUsers(SystemRole? viewerRole, String? viewerId) {
    if (viewerRole == SystemRole.director) {
      return _users
          .where((u) =>
              u.id == viewerId || u.role == SystemRole.accountant)
          .toList();
    }
    return _users;
  }

  @override
  Widget build(BuildContext context) {
    SystemRole? viewerRole;
    String? viewerId;
    try {
      final authState = context.read<AuthBloc>().state;
      viewerRole = authState.user?.role;
      viewerId = authState.user?.id;
    } catch (_) {}
    final visible = _visibleUsers(viewerRole, viewerId);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Управление пользователями',
                      style: context.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${visible.length} пользователей в системе',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showCreateDialog(context, viewerRole),
                icon: const Icon(Icons.person_add_rounded),
                label: const Text('Добавить пользователя'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Table
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _UsersTable(
                    users: visible,
                    viewerRole: viewerRole,
                    viewerId: viewerId,
                    onEdit: (user) => _showEditDialog(context, user, viewerRole),
                    onDelete: (user) => _confirmDelete(context, user),
                  ),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context, SystemRole? viewerRole) {
    showDialog(
      context: context,
      builder: (_) => _CreateUserDialog(
        viewerRole: viewerRole,
        onCreated: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Пользователь создан'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  void _showEditDialog(
      BuildContext context, AppUser user, SystemRole? viewerRole) {
    showDialog(
      context: context,
      builder: (_) => _EditUserDialog(
        user: user,
        viewerRole: viewerRole,
        onUpdated: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Данные обновлены'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AppUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Expanded(child: Text('Удалить пользователя?')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${user.displayName} (${user.email}) будет удалён без возможности восстановления.',
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Учётная запись и пароль будут стёрты. Войти больше нельзя.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            icon: const Icon(Icons.delete_forever_rounded),
            label: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final result = await sl<UserRemoteDataSource>().deleteUser(user.id);
    // Если пользователь удалил собственный аккаунт, supabase-auth разлогинит
    // сессию, GoRouter уведёт на /login, а текущий элемент `users_page`
    // деактивируется. Любое обращение к контексту тут спровоцирует
    // _ElementLifecycle.inactive (чёрный экран при возврате назад).
    if (!mounted) return;
    if (result['success'] == true) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${user.displayName} удалён'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(result['error']?.toString() ?? 'Ошибка удаления'),
          backgroundColor: errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

// ─── Users Table ───

class _UsersTable extends StatelessWidget {
  const _UsersTable({
    required this.users,
    required this.onEdit,
    required this.onDelete,
    this.viewerRole,
    this.viewerId,
  });
  final List<AppUser> users;
  final ValueChanged<AppUser> onEdit;
  final ValueChanged<AppUser> onDelete;
  final SystemRole? viewerRole;
  final String? viewerId;

  static const _roleColors = {
    SystemRole.creator: Colors.purple,
    SystemRole.director: Colors.orange,
    SystemRole.accountant: Colors.teal,
  };

  bool _canDelete(AppUser user) {
    if (viewerId == null || user.id == viewerId) return false;
    if (user.email.toLowerCase() == 'farruh@gmail.com') return false;
    if (viewerRole == SystemRole.creator) return true;
    if (viewerRole == SystemRole.director) {
      return user.role == SystemRole.accountant;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 20,
          headingRowColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: const [
            DataColumn(label: Text('Имя')),
            DataColumn(label: Text('Email')),
            DataColumn(label: Text('Роль')),
            DataColumn(label: Text('Филиалы')),
            DataColumn(label: Text('Статус')),
            DataColumn(label: Text('Действия')),
          ],
          rows: users.map((user) {
            final roleColor =
                _roleColors[user.role] ?? Colors.grey;
            return DataRow(cells: [
              DataCell(
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor:
                          roleColor.withValues(alpha: 0.1),
                      child: Text(
                        user.displayName.isNotEmpty
                            ? user.displayName[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                            fontSize: 12,
                            color: roleColor,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(user.displayName),
                  ],
                ),
              ),
              DataCell(Text(user.email,
                  style: const TextStyle(fontSize: 13))),
              DataCell(
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: roleColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    user.role.displayName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: roleColor,
                    ),
                  ),
                ),
              ),
              DataCell(Text(
                user.role.isAdminOrCreator
                    ? 'Все филиалы'
                    : '${user.assignedBranchIds.length} филиал(а)',
                style: const TextStyle(fontSize: 13),
              )),
              DataCell(
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: user.isActive
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    user.isActive ? 'Активен' : 'Заблокирован',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: user.isActive ? Colors.green : Colors.red,
                    ),
                  ),
                ),
              ),
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => onEdit(user),
                      tooltip: 'Редактировать',
                    ),
                    if (_canDelete(user))
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        color: Colors.red,
                        onPressed: () => onDelete(user),
                        tooltip: 'Удалить',
                      ),
                  ],
                ),
              ),
            ]);
          }).toList(),
        ),
      ),
    );
  }
}

// ─── Create User Dialog ───

class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog({required this.onCreated, this.viewerRole});
  final VoidCallback onCreated;
  final SystemRole? viewerRole;

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String _role = 'accountant';
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add_rounded),
          SizedBox(width: 8),
          Text('Новый пользователь'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Полное имя *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Введите имя' : null,
              ),
              const SizedBox(height: AppSpacing.formFieldGap),
              TextFormField(
                controller: _emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Email *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Введите email';
                  if (!v.contains('@')) return 'Некорректный email';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.formFieldGap),
              TextFormField(
                controller: _passCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Пароль *',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Введите пароль';
                  if (v.length < 6) return 'Минимум 6 символов';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.formFieldGap),
              DropdownButtonFormField<String>(
                key: ValueKey('create-role-$_role'),
                initialValue: _role,
                decoration: const InputDecoration(
                  labelText: 'Роль *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                ),
                items: [
                  const DropdownMenuItem(
                      value: 'accountant',
                      child: Text('Accountant — Бухгалтер')),
                  // Director / Creator только для creator'а
                  if (widget.viewerRole == SystemRole.creator) ...[
                    const DropdownMenuItem(
                        value: 'director',
                        child: Text('Director — Директор')),
                    const DropdownMenuItem(
                        value: 'creator',
                        child: Text('Creator — Создатель')),
                  ],
                ],
                onChanged: (v) => setState(() => _role = v ?? 'accountant'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.check_rounded),
          label: const Text('Создать'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final ds = sl<UserRemoteDataSource>();
      final result = await ds.createUser(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
        displayName: _nameCtrl.text.trim(),
        role: _role,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.of(context).pop();
        widget.onCreated();
      } else {
        _showError(context, result['error']?.toString() ?? 'Ошибка');
      }
    } catch (e) {
      if (mounted) _showError(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ─── Edit User Dialog ───

class _EditUserDialog extends StatefulWidget {
  const _EditUserDialog({
    required this.user,
    required this.onUpdated,
    this.viewerRole,
  });
  final AppUser user;
  final VoidCallback onUpdated;
  final SystemRole? viewerRole;

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late String _role;
  late bool _isActive;
  late List<String> _assignedBranches;
  late AccountantPermissions _permissions;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _nameCtrl;
  List<Branch> _allBranches = [];
  bool _loading = false;
  bool _permsExpanded = false;
  StreamSubscription<List<Branch>>? _branchSub;

  @override
  void initState() {
    super.initState();
    _role = widget.user.role.name;
    _isActive = widget.user.isActive;
    _assignedBranches = List.from(widget.user.assignedBranchIds);
    _permissions = widget.user.permissions;
    _emailCtrl = TextEditingController(text: widget.user.email);
    _nameCtrl = TextEditingController(text: widget.user.displayName);

    _branchSub = sl<BranchRepository>().watchBranches().listen((branches) {
      if (mounted) setState(() => _allBranches = branches);
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _branchSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPrivileged =
        _role == 'admin' || _role == 'creator' || _role == 'director';

    // Check if current logged-in user can change branches / role
    SystemRole? currentUserRole = widget.viewerRole;
    try {
      final authState = context.read<AuthBloc>().state;
      currentUserRole ??= authState.user?.role;
    } catch (_) {}
    final canEditBranches = currentUserRole?.canChangeBranch ?? false;
    // Только creator может менять роль (повышать/понижать).
    final canEditRole = currentUserRole == SystemRole.creator;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.manage_accounts_rounded),
          const SizedBox(width: 8),
          Expanded(child: Text('Редактировать: ${widget.user.displayName}')),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Имя',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                  helperText: 'Меняется через защищённую серверную функцию',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
              key: ValueKey('edit-role-$_role'),
              initialValue: _role,
              decoration: const InputDecoration(
                labelText: 'Роль',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                    value: 'accountant', child: Text('Accountant — Бухгалтер')),
                DropdownMenuItem(
                    value: 'director', child: Text('Director — Директор')),
                DropdownMenuItem(
                    value: 'creator', child: Text('Creator — Создатель')),
              ],
              onChanged: canEditRole
                  ? (v) => setState(() => _role = v ?? _role)
                  : null,
            ),
            const SizedBox(height: AppSpacing.md),
            SwitchListTile(
              title: const Text('Активный аккаунт'),
              subtitle: Text(_isActive ? 'Пользователь может войти' : 'Доступ заблокирован'),
              value: _isActive,
              onChanged: (v) => setState(() => _isActive = v),
            ),
            if (!isPrivileged) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Text('Назначенные филиалы',
                      style: context.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (!canEditBranches) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'Только Creator может менять филиалы',
                      child: Icon(Icons.lock_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ],
                  const Spacer(),
                  if (canEditBranches)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        if (_assignedBranches.length == _allBranches.length) {
                          _assignedBranches = [];
                        } else {
                          _assignedBranches =
                              _allBranches.map((b) => b.id).toList();
                        }
                      }),
                      icon: Icon(
                        _assignedBranches.length == _allBranches.length
                            ? Icons.deselect_outlined
                            : Icons.select_all_outlined,
                        size: 16,
                      ),
                      label: Text(
                        _assignedBranches.length == _allBranches.length
                            ? 'Снять все'
                            : 'Все филиалы',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ..._allBranches.map((branch) {
                return CheckboxListTile(
                  dense: true,
                  title: Text(branch.name),
                  subtitle: Text(branch.baseCurrency),
                  value: _assignedBranches.contains(branch.id),
                  onChanged: canEditBranches
                      ? (checked) {
                          setState(() {
                            if (checked == true) {
                              _assignedBranches.add(branch.id);
                            } else {
                              _assignedBranches.remove(branch.id);
                            }
                          });
                        }
                      : null,
                );
              }),
              const SizedBox(height: AppSpacing.md),
              _PermissionsMatrix(
                value: _permissions,
                onChanged: canEditBranches
                    ? (p) => setState(() => _permissions = p)
                    : null,
                expanded: _permsExpanded,
                onExpand: () =>
                    setState(() => _permsExpanded = !_permsExpanded),
              ),
            ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.save_rounded),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final ds = sl<UserRemoteDataSource>();
      final roleChanged = _role != widget.user.role.name;
      final emailChanged = _emailCtrl.text.trim().toLowerCase() !=
          widget.user.email.toLowerCase();
      final newName = _nameCtrl.text.trim();
      final nameChanged = newName.isNotEmpty && newName != widget.user.displayName;
      final result = await ds.updateUser(
        userId: widget.user.id,
        role: roleChanged ? _role : null,
        isActive: _isActive,
        assignedBranchIds: _assignedBranches,
        permissions: _permissions != widget.user.permissions ? _permissions : null,
        displayName: nameChanged ? newName : null,
        email: emailChanged ? _emailCtrl.text.trim() : null,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.of(context).pop();
        widget.onUpdated();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error']?.toString() ?? 'Ошибка'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ─── Permissions Matrix ───

class _PermissionGroup {
  const _PermissionGroup(this.title, this.icon, this.items);
  final String title;
  final IconData icon;
  final List<_PermissionItem> items;
}

class _PermissionItem {
  const _PermissionItem({
    required this.label,
    required this.description,
    required this.read,
    required this.write,
    this.soon = false,
  });

  final String label;
  final String description;
  final bool Function(AccountantPermissions) read;
  final AccountantPermissions Function(AccountantPermissions, bool) write;

  /// Флаг сохраняется в БД, но в UI/RLS пока не проверяется.
  /// Чтобы админ не считал, что разграничение действует, рендерим как
  /// disabled + чип «СКОРО».
  final bool soon;
}

class _PermissionsMatrix extends StatelessWidget {
  const _PermissionsMatrix({
    required this.value,
    required this.onChanged,
    required this.expanded,
    required this.onExpand,
  });

  final AccountantPermissions value;
  final ValueChanged<AccountantPermissions>? onChanged;
  final bool expanded;
  final VoidCallback onExpand;

  static final _groups = <_PermissionGroup>[
    _PermissionGroup(
      'Переводы и операции',
      Icons.swap_horiz_rounded,
      [
        _PermissionItem(
          label: 'Видеть переводы',
          description: 'Доступ к экрану переводов',
          read: (p) => p.canTransfers,
          write: (p, v) => p.copyWith(canTransfers: v),
        ),
        _PermissionItem(
          label: 'Создавать / редактировать переводы',
          description: 'Включая суммы и реквизиты',
          read: (p) => p.canManageTransfers,
          write: (p, v) => p.copyWith(canManageTransfers: v),
        ),
        _PermissionItem(
          label: 'Перевод в любой филиал',
          description: 'Иначе — только между назначенными',
          read: (p) => p.canCrossBranchTransfers,
          write: (p, v) => p.copyWith(canCrossBranchTransfers: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Видеть покупки',
          description: 'Экран закупок',
          read: (p) => p.canPurchases,
          write: (p, v) => p.copyWith(canPurchases: v),
        ),
        _PermissionItem(
          label: 'Создавать / редактировать покупки',
          description: 'Включая суммы и поставщиков',
          read: (p) => p.canManagePurchases,
          write: (p, v) => p.copyWith(canManagePurchases: v),
        ),
        _PermissionItem(
          label: 'Пополнение филиала',
          description: 'Топ-апы счетов',
          read: (p) => p.canBranchTopUp,
          write: (p, v) => p.copyWith(canBranchTopUp: v),
        ),
        _PermissionItem(
          label: 'Удаление транзакций',
          description: 'Soft-delete переводов и покупок',
          read: (p) => p.canDeleteTransactions,
          write: (p, v) => p.copyWith(canDeleteTransactions: v),
          soon: true,
        ),
      ],
    ),
    _PermissionGroup(
      'Справочники и аналитика',
      Icons.dashboard_outlined,
      [
        _PermissionItem(
          label: 'Видеть клиентов',
          description: '',
          read: (p) => p.canClients,
          write: (p, v) => p.copyWith(canClients: v),
        ),
        _PermissionItem(
          label: 'Управление клиентами',
          description: 'Создание и редактирование',
          read: (p) => p.canManageClients,
          write: (p, v) => p.copyWith(canManageClients: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Журнал операций',
          description: 'Экран ledger',
          read: (p) => p.canLedger,
          write: (p, v) => p.copyWith(canLedger: v),
        ),
        _PermissionItem(
          label: 'Аналитика',
          description: 'Графики и сводки',
          read: (p) => p.canAnalytics,
          write: (p, v) => p.copyWith(canAnalytics: v),
        ),
        _PermissionItem(
          label: 'Отчёты',
          description: 'Сводные отчёты',
          read: (p) => p.canReports,
          write: (p, v) => p.copyWith(canReports: v),
        ),
        _PermissionItem(
          label: 'Курсы валют',
          description: 'Просмотр курсов',
          read: (p) => p.canExchangeRates,
          write: (p, v) => p.copyWith(canExchangeRates: v),
        ),
        _PermissionItem(
          label: 'Изменение курсов',
          description: 'Ручная установка курсов',
          read: (p) => p.canManageExchangeRates,
          write: (p, v) => p.copyWith(canManageExchangeRates: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Видеть филиалы',
          description: 'Экран филиалов и счетов',
          read: (p) => p.canBranchesView,
          write: (p, v) => p.copyWith(canBranchesView: v),
        ),
      ],
    ),
    _PermissionGroup(
      'Чувствительные данные',
      Icons.lock_outline,
      [
        _PermissionItem(
          label: 'Видеть балансы',
          description: 'Числовые остатки счетов',
          read: (p) => p.canViewBalances,
          write: (p, v) => p.copyWith(canViewBalances: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Полные данные карт',
          description: 'Номер карты, держатель, банк',
          read: (p) => p.canViewCardDetails,
          write: (p, v) => p.copyWith(canViewCardDetails: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Журнал аудита',
          description: 'История действий',
          read: (p) => p.canViewAuditLog,
          write: (p, v) => p.copyWith(canViewAuditLog: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Экспорт данных',
          description: 'CSV / Excel',
          read: (p) => p.canExportData,
          write: (p, v) => p.copyWith(canExportData: v),
          soon: true,
        ),
        _PermissionItem(
          label: 'Уведомления',
          description: 'Экран уведомлений',
          read: (p) => p.canViewNotifications,
          write: (p, v) => p.copyWith(canViewNotifications: v),
          soon: true,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = context.isDark;
    final readOnly = onChanged == null;
    final enabledCount = _groups
        .expand((g) => g.items)
        .where((i) => i.read(value))
        .length;
    final totalCount = _groups.expand((g) => g.items).length;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onExpand,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Матрица разрешений',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        Text(
                          'Включено: $enabledCount из $totalCount',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? AppColors.darkTextSecondary
                                : AppColors.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!readOnly && expanded)
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () =>
                              onChanged?.call(AccountantPermissions.all),
                          child: const Text('Все', style: TextStyle(fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () =>
                              onChanged?.call(AccountantPermissions.none),
                          child: const Text('Минимум',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(
                height: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.2)),
            for (final group in _groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.md, AppSpacing.md, 4),
                child: Row(
                  children: [
                    Icon(group.icon,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      group.title,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final item in group.items)
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: 0),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 13,
                            color: item.soon
                                ? theme.colorScheme.onSurface
                                    .withValues(alpha: 0.55)
                                : null,
                          ),
                        ),
                      ),
                      if (item.soon) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: const Text(
                            'СКОРО',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: item.description.isEmpty && !item.soon
                      ? null
                      : Text(
                          item.soon
                              ? 'Флаг сохраняется, но проверка пока не реализована'
                              : item.description,
                          style: TextStyle(
                            fontSize: 11,
                            color: item.soon
                                ? theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7)
                                : null,
                          ),
                        ),
                  value: item.read(value),
                  onChanged: (readOnly || item.soon)
                      ? null
                      : (v) => onChanged?.call(item.write(value, v)),
                ),
            ],
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}
