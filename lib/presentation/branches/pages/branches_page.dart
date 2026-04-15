import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

class BranchesPage extends StatefulWidget {
  const BranchesPage({super.key});

  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  final _repo = sl<BranchRepository>();
  final _ledgerDs = sl<LedgerRemoteDataSource>();
  late final StreamSubscription<List<Branch>> _sub;
  List<Branch> _branches = [];
  Branch? _selected;
  List<BranchAccount> _accounts = [];
  Map<String, double> _balances = {};
  bool _loading = true;
  StreamSubscription<List<BranchAccount>>? _accountsSub;
  StreamSubscription<Map<String, double>>? _balancesSub;

  AppUser? get _currentUser {
    try {
      return context.read<AuthBloc>().state.user;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sub = _repo.watchBranches().listen((branches) {
      if (mounted) {
        setState(() {
          _branches = filterBranchesByAccess(branches, _currentUser);
          _loading = false;
        });
      }
    });
  }

  void _selectBranch(Branch branch) {
    setState(() => _selected = branch);
    _accountsSub?.cancel();
    _balancesSub?.cancel();
    _accountsSub = _repo.watchBranchAccounts(branch.id).listen((accs) {
      if (mounted) setState(() => _accounts = accs);
    });
    _balancesSub = _ledgerDs.watchBranchBalances(branch.id).listen((bals) {
      if (mounted) setState(() => _balances = bals);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _accountsSub?.cancel();
    _balancesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCreator = _currentUser?.role.isCreator ?? false;

    return context.isDesktop
        ? _DesktopLayout(
            branches: _branches,
            selected: _selected,
            accounts: _accounts,
            balances: _balances,
            loading: _loading,
            onSelect: _selectBranch,
            canManage: isCreator,
          )
        : _MobileLayout(
            branches: _branches,
            loading: _loading,
            canManage: isCreator,
          );
  }
}

// ─── Desktop ───

class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({
    required this.branches,
    required this.selected,
    required this.accounts,
    required this.balances,
    required this.loading,
    required this.onSelect,
    required this.canManage,
  });

  final List<Branch> branches;
  final Branch? selected;
  final List<BranchAccount> accounts;
  final Map<String, double> balances;
  final bool loading;
  final ValueChanged<Branch> onSelect;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
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
                    Text('Управление филиалами',
                        style: context.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      '${branches.length} активных филиалов',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canManage)
                FilledButton.icon(
                  onPressed: () => _showCreateBranchDialog(context),
                  icon: const Icon(Icons.add_business_rounded),
                  label: const Text('Добавить филиал'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Branch list
                SizedBox(
                  width: 280,
                  child: _BranchList(
                    branches: branches,
                    selected: selected,
                    loading: loading,
                    onSelect: onSelect,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                // Branch detail
                Expanded(
                  child: selected != null
                      ? _BranchDetail(
                          branch: selected!,
                          accounts: accounts,
                          balances: balances,
                          canManage: canManage,
                        )
                      : const _EmptyDetail(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mobile ───

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({required this.branches, required this.loading, required this.canManage});
  final List<Branch> branches;
  final bool loading;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Филиалы')),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _showCreateBranchDialog(context),
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Добавить'),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: branches.length,
              itemBuilder: (context, i) {
                final branch = branches[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                    child: Text(
                      branch.code.substring(0, branch.code.length.clamp(0, 2)),
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  title: Text(branch.name),
                  subtitle: Text(branch.baseCurrency),
                  trailing: const Icon(Icons.chevron_right_rounded),
                );
              },
            ),
    );
  }
}

// ─── Branch List (Desktop sidebar) ───

class _BranchList extends StatelessWidget {
  const _BranchList({
    required this.branches,
    required this.selected,
    required this.loading,
    required this.onSelect,
  });
  final List<Branch> branches;
  final Branch? selected;
  final bool loading;
  final ValueChanged<Branch> onSelect;

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
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text('Список филиалов',
                style: context.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemCount: branches.length,
                    itemBuilder: (context, i) {
                      final branch = branches[i];
                      final isSelected = selected?.id == branch.id;
                      return ListTile(
                        selected: isSelected,
                        selectedTileColor:
                            AppColors.primary.withValues(alpha: 0.08),
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: isSelected
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.1),
                          child: Text(
                            branch.code
                                .substring(0, branch.code.length.clamp(0, 2)),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color:
                                  isSelected ? Colors.white : AppColors.primary,
                            ),
                          ),
                        ),
                        title: Text(branch.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text(branch.baseCurrency),
                        onTap: () => onSelect(branch),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Branch Detail ───

class _BranchDetail extends StatelessWidget {
  const _BranchDetail({
    required this.branch,
    required this.accounts,
    required this.balances,
    this.canManage = false,
  });
  final Branch branch;
  final List<BranchAccount> accounts;
  final Map<String, double> balances;
  final bool canManage;

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
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Branch header
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      branch.code
                          .substring(0, branch.code.length.clamp(0, 3)),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(branch.name,
                          style: context.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text('Базовая валюта: ${branch.baseCurrency}',
                          style: context.textTheme.bodyMedium),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                              color: Colors.green, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      const Text('Активен',
                          style: TextStyle(
                              color: Colors.green, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: () =>
                      _showAddAccountDialog(context, branch),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Добавить счёт'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            const Divider(),
            const SizedBox(height: AppSpacing.md),

            // Accounts table
            Text('Счета филиала',
                style: context.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: accounts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.account_balance_outlined,
                              size: 40,
                              color: context.isDark
                                  ? AppColors.darkTextSecondary
                                  : AppColors.lightTextSecondary),
                          const SizedBox(height: AppSpacing.sm),
                          const Text('Нет счетов'),
                        ],
                      ),
                    )
                  : SingleChildScrollView(
                      child: DataTable(
                        columnSpacing: 24,
                        headingRowColor: WidgetStateProperty.all(
                          Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                        columns: const [
                          DataColumn(label: Text('Название')),
                          DataColumn(label: Text('Тип')),
                          DataColumn(label: Text('Валюта')),
                          DataColumn(label: Text('Баланс')),
                          DataColumn(label: Text('Статус')),
                        ],
                        rows: accounts.map((acc) {
                          final balance = balances[acc.id] ?? 0.0;
                          final balColor = balance > 0 ? Colors.green : (balance < 0 ? Colors.red : null);
                          return DataRow(cells: [
                            DataCell(Text(acc.name)),
                            DataCell(_AccountTypeBadge(type: acc.type)),
                            DataCell(Text(acc.currency)),
                            DataCell(
                              Text(
                                '${balance.toStringAsFixed(2)} ${acc.currency}',
                                style: balColor != null
                                    ? TextStyle(color: balColor, fontWeight: FontWeight.w600)
                                    : null,
                              ),
                            ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    acc.isActive ? 'Активен' : 'Неактивен',
                                    style: TextStyle(
                                      color: acc.isActive
                                          ? Colors.green
                                          : Colors.red,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (canManage) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, size: 18),
                                      onPressed: () =>
                                          _showEditAccountDialog(context, branch, acc),
                                      tooltip: 'Изменить счёт',
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ]);
                        }).toList(),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountTypeBadge extends StatelessWidget {
  const _AccountTypeBadge({required this.type});
  final AccountType type;

  static const _colors = {
    AccountType.cash: Colors.green,
    AccountType.card: Colors.blue,
    AccountType.reserve: Colors.orange,
    AccountType.transit: Colors.purple,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[type] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        type.displayName,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

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
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.business_outlined,
                size: 48,
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary),
            const SizedBox(height: AppSpacing.md),
            Text('Выберите филиал',
                style: context.textTheme.bodyLarge?.copyWith(
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                )),
          ],
        ),
      ),
    );
  }
}

// ─── Dialogs ───

void _showCreateBranchDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => const _CreateBranchDialog(),
  );
}

class _CreateBranchDialog extends StatefulWidget {
  const _CreateBranchDialog();

  @override
  State<_CreateBranchDialog> createState() => _CreateBranchDialogState();
}

class _CreateBranchDialogState extends State<_CreateBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String _currency = 'USD';
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS'];

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
          Icon(Icons.add_business_rounded),
          SizedBox(width: 8),
          Text('Новый филиал'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 400,
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
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Код филиала *',
                  border: OutlineInputBorder(),
                  hintText: 'MSK',
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Введите код' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String>(
                key: ValueKey('branch-curr-$_currency'),
                initialValue: _currency,
                decoration: const InputDecoration(
                  labelText: 'Базовая валюта *',
                  border: OutlineInputBorder(),
                ),
                items: _currencies
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
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
        SnackBar(
          content: Text('Ошибка: ${failure.message}'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      ),
      (_) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Филиал создан'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
  }
}

void _showAddAccountDialog(BuildContext context, Branch branch) {
  showDialog(
    context: context,
    builder: (_) => _AddAccountDialog(branch: branch),
  );
}

void _showEditAccountDialog(
    BuildContext context, Branch branch, BranchAccount account) {
  showDialog(
    context: context,
    builder: (_) => _EditAccountDialog(branch: branch, account: account),
  );
}

class _EditAccountDialog extends StatefulWidget {
  const _EditAccountDialog({required this.branch, required this.account});
  final Branch branch;
  final BranchAccount account;

  @override
  State<_EditAccountDialog> createState() => _EditAccountDialogState();
}

class _EditAccountDialogState extends State<_EditAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late AccountType _type;
  late String _currency;
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'UZS', 'RUB', 'EUR', 'TRY', 'AED', 'CNY', 'KZT', 'KGS', 'TJS'];

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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
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
        SnackBar(
          content: Text('Ошибка: ${failure.message}'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      ),
      (_) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Счёт обновлён'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Изменить счёт'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<AccountType>(
                value: _type,
                decoration: const InputDecoration(
                  labelText: 'Тип счёта',
                  border: OutlineInputBorder(),
                ),
                items: AccountType.values
                    .map((t) => DropdownMenuItem(
                        value: t, child: Text(t.displayName)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v ?? _type),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String>(
                value: _currency,
                decoration: const InputDecoration(
                  labelText: 'Валюта',
                  border: OutlineInputBorder(),
                ),
                items: _currencies
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _currency = v ?? _currency),
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
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _AddAccountDialog extends StatefulWidget {
  const _AddAccountDialog({required this.branch});
  final Branch branch;

  @override
  State<_AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<_AddAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  AccountType _type = AccountType.cash;
  String _currency = 'USD';
  bool _loading = false;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'AED', 'CNY', 'KZT', 'TJS'];

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
          width: 360,
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
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Введите название' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<AccountType>(
                key: ValueKey('acc-type-$_type'),
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: 'Тип счёта',
                  border: OutlineInputBorder(),
                ),
                items: AccountType.values
                    .map((t) =>
                        DropdownMenuItem(value: t, child: Text(t.displayName)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v ?? AccountType.cash),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String>(
                key: ValueKey('acc-curr-$_currency'),
                initialValue: _currency,
                decoration: const InputDecoration(
                  labelText: 'Валюта',
                  border: OutlineInputBorder(),
                ),
                items: _currencies
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
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
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
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
        SnackBar(
          content: Text('Ошибка: ${failure.message}'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      ),
      (_) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Счёт добавлен'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
  }
}
