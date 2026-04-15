import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});

  @override
  State<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends State<AdminPanelPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final _userDs = sl<UserRemoteDataSource>();
  final _branchRepo = sl<BranchRepository>();

  late final StreamSubscription<List<AppUser>> _userSub;
  late final StreamSubscription<List<Branch>> _branchSub;

  List<AppUser> _users = [];
  List<Branch> _branches = [];
  bool _loadingUsers = true;
  bool _loadingBranches = true;

  String _userSearch = '';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);

    _userSub = _userDs.watchUsers().listen((users) {
      if (mounted) setState(() { _users = users; _loadingUsers = false; });
    });
    _branchSub = _branchRepo.watchBranches().listen((branches) {
      if (mounted) setState(() { _branches = branches; _loadingBranches = false; });
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _userSub.cancel();
    _branchSub.cancel();
    super.dispose();
  }

  AppUser? get _currentUser {
    try { return context.read<AuthBloc>().state.user; } catch (_) { return null; }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final cs = context.colorScheme;

    return Scaffold(
      body: Column(
        children: [
          // ─── Header ───
          Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xxl, AppSpacing.lg, AppSpacing.xxl, 0,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              border: Border(
                bottom: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      ),
                      child: const Icon(Icons.admin_panel_settings,
                          color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Панель управления',
                            style: context.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            'Creator: ${_currentUser?.displayName ?? "—"} • '
                            '${_users.length} сотрудников • ${_branches.length} филиалов',
                            style: context.textTheme.bodySmall?.copyWith(
                              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _QuickActionButton(
                      icon: Icons.person_add_rounded,
                      label: 'Сотрудник',
                      color: AppColors.secondary,
                      onTap: () => _showCreateUserDialog(context),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _QuickActionButton(
                      icon: Icons.add_business_rounded,
                      label: 'Филиал',
                      color: AppColors.primary,
                      onTap: () => _showCreateBranchDialog(context),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                TabBar(
                  controller: _tabCtrl,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  tabs: [
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dashboard_outlined, size: 18, color: cs.primary),
                          const SizedBox(width: 6),
                          const Text('Обзор системы'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.people_outline, size: 18),
                          const SizedBox(width: 6),
                          Text('Сотрудники (${_users.length})'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.business_outlined, size: 18),
                          const SizedBox(width: 6),
                          Text('Филиалы (${_branches.length})'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.security_outlined, size: 18),
                          const SizedBox(width: 6),
                          const Text('Матрица доступов'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // ─── Body ───
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _OverviewTab(
                  users: _users,
                  branches: _branches,
                  loading: _loadingUsers || _loadingBranches,
                  onBranchTap: (branch) => _showAssignAccountantsDialog(context, branch),
                ),
                _UsersTab(
                  users: _users,
                  branches: _branches,
                  loading: _loadingUsers,
                  search: _userSearch,
                  onSearchChanged: (v) => setState(() => _userSearch = v),
                  onEdit: (u) => _showEditUserDialog(context, u),
                  onCreate: () => _showCreateUserDialog(context),
                ),
                _BranchesTab(
                  branches: _branches,
                  users: _users,
                  loading: _loadingBranches,
                  onAssignAccountants: (branch) => _showAssignAccountantsDialog(context, branch),
                  onEditBranch: (branch) => _showEditBranchDialog(context, branch),
                ),
                _AccessMatrixTab(users: _users, branches: _branches, loading: _loadingUsers || _loadingBranches),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Dialogs ───

  void _showCreateUserDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateUserDialog(
        branches: _branches,
        onCreated: () {
          if (mounted) context.showSuccessSnackBar('Сотрудник создан');
        },
      ),
    );
  }

  void _showEditUserDialog(BuildContext context, AppUser user) {
    showDialog(
      context: context,
      builder: (_) => _EditUserDialog(
        user: user,
        branches: _branches,
        onUpdated: () {
          if (mounted) context.showSuccessSnackBar('Данные обновлены');
        },
      ),
    );
  }

  void _showEditBranchDialog(BuildContext context, Branch branch) {
    showDialog(
      context: context,
      builder: (_) => _EditBranchDialog(
        branch: branch,
        onUpdated: () {
          if (mounted) context.showSuccessSnackBar('Филиал обновлён');
        },
      ),
    );
  }

  void _showAssignAccountantsDialog(BuildContext context, Branch branch) {
    showDialog(
      context: context,
      builder: (_) => _AssignAccountantsDialog(
        branch: branch,
        users: _users,
        onUpdated: () {
          if (mounted) context.showSuccessSnackBar('Доступы обновлены');
        },
      ),
    );
  }

  void _showCreateBranchDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateBranchDialog(
        onCreated: () {
          if (mounted) context.showSuccessSnackBar('Филиал создан');
        },
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TAB 1: System Overview
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.users,
    required this.branches,
    required this.loading,
    this.onBranchTap,
  });
  final List<AppUser> users;
  final List<Branch> branches;
  final bool loading;
  final ValueChanged<Branch>? onBranchTap;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    final creators = users.where((u) => u.role == SystemRole.creator).length;
    final accountants = users.where((u) => u.role == SystemRole.accountant).length;
    final activeUsers = users.where((u) => u.isActive).length;
    final blockedUsers = users.where((u) => !u.isActive).length;
    final activeBranches = branches.where((b) => b.isActive).length;

    final isDark = context.isDark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // KPI Row
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.lg,
            children: [
              _KpiCard(
                title: 'Всего сотрудников',
                value: '${users.length}',
                icon: Icons.people_rounded,
                color: AppColors.secondary,
                subtitle: '$activeUsers активных',
              ),
              _KpiCard(
                title: 'Creators',
                value: '$creators',
                icon: Icons.shield_rounded,
                color: Colors.purple,
                subtitle: 'Полные права',
              ),
              _KpiCard(
                title: 'Бухгалтеры',
                value: '$accountants',
                icon: Icons.calculate_rounded,
                color: AppColors.primary,
                subtitle: 'Ограниченный доступ',
              ),
              _KpiCard(
                title: 'Филиалы',
                value: '$activeBranches',
                icon: Icons.business_rounded,
                color: AppColors.warning,
                subtitle: '${branches.length} всего',
              ),
              if (blockedUsers > 0)
                _KpiCard(
                  title: 'Заблокированы',
                  value: '$blockedUsers',
                  icon: Icons.block_rounded,
                  color: AppColors.error,
                  subtitle: 'Нет доступа',
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxxl),

          // Recent Users
          Text('Последние добавленные сотрудники',
            style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.md),
          ...users.take(5).map((user) {
            final roleColor = user.role == SystemRole.creator ? Colors.purple : AppColors.primary;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                side: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: roleColor.withValues(alpha: 0.1),
                  child: Text(
                    user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '?',
                    style: TextStyle(color: roleColor, fontWeight: FontWeight.w700),
                  ),
                ),
                title: Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(user.email),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RoleBadge(role: user.role),
                    const SizedBox(width: 8),
                    _StatusDot(isActive: user.isActive),
                  ],
                ),
              ),
            );
          }),

          const SizedBox(height: AppSpacing.xxxl),

          // Branches overview
          Text('Филиалы',
            style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: branches.map((branch) {
              final assignedCount = users.where(
                (u) => u.role == SystemRole.accountant && u.assignedBranchIds.contains(branch.id),
              ).length;
              return _BranchChip(
                branch: branch,
                assignedCount: assignedCount,
                onTap: onBranchTap != null ? () => onBranchTap!(branch) : null,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TAB 2: Users Management
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _UsersTab extends StatelessWidget {
  const _UsersTab({
    required this.users,
    required this.branches,
    required this.loading,
    required this.search,
    required this.onSearchChanged,
    required this.onEdit,
    required this.onCreate,
  });

  final List<AppUser> users;
  final List<Branch> branches;
  final bool loading;
  final String search;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<AppUser> onEdit;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    final isDark = context.isDark;
    final filtered = search.isEmpty
        ? users
        : users.where((u) {
            final q = search.toLowerCase();
            return u.displayName.toLowerCase().contains(q) ||
                u.email.toLowerCase().contains(q);
          }).toList();

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        children: [
          // Toolbar
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Поиск по имени или email...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: const Text('Добавить'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Table
          Expanded(
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                side: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  // Table header
                  Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: const [
                        SizedBox(width: 44),
                        Expanded(flex: 3, child: Text('Имя', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                        Expanded(flex: 3, child: Text('Email', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                        Expanded(flex: 2, child: Text('Роль', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                        Expanded(flex: 2, child: Text('Филиалы', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                        Expanded(flex: 1, child: Text('Статус', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                        SizedBox(width: 48),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final user = filtered[i];
                        return _UserRow(
                          user: user,
                          branches: branches,
                          onEdit: () => onEdit(user),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.user, required this.branches, required this.onEdit});
  final AppUser user;
  final List<Branch> branches;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final roleColor = user.role == SystemRole.creator ? Colors.purple : AppColors.primary;
    final branchNames = user.role.isAdminOrCreator
        ? 'Все филиалы'
        : user.assignedBranchIds
            .map((id) => branches.firstWhere((b) => b.id == id, orElse: () => Branch(id: id, name: id, code: '?', baseCurrency: '', createdAt: DateTime.now())).name)
            .join(', ');

    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: roleColor.withValues(alpha: 0.1),
              child: Text(
                user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '?',
                style: TextStyle(color: roleColor, fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(user.email, style: TextStyle(fontSize: 13, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
            ),
            Expanded(flex: 2, child: _RoleBadge(role: user.role)),
            Expanded(
              flex: 2,
              child: Text(
                branchNames.isEmpty ? '—' : branchNames,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            Expanded(flex: 1, child: _StatusDot(isActive: user.isActive)),
            SizedBox(
              width: 48,
              child: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: onEdit,
                tooltip: 'Редактировать',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TAB 3: Branches Management
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _BranchesTab extends StatefulWidget {
  const _BranchesTab({
    required this.branches,
    required this.users,
    required this.loading,
    this.onAssignAccountants,
    this.onEditBranch,
  });
  final List<Branch> branches;
  final List<AppUser> users;
  final bool loading;
  final ValueChanged<Branch>? onAssignAccountants;
  final ValueChanged<Branch>? onEditBranch;

  @override
  State<_BranchesTab> createState() => _BranchesTabState();
}

class _BranchesTabState extends State<_BranchesTab> {
  String? _selectedBranchId;
  List<BranchAccount> _accounts = [];
  Map<String, double> _balances = {};
  StreamSubscription<List<BranchAccount>>? _accSub;
  StreamSubscription<Map<String, double>>? _balSub;

  void _selectBranch(Branch branch) {
    setState(() => _selectedBranchId = branch.id);
    _accSub?.cancel();
    _balSub?.cancel();
    _accSub = sl<BranchRepository>().watchBranchAccounts(branch.id).listen((accs) {
      if (mounted) setState(() => _accounts = accs);
    });
    _balSub = sl<LedgerRemoteDataSource>().watchBranchBalances(branch.id).listen((bals) {
      if (mounted) setState(() => _balances = bals);
    });
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _balSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) return const Center(child: CircularProgressIndicator());

    final isDark = context.isDark;
    final selected = _selectedBranchId != null
        ? widget.branches.where((b) => b.id == _selectedBranchId).firstOrNull
        : null;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Branch list
          SizedBox(
            width: 300,
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Row(
                      children: [
                        const Icon(Icons.business_rounded, size: 18),
                        const SizedBox(width: 8),
                        Text('Филиалы (${widget.branches.length})',
                          style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.add_rounded, size: 20),
                          onPressed: () => _showCreateBranch(context),
                          tooltip: 'Добавить филиал',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemCount: widget.branches.length,
                      itemBuilder: (context, i) {
                        final branch = widget.branches[i];
                        final isSelected = branch.id == _selectedBranchId;
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: AppColors.primary.withValues(alpha: 0.08),
                          leading: Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.primary : AppColors.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                branch.code.substring(0, branch.code.length.clamp(0, 2)),
                                style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w700,
                                  color: isSelected ? Colors.white : AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                          title: Text(branch.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          subtitle: Text(branch.baseCurrency, style: const TextStyle(fontSize: 12)),
                          trailing: Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                              color: branch.isActive ? Colors.green : Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          onTap: () => _selectBranch(branch),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          // Detail
          Expanded(
            child: selected != null
                ? _BranchDetailCard(
                    branch: selected,
                    accounts: _accounts,
                    balances: _balances,
                    onAssignAccountants: widget.onAssignAccountants,
                    onEditBranch: widget.onEditBranch,
                  )
                : Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.touch_app_rounded, size: 48,
                            color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary),
                          const SizedBox(height: 12),
                          Text('Выберите филиал из списка',
                            style: TextStyle(color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _showCreateBranch(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateBranchDialog(
        onCreated: () {
          if (mounted) context.showSuccessSnackBar('Филиал создан');
        },
      ),
    );
  }
}

class _BranchDetailCard extends StatelessWidget {
  const _BranchDetailCard({
    required this.branch,
    required this.accounts,
    required this.balances,
    this.onAssignAccountants,
    this.onEditBranch,
  });
  final Branch branch;
  final List<BranchAccount> accounts;
  final Map<String, double> balances;
  final ValueChanged<Branch>? onAssignAccountants;
  final ValueChanged<Branch>? onEditBranch;

  Map<String, double> get _balancesByCurrency =>
      balanceByCurrency(accounts, balances);

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      branch.code.substring(0, branch.code.length.clamp(0, 3)),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      branch.name,
                      style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _InfoChip(label: 'Валюта: ${branch.baseCurrency}', icon: Icons.currency_exchange_rounded),
                        _InfoChip(label: '${accounts.length} счетов', icon: Icons.account_balance_rounded),
                      ],
                    ),
                  ],
                ),
                // Balance by currency
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: (_balancesByCurrency.values.fold(0.0, (a, b) => a + b) >= 0)
                        ? AppColors.primary.withValues(alpha: 0.08)
                        : AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(
                      color: (_balancesByCurrency.values.fold(0.0, (a, b) => a + b) >= 0)
                          ? AppColors.primary.withValues(alpha: 0.3)
                          : AppColors.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Баланс по валютам',
                        style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          CurrencyUtils.formatBalanceBreakdown(_balancesByCurrency),
                          style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800,
                            color: (_balancesByCurrency.values.fold(0.0, (a, b) => a + b) >= 0) ? AppColors.primary : AppColors.error,
                          ),
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onEditBranch != null)
                  OutlinedButton.icon(
                    onPressed: () => onEditBranch!(branch),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Изменить'),
                  ),
                if (onAssignAccountants != null)
                  OutlinedButton.icon(
                    onPressed: () => onAssignAccountants!(branch),
                    icon: const Icon(Icons.manage_accounts_rounded, size: 18),
                    label: const Text('Доступ бухгалтерам'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _showAddAccountDialog(context, branch),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Добавить счёт'),
                ),
              ],
            ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Divider(),
            const SizedBox(height: AppSpacing.md),
            Text('Счета', style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: accounts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.account_balance_wallet_outlined, size: 40,
                            color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary),
                          const SizedBox(height: 8),
                          const Text('Нет счетов. Добавьте первый счёт.'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: accounts.length,
                      itemBuilder: (context, i) {
                        final acc = accounts[i];
                        final balance = balances[acc.id] ?? 0.0;
                        return _AccountTile(
                          account: acc,
                          balance: balance,
                          onAdjust: () => _showAdjustDialog(context, branch, acc, balance),
                          onEdit: () => _showEditAccountDialog(context, branch, acc),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddAccountDialog(BuildContext context, Branch branch) {
    showDialog(
      context: context,
      builder: (_) => _AddAccountDialog(
        branch: branch,
        onCreated: () {
          if (context.mounted) context.showSuccessSnackBar('Счёт добавлен');
        },
      ),
    );
  }

  void _showAdjustDialog(BuildContext context, Branch branch, BranchAccount account, double currentBalance) {
    showDialog(
      context: context,
      builder: (_) => _AdjustBalanceDialog(
        branch: branch,
        account: account,
        currentBalance: currentBalance,
        onDone: () {
          if (context.mounted) context.showSuccessSnackBar('Баланс обновлён');
        },
      ),
    );
  }

  void _showEditAccountDialog(BuildContext context, Branch branch, BranchAccount account) {
    showDialog(
      context: context,
      builder: (_) => _EditAccountDialog(
        account: account,
        branch: branch,
        onUpdated: () {
          if (context.mounted) context.showSuccessSnackBar('Счёт обновлён');
        },
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.balance,
    required this.onAdjust,
    this.onEdit,
  });
  final BranchAccount account;
  final double balance;
  final VoidCallback onAdjust;
  final VoidCallback? onEdit;

  static const _typeColors = {
    AccountType.cash: Colors.green,
    AccountType.card: Colors.blue,
    AccountType.reserve: Colors.orange,
    AccountType.transit: Colors.purple,
  };

  @override
  Widget build(BuildContext context) {
    final color = _typeColors[account.type] ?? Colors.grey;
    final balColor = balance > 0 ? AppColors.primary : (balance < 0 ? AppColors.error : null);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        side: BorderSide(color: color.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(account.type.icon, style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(account.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  Text('${account.type.displayName} • ${account.currency}',
                    style: TextStyle(fontSize: 11, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                ],
              ),
            ),
            // Balance display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: (balColor ?? Colors.grey).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${balance.toStringAsFixed(2)} ${account.currency}',
                style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700,
                  color: balColor ?? (context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (onEdit != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Изменить название счёта (Creator)',
                onPressed: onEdit,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.secondary.withValues(alpha: 0.08),
                  foregroundColor: AppColors.secondary,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.tune_rounded, size: 20),
              tooltip: 'Корректировка баланса',
              onPressed: onAdjust,
              style: IconButton.styleFrom(
                backgroundColor: AppColors.secondary.withValues(alpha: 0.08),
                foregroundColor: AppColors.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TAB 4: Access Matrix
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _AccessMatrixTab extends StatelessWidget {
  const _AccessMatrixTab({required this.users, required this.branches, required this.loading});
  final List<AppUser> users;
  final List<Branch> branches;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    final isDark = context.isDark;
    final accountants = users.where((u) => u.role == SystemRole.accountant).toList();

    if (branches.isEmpty || accountants.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_rounded, size: 48,
              color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary),
            const SizedBox(height: 12),
            Text(
              branches.isEmpty
                  ? 'Создайте филиалы для управления доступами'
                  : 'Добавьте бухгалтеров для управления доступами',
              style: TextStyle(color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.grid_view_rounded, size: 20),
              const SizedBox(width: 8),
              Text('Матрица доступов', style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text(
                'Creators имеют доступ ко всем филиалам',
                style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowColor: WidgetStateProperty.all(
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    columns: [
                      const DataColumn(label: Text('Сотрудник', style: TextStyle(fontWeight: FontWeight.w700))),
                      const DataColumn(label: Text('Роль', style: TextStyle(fontWeight: FontWeight.w700))),
                      ...branches.map((b) => DataColumn(
                        label: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(b.code, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11)),
                            Text(b.baseCurrency, style: const TextStyle(fontSize: 9)),
                          ],
                        ),
                      )),
                    ],
                    rows: accountants.map((user) {
                      return DataRow(cells: [
                        DataCell(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                              child: Text(user.displayName.isNotEmpty ? user.displayName[0] : '?',
                                style: TextStyle(fontSize: 10, color: AppColors.primary, fontWeight: FontWeight.w700)),
                            ),
                            const SizedBox(width: 8),
                            Text(user.displayName, style: const TextStyle(fontSize: 13)),
                          ],
                        )),
                        DataCell(_RoleBadge(role: user.role)),
                        ...branches.map((branch) {
                          final hasAccess = user.assignedBranchIds.contains(branch.id);
                          return DataCell(
                            _AccessToggle(
                              hasAccess: hasAccess,
                              onToggle: () => _toggleAccess(context, user, branch, !hasAccess),
                            ),
                          );
                        }),
                      ]);
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleAccess(BuildContext ctx, AppUser user, Branch branch, bool grant) async {
    final ds = sl<UserRemoteDataSource>();
    final newBranches = List<String>.from(user.assignedBranchIds);
    if (grant) {
      if (!newBranches.contains(branch.id)) newBranches.add(branch.id);
    } else {
      newBranches.remove(branch.id);
    }
    final result = await ds.updateUser(
      userId: user.id,
      assignedBranchIds: newBranches,
    );
    if (ctx.mounted) {
      if (result['success'] == true) {
        ctx.showSuccessSnackBar(
          grant ? '${user.displayName} → ${branch.name}: доступ выдан' : '${user.displayName} → ${branch.name}: доступ убран',
        );
      } else {
        ctx.showSnackBar(result['error']?.toString() ?? 'Ошибка', isError: true);
      }
    }
  }
}

class _AccessToggle extends StatelessWidget {
  const _AccessToggle({required this.hasAccess, required this.onToggle});
  final bool hasAccess;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: hasAccess ? AppColors.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasAccess ? AppColors.primary : Colors.grey.withValues(alpha: 0.3),
            width: 1.5,
          ),
        ),
        child: hasAccess
            ? const Icon(Icons.check_rounded, color: AppColors.primary, size: 20)
            : Icon(Icons.close_rounded, color: Colors.grey.withValues(alpha: 0.4), size: 16),
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Shared Widgets
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.title, required this.value, required this.icon, required this.color, required this.subtitle});
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      width: 200,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const Spacer(),
              Text(value, style: context.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: color)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(title, style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          Text(subtitle, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary)),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});
  final SystemRole role;

  @override
  Widget build(BuildContext context) {
    final color = role == SystemRole.creator ? Colors.purple : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        role.displayNameRu,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.isActive});
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: isActive ? Colors.green : Colors.red, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          isActive ? 'Активен' : 'Заблокирован',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isActive ? Colors.green : Colors.red),
        ),
      ],
    );
  }
}

class _BranchChip extends StatelessWidget {
  const _BranchChip({
    required this.branch,
    required this.assignedCount,
    this.onTap,
  });
  final Branch branch;
  final int assignedCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final content = Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                branch.code.substring(0, branch.code.length.clamp(0, 2)),
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(branch.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              Text('${branch.baseCurrency} • $assignedCount бухгалтер(ов)',
                style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: content,
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCardHover,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
        ],
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Dialogs
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _AssignAccountantsDialog extends StatefulWidget {
  const _AssignAccountantsDialog({
    required this.branch,
    required this.users,
    required this.onUpdated,
  });
  final Branch branch;
  final List<AppUser> users;
  final VoidCallback onUpdated;

  @override
  State<_AssignAccountantsDialog> createState() => _AssignAccountantsDialogState();
}

class _AssignAccountantsDialogState extends State<_AssignAccountantsDialog> {
  late final Map<String, bool> _localAccess;

  @override
  void initState() {
    super.initState();
    _localAccess = {
      for (final u in widget.users.where((u) => u.role == SystemRole.accountant))
        u.id: u.assignedBranchIds.contains(widget.branch.id),
    };
  }

  Future<void> _toggleAccess(AppUser user, bool grant) async {
    setState(() => _localAccess[user.id] = grant);
    final newBranches = List<String>.from(user.assignedBranchIds);
    if (grant) {
      if (!newBranches.contains(widget.branch.id)) newBranches.add(widget.branch.id);
    } else {
      newBranches.remove(widget.branch.id);
    }
    final result = await sl<UserRemoteDataSource>().updateUser(
      userId: user.id,
      assignedBranchIds: newBranches,
    );
    if (mounted) {
      if (result['success'] == true) {
        context.showSuccessSnackBar(
          grant ? '${user.displayName}: доступ к ${widget.branch.name}' : '${user.displayName}: доступ убран',
        );
        widget.onUpdated();
      } else {
        setState(() => _localAccess[user.id] = !grant);
        context.showSnackBar(result['error']?.toString() ?? 'Ошибка', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountants = widget.users.where((u) => u.role == SystemRole.accountant).toList();
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.manage_accounts_rounded, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Доступ к филиалу'),
                Text(widget.branch.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: accountants.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  'Нет бухгалтеров. Добавьте сотрудников с ролью «Бухгалтер» во вкладке «Сотрудники».',
                  style: TextStyle(color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              )
            : ListView.separated(
                    shrinkWrap: true,
                    itemCount: accountants.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final user = accountants[i];
                      final hasAccess = _localAccess[user.id] ?? user.assignedBranchIds.contains(widget.branch.id);
                      return CheckboxListTile(
                        dense: true,
                        title: Text(user.displayName, style: const TextStyle(fontSize: 14)),
                        subtitle: Text(user.email, style: TextStyle(fontSize: 11, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                        value: hasAccess,
                        onChanged: (v) => _toggleAccess(user, v ?? false),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog({required this.branches, required this.onCreated});
  final List<Branch> branches;
  final VoidCallback onCreated;

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String _role = 'accountant';
  final Set<String> _selectedBranches = {};
  AccountantPermissions _permissions = AccountantPermissions.all;
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
    final isCreatorRole = _role == 'creator';

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add_rounded, color: AppColors.secondary),
          SizedBox(width: 10),
          Text('Новый сотрудник'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Полное имя *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите имя' : null,
                ),
                const SizedBox(height: AppSpacing.md),
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
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _passCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Пароль *',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Введите пароль';
                    if (v.length < 6) return 'Минимум 6 символов';
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  key: ValueKey('role-$_role'),
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'Роль *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'accountant', child: Text('Бухгалтер (Accountant)')),
                    DropdownMenuItem(value: 'creator', child: Text('Создатель (Creator)')),
                  ],
                  onChanged: (v) => setState(() => _role = v ?? 'accountant'),
                ),

                if (!isCreatorRole && widget.branches.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text('Доступ к филиалам',
                    style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Выберите филиалы, к которым будет иметь доступ бухгалтер',
                    style: TextStyle(fontSize: 12, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                  const SizedBox(height: AppSpacing.sm),
                  ...widget.branches.map((branch) {
                    return CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(branch.name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(branch.baseCurrency, style: const TextStyle(fontSize: 11)),
                      value: _selectedBranches.contains(branch.id),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedBranches.add(branch.id);
                          } else {
                            _selectedBranches.remove(branch.id);
                          }
                        });
                      },
                    );
                  }),
                ],

                if (!isCreatorRole) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text('Чем может заниматься бухгалтер',
                    style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Включите только те разделы, к которым нужен доступ',
                    style: TextStyle(fontSize: 12, color: context.isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                  const SizedBox(height: AppSpacing.sm),
                  ..._permissionCheckboxes(context),
                ],

                if (isCreatorRole) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Colors.purple.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                      border: Border.all(color: Colors.purple.withValues(alpha: 0.2)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: Colors.purple),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Creator получит полный доступ ко всем филиалам и операциям',
                            style: TextStyle(fontSize: 12, color: Colors.purple),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
        assignedBranchIds: _selectedBranches.toList(),
        permissions: _permissions,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.of(context).pop();
        widget.onCreated();
      } else {
        _showError(result['error']?.toString() ?? 'Ошибка');
      }
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
    );
  }

  List<Widget> _permissionCheckboxes(BuildContext context) {
    return [
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Переводы', style: TextStyle(fontSize: 14)), value: _permissions.canTransfers, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canTransfers: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Управление переводами', style: TextStyle(fontSize: 14)), value: _permissions.canManageTransfers, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canManageTransfers: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Пополнение филиала', style: TextStyle(fontSize: 14)), value: _permissions.canBranchTopUp, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canBranchTopUp: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Покупки', style: TextStyle(fontSize: 14)), value: _permissions.canPurchases, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canPurchases: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Управление покупками', style: TextStyle(fontSize: 14)), value: _permissions.canManagePurchases, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canManagePurchases: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Клиенты', style: TextStyle(fontSize: 14)), value: _permissions.canClients, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canClients: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Журнал операций', style: TextStyle(fontSize: 14)), value: _permissions.canLedger, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canLedger: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Аналитика', style: TextStyle(fontSize: 14)), value: _permissions.canAnalytics, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canAnalytics: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Отчёты', style: TextStyle(fontSize: 14)), value: _permissions.canReports, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canReports: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Курсы валют', style: TextStyle(fontSize: 14)), value: _permissions.canExchangeRates, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canExchangeRates: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Просмотр филиалов', style: TextStyle(fontSize: 14)), value: _permissions.canBranchesView, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canBranchesView: v ?? true))),
    ];
  }
}

// ─── Edit User Dialog ───

class _EditUserDialog extends StatefulWidget {
  const _EditUserDialog({required this.user, required this.branches, required this.onUpdated});
  final AppUser user;
  final List<Branch> branches;
  final VoidCallback onUpdated;

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late String _role;
  late bool _isActive;
  late Set<String> _assignedBranches;
  late AccountantPermissions _permissions;
  late final TextEditingController _nameCtrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _role = widget.user.role.name;
    _isActive = widget.user.isActive;
    _assignedBranches = Set.from(widget.user.assignedBranchIds);
    _permissions = widget.user.permissions;
    _nameCtrl = TextEditingController(text: widget.user.displayName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPrivileged = _role == 'admin' || _role == 'creator';

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.manage_accounts_rounded),
          const SizedBox(width: 10),
          Expanded(child: Text('Редактировать: ${widget.user.displayName}', overflow: TextOverflow.ellipsis)),
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
                  labelText: 'Полное имя',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // Email (read-only)
              TextFormField(
                initialValue: widget.user.email,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              DropdownButtonFormField<String>(
                key: ValueKey('edit-role-$_role'),
                initialValue: _role,
                decoration: const InputDecoration(
                  labelText: 'Роль',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                ),
                items: const [
                  DropdownMenuItem(value: 'accountant', child: Text('Бухгалтер (Accountant)')),
                  DropdownMenuItem(value: 'creator', child: Text('Создатель (Creator)')),
                ],
                onChanged: (v) => setState(() => _role = v ?? _role),
              ),
              const SizedBox(height: AppSpacing.md),

              // Active switch
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(color: context.isDark ? AppColors.darkBorder : AppColors.lightBorder),
                ),
                child: SwitchListTile(
                  title: const Text('Активный аккаунт', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    _isActive ? 'Сотрудник может входить в систему' : 'Доступ заблокирован',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
              ),

              if (!isPrivileged && widget.branches.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Text('Доступ к филиалам',
                  style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                ...widget.branches.map((branch) {
                  return CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(branch.name, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(branch.baseCurrency, style: const TextStyle(fontSize: 11)),
                    value: _assignedBranches.contains(branch.id),
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          _assignedBranches.add(branch.id);
                        } else {
                          _assignedBranches.remove(branch.id);
                        }
                      });
                    },
                  );
                }),
              ],

              if (!isPrivileged) ...[
                const SizedBox(height: AppSpacing.lg),
                Text('Чем может заниматься бухгалтер',
                  style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                ..._editPermissionCheckboxes(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
      final result = await ds.updateUser(
        userId: widget.user.id,
        role: _role,
        isActive: _isActive,
        assignedBranchIds: _assignedBranches.toList(),
        permissions: _permissions,
        displayName: _nameCtrl.text.trim() != widget.user.displayName ? _nameCtrl.text.trim() : null,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.of(context).pop();
        widget.onUpdated();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['error']?.toString() ?? 'Ошибка'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Widget> _editPermissionCheckboxes() {
    return [
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Переводы', style: TextStyle(fontSize: 14)), value: _permissions.canTransfers, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canTransfers: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Управление переводами', style: TextStyle(fontSize: 14)), value: _permissions.canManageTransfers, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canManageTransfers: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Пополнение филиала', style: TextStyle(fontSize: 14)), value: _permissions.canBranchTopUp, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canBranchTopUp: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Покупки', style: TextStyle(fontSize: 14)), value: _permissions.canPurchases, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canPurchases: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Управление покупками', style: TextStyle(fontSize: 14)), value: _permissions.canManagePurchases, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canManagePurchases: v ?? false))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Клиенты', style: TextStyle(fontSize: 14)), value: _permissions.canClients, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canClients: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Журнал операций', style: TextStyle(fontSize: 14)), value: _permissions.canLedger, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canLedger: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Аналитика', style: TextStyle(fontSize: 14)), value: _permissions.canAnalytics, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canAnalytics: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Отчёты', style: TextStyle(fontSize: 14)), value: _permissions.canReports, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canReports: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Курсы валют', style: TextStyle(fontSize: 14)), value: _permissions.canExchangeRates, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canExchangeRates: v ?? true))),
      CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Просмотр филиалов', style: TextStyle(fontSize: 14)), value: _permissions.canBranchesView, onChanged: (v) => setState(() => _permissions = _permissions.copyWith(canBranchesView: v ?? true))),
    ];
  }
}

// ─── Edit Branch Dialog ───

class _EditBranchDialog extends StatefulWidget {
  const _EditBranchDialog({required this.branch, required this.onUpdated});
  final Branch branch;
  final VoidCallback onUpdated;

  @override
  State<_EditBranchDialog> createState() => _EditBranchDialogState();
}

class _EditBranchDialogState extends State<_EditBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _codeCtrl;
  late String _currency;
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS', 'TRY', 'KGS'];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.branch.name);
    _codeCtrl = TextEditingController(text: widget.branch.code);
    _currency = widget.branch.baseCurrency;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final repo = sl<BranchRepository>();
    final result = await repo.updateBranch(
      branchId: widget.branch.id,
      name: _nameCtrl.text.trim(),
      code: _codeCtrl.text.trim().toUpperCase(),
      baseCurrency: _currency,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    result.fold(
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${failure.message}'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      ),
      (_) {
        Navigator.of(context).pop();
        widget.onUpdated();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.edit_outlined, color: AppColors.primary),
          SizedBox(width: 10),
          Text('Изменить филиал'),
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
                  labelText: 'Название филиала *',
                  border: OutlineInputBorder(),
                  hintText: 'Ташкент',
                  prefixIcon: Icon(Icons.business_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Код филиала (номер карты) *',
                  border: OutlineInputBorder(),
                  hintText: '111111',
                  prefixIcon: Icon(Icons.code_rounded),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите код' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                key: ValueKey('edit-branch-curr-$_currency'),
                value: _currency,
                decoration: const InputDecoration(
                  labelText: 'Базовая валюта *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.currency_exchange_rounded),
                ),
                items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_rounded),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }
}

// ─── Create Branch Dialog ───

class _CreateBranchDialog extends StatefulWidget {
  const _CreateBranchDialog({required this.onCreated});
  final VoidCallback onCreated;

  @override
  State<_CreateBranchDialog> createState() => _CreateBranchDialogState();
}

class _CreateBranchDialogState extends State<_CreateBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String _currency = 'USD';
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS', 'TRY', 'KGS'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.add_business_rounded, color: AppColors.primary),
          SizedBox(width: 10),
          Text('Новый филиал'),
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
                  labelText: 'Название филиала *',
                  border: OutlineInputBorder(),
                  hintText: 'Москва',
                  prefixIcon: Icon(Icons.business_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Код филиала *',
                  border: OutlineInputBorder(),
                  hintText: 'MSK',
                  prefixIcon: Icon(Icons.code_rounded),
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите код' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                key: ValueKey('new-branch-curr-$_currency'),
                initialValue: _currency,
                decoration: const InputDecoration(
                  labelText: 'Базовая валюта *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.currency_exchange_rounded),
                ),
                items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_rounded),
          label: const Text('Создать'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final repo = sl<BranchRepository>();
    final result = await repo.createBranch(
      name: _nameCtrl.text.trim(),
      code: _codeCtrl.text.trim().toUpperCase(),
      baseCurrency: _currency,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    result.fold(
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${failure.message}'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      ),
      (_) {
        Navigator.of(context).pop();
        widget.onCreated();
      },
    );
  }
}

// ─── Add Account Dialog ───

class _AddAccountDialog extends StatefulWidget {
  const _AddAccountDialog({required this.branch, required this.onCreated});
  final Branch branch;
  final VoidCallback onCreated;

  @override
  State<_AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<_AddAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  AccountType _type = AccountType.cash;
  late String _currency;
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS', 'TRY', 'KGS'];

  @override
  void initState() {
    super.initState();
    _currency = widget.branch.baseCurrency;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Новый счёт — ${widget.branch.name}'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название счёта *',
                  border: OutlineInputBorder(),
                  hintText: 'Касса USD',
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<AccountType>(
                key: ValueKey('acc-type-$_type'),
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Тип счёта', border: OutlineInputBorder()),
                items: AccountType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.displayName))).toList(),
                onChanged: (v) => setState(() => _type = v ?? AccountType.cash),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                key: ValueKey('acc-curr-$_currency'),
                initialValue: _currency,
                decoration: const InputDecoration(labelText: 'Валюта', border: OutlineInputBorder()),
                items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Добавить'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final repo = sl<BranchRepository>();
    final result = await repo.createBranchAccount(
      branchId: widget.branch.id,
      name: _nameCtrl.text.trim(),
      type: _type,
      currency: _currency,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    result.fold(
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${failure.message}'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      ),
      (_) {
        Navigator.of(context).pop();
        widget.onCreated();
      },
    );
  }
}

// ─── Edit Account Dialog (Creator only) ───

class _EditAccountDialog extends StatefulWidget {
  const _EditAccountDialog({
    required this.account,
    required this.branch,
    required this.onUpdated,
  });
  final BranchAccount account;
  final Branch branch;
  final VoidCallback onUpdated;

  @override
  State<_EditAccountDialog> createState() => _EditAccountDialogState();
}

class _EditAccountDialogState extends State<_EditAccountDialog> {
  late final TextEditingController _nameCtrl;
  late AccountType _type;
  late String _currency;
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS', 'TRY', 'KGS'];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.account.name);
    _type = widget.account.type;
    _currency = widget.account.currency;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.edit_rounded, color: AppColors.secondary),
          SizedBox(width: 10),
          Text('Изменить счёт'),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Название счёта *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.account_balance_wallet_outlined),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите название' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<AccountType>(
              key: ValueKey('edit-acc-type-$_type'),
              value: _type,
              decoration: const InputDecoration(labelText: 'Тип счёта', border: OutlineInputBorder()),
              items: AccountType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.displayName))).toList(),
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              key: ValueKey('edit-acc-curr-$_currency'),
              value: _currency,
              decoration: const InputDecoration(labelText: 'Валюта', border: OutlineInputBorder()),
              items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) => setState(() => _currency = v ?? _currency),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_rounded),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название счёта'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    setState(() => _loading = true);
    final repo = sl<BranchRepository>();
    final result = await repo.updateBranchAccount(
      accountId: widget.account.id,
      name: _nameCtrl.text.trim(),
      type: _type,
      currency: _currency,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    result.fold(
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${failure.message}'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      ),
      (_) {
        Navigator.of(context).pop();
        widget.onUpdated();
      },
    );
  }
}

// ─── Adjust Balance Dialog ───

class _AdjustBalanceDialog extends StatefulWidget {
  const _AdjustBalanceDialog({
    required this.branch,
    required this.account,
    required this.currentBalance,
    required this.onDone,
  });
  final Branch branch;
  final BranchAccount account;
  final double currentBalance;
  final VoidCallback onDone;

  @override
  State<_AdjustBalanceDialog> createState() => _AdjustBalanceDialogState();
}

class _AdjustBalanceDialogState extends State<_AdjustBalanceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _operation = 'credit'; // credit = пополнение, debit = списание
  String _refType = 'adjustment'; // adjustment or openingBalance
  bool _loading = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final balColor = widget.currentBalance >= 0 ? AppColors.primary : AppColors.error;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.tune_rounded, color: AppColors.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text('Корректировка: ${widget.account.name}', overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Current balance display
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: balColor.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(color: balColor.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet_rounded, size: 20, color: balColor),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Текущий баланс',
                          style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                        Text(
                          '${widget.currentBalance.toStringAsFixed(2)} ${widget.account.currency}',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: balColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Operation type
              Text('Тип операции', style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: _OperationCard(
                      label: 'Пополнение',
                      icon: Icons.add_circle_outline_rounded,
                      color: AppColors.income,
                      selected: _operation == 'credit',
                      onTap: () => setState(() => _operation = 'credit'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _OperationCard(
                      label: 'Списание',
                      icon: Icons.remove_circle_outline_rounded,
                      color: AppColors.expense,
                      selected: _operation == 'debit',
                      onTap: () => setState(() => _operation = 'debit'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),

              // Reference type
              DropdownButtonFormField<String>(
                key: ValueKey('ref-$_refType'),
                initialValue: _refType,
                decoration: const InputDecoration(
                  labelText: 'Причина',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label_outline_rounded),
                ),
                items: const [
                  DropdownMenuItem(value: 'adjustment', child: Text('Корректировка')),
                  DropdownMenuItem(value: 'openingBalance', child: Text('Начальный баланс')),
                ],
                onChanged: (v) => setState(() => _refType = v ?? 'adjustment'),
              ),
              const SizedBox(height: AppSpacing.md),

              // Amount
              TextFormField(
                controller: _amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Сумма (${widget.account.currency}) *',
                  border: const OutlineInputBorder(),
                  prefixIcon: Icon(
                    _operation == 'credit' ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                    color: _operation == 'credit' ? AppColors.income : AppColors.expense,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Введите сумму';
                  final parsed = double.tryParse(v.replaceAll(',', '.'));
                  if (parsed == null || parsed <= 0) return 'Сумма должна быть > 0';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),

              // Description
              TextFormField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Описание (необязательно)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.notes_rounded),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(_operation == 'credit' ? Icons.add_rounded : Icons.remove_rounded),
          label: Text(_operation == 'credit' ? 'Пополнить' : 'Списать'),
          style: FilledButton.styleFrom(
            backgroundColor: _operation == 'credit' ? AppColors.income : AppColors.expense,
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      final amount = double.parse(_amountCtrl.text.replaceAll(',', '.'));
      final creatorUid = context.read<AuthBloc>().state.user?.id ?? '';
      final ds = sl<LedgerRemoteDataSource>();

      await ds.adjustAccountBalance(
        branchId: widget.branch.id,
        accountId: widget.account.id,
        amount: amount,
        currency: widget.account.currency,
        type: _operation,
        referenceType: _refType,
        description: _descCtrl.text.trim().isEmpty
            ? (_refType == 'openingBalance' ? 'Начальный баланс' : 'Корректировка баланса')
            : _descCtrl.text.trim(),
        createdBy: creatorUid,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onDone();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({required this.label, required this.icon, required this.color, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
            color: selected ? color : Colors.grey.withValues(alpha: 0.3),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: selected ? color : Colors.grey),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? color : Colors.grey,
            )),
          ],
        ),
      ),
    );
  }
}
