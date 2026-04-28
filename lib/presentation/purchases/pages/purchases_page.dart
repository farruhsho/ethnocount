import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/domain/entities/purchase.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/client_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/purchases/bloc/purchase_bloc.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  final _branchRepo = sl<BranchRepository>();
  final _clientRepo = sl<ClientRepository>();

  String _search = '';
  Purchase? _selected;
  String? _filterBranchId;
  List<Branch> _branches = [];
  List<Client> _clients = [];
  StreamSubscription<List<Branch>>? _branchSub;
  StreamSubscription<List<Client>>? _clientSub;

  @override
  void initState() {
    super.initState();
    context.read<PurchaseBloc>().add(const PurchasesLoadRequested());
    _branchSub = _branchRepo.watchBranches().listen((branches) {
      if (mounted) setState(() => _branches = branches);
    });
    _clientSub = _clientRepo.watchClients().listen((clients) {
      if (mounted) setState(() => _clients = clients);
    });
  }

  @override
  void dispose() {
    _branchSub?.cancel();
    _clientSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PurchaseBloc, PurchaseBlocState>(
      listener: (context, state) {
        if (state.status == PurchaseBlocStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage ?? 'Готово'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() => _selected = null);
        }
        if (state.status == PurchaseBlocStatus.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? 'Ошибка'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      builder: (context, state) {
        final filtered = state.purchases.where((p) {
          final q = _search.toLowerCase();
          final matchSearch = q.isEmpty ||
              p.description.toLowerCase().contains(q) ||
              p.transactionCode.toLowerCase().contains(q) ||
              (p.clientName?.toLowerCase().contains(q) ?? false);
          final matchBranch =
              _filterBranchId == null || p.branchId == _filterBranchId;
          return matchSearch && matchBranch;
        }).toList();

        final isLoading = state.status == PurchaseBlocStatus.loading ||
            state.status == PurchaseBlocStatus.creating;

        if (context.isDesktop) {
          return _DesktopLayout(
            purchases: filtered,
            selected: _selected,
            search: _search,
            filterBranchId: _filterBranchId,
            branches: _branches,
            clients: _clients,
            branchRepo: _branchRepo,
            isLoading: isLoading,
            onSelect: (p) => setState(() => _selected = p),
            onSearch: (v) => setState(() => _search = v),
            onFilterBranch: (id) => setState(() => _filterBranchId = id),
          );
        }
        return _MobileLayout(
          purchases: filtered,
          branches: _branches,
          clients: _clients,
          branchRepo: _branchRepo,
          search: _search,
          isLoading: isLoading,
          canManage: context.watch<AuthBloc>().state.user?.canManagePurchases ?? false,
          onSearch: (v) => setState(() => _search = v),
        );
      },
    );
  }
}

// ─── Desktop Layout ───

class _DesktopLayout extends StatelessWidget {
  final List<Purchase> purchases;
  final Purchase? selected;
  final String search;
  final String? filterBranchId;
  final List<Branch> branches;
  final List<Client> clients;
  final BranchRepository branchRepo;
  final bool isLoading;
  final ValueChanged<Purchase> onSelect;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onFilterBranch;

  const _DesktopLayout({
    required this.purchases,
    required this.selected,
    required this.search,
    required this.filterBranchId,
    required this.branches,
    required this.clients,
    required this.branchRepo,
    required this.isLoading,
    required this.onSelect,
    required this.onSearch,
    required this.onFilterBranch,
  });

  @override
  Widget build(BuildContext context) {
    final canManage = context.watch<AuthBloc>().state.user?.canManagePurchases ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Покупки'),
        actions: [
          if (canManage)
            FilledButton.icon(
              onPressed: () => _showCreateDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Новая покупка'),
            ),
          if (canManage) const SizedBox(width: AppSpacing.md),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: selected != null ? 6 : 10,
            child: Column(
              children: [
                _FilterBar(
                  search: search,
                  filterBranchId: filterBranchId,
                  branches: branches,
                  onSearch: onSearch,
                  onFilterBranch: onFilterBranch,
                ),
                Expanded(
                  child: isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : purchases.isEmpty
                          ? _EmptyState(
                              onCreate: canManage ? () => _showCreateDialog(context) : null)
                          : _PurchasesTable(
                              purchases: purchases,
                              selected: selected,
                              onTap: onSelect,
                            ),
                ),
              ],
            ),
          ),
          if (selected != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: 380,
              child: _DetailPanel(purchase: selected!),
            ),
          ],
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => BlocProvider.value(
        value: context.read<PurchaseBloc>(),
        child: _CreatePurchaseDialog(
          branches: branches,
          clients: clients,
          branchRepo: branchRepo,
        ),
      ),
    );
  }
}

// ─── Mobile Layout ───

class _MobileLayout extends StatelessWidget {
  final List<Purchase> purchases;
  final List<Branch> branches;
  final List<Client> clients;
  final BranchRepository branchRepo;
  final String search;
  final bool isLoading;
  final bool canManage;
  final ValueChanged<String> onSearch;

  const _MobileLayout({
    required this.purchases,
    required this.branches,
    required this.clients,
    required this.branchRepo,
    required this.search,
    required this.isLoading,
    required this.canManage,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Покупки'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Поиск по описанию, коду...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: onSearch,
            ),
          ),
        ),
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => BlocProvider.value(
                  value: context.read<PurchaseBloc>(),
                  child: _CreatePurchaseDialog(
                    branches: branches,
                    clients: clients,
                    branchRepo: branchRepo,
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Покупка'),
            )
          : null,
      body: isLoading && purchases.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : purchases.isEmpty
              ? _EmptyState(
                  onCreate: canManage
                      ? () => showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => BlocProvider.value(
                              value: context.read<PurchaseBloc>(),
                              child: _CreatePurchaseDialog(
                                branches: branches,
                                clients: clients,
                                branchRepo: branchRepo,
                              ),
                            ),
                          )
                      : null)
              : RefreshIndicator(
                  onRefresh: () async {
                    context
                        .read<PurchaseBloc>()
                        .add(const PurchasesLoadRequested());
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: purchases.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final p = purchases[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppColors.primary.withValues(alpha: 0.1),
                          child: Text(
                            CurrencyUtils.flag(p.currency),
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                        title: Text(p.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15)),
                        subtitle: Text(p.transactionCode,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    fontSize: 13,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline)),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${CurrencyUtils.symbol(p.currency)} ${p.totalAmount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14),
                            ),
                            Text(
                              p.createdAt.historyFormatted,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontSize: 12),
                            ),
                          ],
                        ),
                        onTap: () => showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (_) => _DetailPanel(purchase: p),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

// ─── Filter Bar ───

class _FilterBar extends StatelessWidget {
  final String search;
  final String? filterBranchId;
  final List<Branch> branches;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onFilterBranch;

  const _FilterBar({
    required this.search,
    required this.filterBranchId,
    required this.branches,
    required this.onSearch,
    required this.onFilterBranch,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Поиск по описанию, коду, клиенту...',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                isDense: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: onSearch,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (branches.isNotEmpty)
            DropdownButton<String?>(
              value: filterBranchId,
              hint: const Text('Все филиалы'),
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(10),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('Все филиалы')),
                ...branches.map(
                  (b) => DropdownMenuItem(
                      value: b.id, child: Text(b.name)),
                ),
              ],
              onChanged: onFilterBranch,
            ),
        ],
      ),
    );
  }
}

// ─── Purchases Table ───

class _PurchasesTable extends StatelessWidget {
  final List<Purchase> purchases;
  final Purchase? selected;
  final ValueChanged<Purchase> onTap;

  const _PurchasesTable({
    required this.purchases,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 44,
        dataRowMaxHeight: 56,
        showCheckboxColumn: false,
        columns: [
          DataColumn(label: Text('Код', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          DataColumn(label: Text('Описание', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          DataColumn(label: Text('Сумма', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), numeric: true),
          DataColumn(label: Text('Оплата', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          DataColumn(label: Text('Клиент', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          DataColumn(label: Text('Дата и время', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        ],
        rows: purchases.map((p) {
          final isSelected = selected?.id == p.id;
          return DataRow(
            selected: isSelected,
            color: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.primary.withValues(alpha: 0.08);
              }
              return null;
            }),
            onSelectChanged: (_) => onTap(p),
            cells: [
              DataCell(
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    p.transactionCode,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              DataCell(
                SizedBox(
                  width: 180,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: theme.colorScheme.onSurface)),
                      if (p.category != null)
                        Text(p.category!,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                                fontSize: 13)),
                    ],
                  ),
                ),
              ),
              DataCell(
                Text(
                  '${CurrencyUtils.flag(p.currency)} ${CurrencyUtils.symbol(p.currency)} ${p.totalAmount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              DataCell(_PaymentBreakdownChip(payments: p.payments)),
              DataCell(
                Text(p.clientName ?? '—',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurface,
                    )),
              ),
              DataCell(
                Text(p.createdAt.historyFormatted,
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurface,
                    )),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _PaymentBreakdownChip extends StatelessWidget {
  final List<PurchasePayment> payments;
  const _PaymentBreakdownChip({required this.payments});

  @override
  Widget build(BuildContext context) {
    if (payments.isEmpty) return const Text('—');
    return Row(
      children: payments.take(3).map((p) {
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Tooltip(
            message:
                '${p.accountName}: ${p.amount.toStringAsFixed(2)} ${p.currency}',
            child: Chip(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelPadding:
                  const EdgeInsets.symmetric(horizontal: 6),
              label: Text(
                '${p.percentage.toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Detail Panel ───

class _DetailPanel extends StatelessWidget {
  final Purchase purchase;
  const _DetailPanel({required this.purchase});

  void _showEditDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<PurchaseBloc>(),
        child: _EditPurchaseDialog(
          purchase: purchase,
          onUpdated: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<PurchaseBloc>(),
        child: _DeletePurchaseDialog(
          purchase: purchase,
          onDeleted: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  static const _colors = [
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthBloc>().state.user;
    final canManage = user?.canManagePurchases ?? false;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Детали покупки'),
        actions: [
          if (canManage) ...[
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => _showEditDialog(context),
              tooltip: 'Изменить',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _showDeleteDialog(context),
              tooltip: 'Удалить',
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              child: Text(
                purchase.transactionCode,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _InfoRow(
            label: 'Итого',
            value:
                '${CurrencyUtils.flag(purchase.currency)} ${CurrencyUtils.symbol(purchase.currency)} ${purchase.totalAmount.toStringAsFixed(2)} ${purchase.currency}',
            isHighlight: true,
          ),
          _InfoRow(label: 'Описание', value: purchase.description),
          if (purchase.category != null)
            _InfoRow(label: 'Категория', value: purchase.category!),
          _InfoRow(label: 'Филиал', value: purchase.branchId),
          if (purchase.clientName != null)
            _InfoRow(label: 'Клиент', value: purchase.clientName!),
          _InfoRow(
            label: 'Дата',
            value: purchase.createdAt.historyFormatted,
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Разбивка платежей',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: AppSpacing.sm),
          ...purchase.payments.asMap().entries.map((entry) {
            final i = entry.key;
            final p = entry.value;
            final color = _colors[i % _colors.length];
            return Card(
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: color,
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.accountName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500)),
                          Text(
                            '${CurrencyUtils.symbol(p.currency)} ${p.amount.toStringAsFixed(2)} ${p.currency}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${p.percentage.toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 80,
                          height: 6,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: p.percentage / 100,
                              backgroundColor:
                                  color.withValues(alpha: 0.2),
                              color: color,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─── Edit Purchase Dialog (Creator only) ───

class _EditPurchaseDialog extends StatefulWidget {
  const _EditPurchaseDialog({
    required this.purchase,
    required this.onUpdated,
  });
  final Purchase purchase;
  final VoidCallback onUpdated;

  @override
  State<_EditPurchaseDialog> createState() => _EditPurchaseDialogState();
}

class _EditPurchaseDialogState extends State<_EditPurchaseDialog> {
  late final TextEditingController _descCtrl;
  late final TextEditingController _catCtrl;
  late final TextEditingController _amountCtrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.purchase.description);
    _catCtrl = TextEditingController(text: widget.purchase.category ?? '');
    _amountCtrl = TextEditingController(text: widget.purchase.totalAmount.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _catCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<PurchaseBloc, PurchaseBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == PurchaseBlocStatus.success ||
              curr.status == PurchaseBlocStatus.error),
      listener: (context, state) {
        if (state.status == PurchaseBlocStatus.success) {
          setState(() => _loading = false);
          Navigator.of(context).pop();
          widget.onUpdated();
        } else if (state.status == PurchaseBlocStatus.error) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? 'Ошибка'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.edit_rounded, color: AppColors.secondary),
          SizedBox(width: 10),
          Text('Изменить покупку'),
        ],
      ),
      content: SizedBox(
        width: context.isDesktop ? 380 : double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _descCtrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Описание *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.description_outlined),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _catCtrl,
              decoration: const InputDecoration(
                labelText: 'Категория',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.category_outlined),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Сумма (${widget.purchase.currency})',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.attach_money_outlined),
              ),
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
    ),
    );
  }

  Future<void> _submit() async {
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите описание'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите корректную сумму'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    setState(() => _loading = true);
    List<Map<String, dynamic>>? payments;
    if ((amount - widget.purchase.totalAmount).abs() > 0.01) {
      final scale = amount / widget.purchase.totalAmount;
      final list = <Map<String, dynamic>>[];
      var sum = 0.0;
      final ps = widget.purchase.payments;
      for (var i = 0; i < ps.length; i++) {
        final p = ps[i];
        final amt = i < ps.length - 1
            ? (p.amount * scale * 100).round() / 100
            : (amount - sum).roundToDouble();
        sum += amt;
        list.add({
          'accountId': p.accountId,
          'accountName': p.accountName,
          'amount': amt,
          'currency': p.currency,
          if (p.accountType != null) 'accountType': p.accountType!.name,
          'percentage': (amt / amount * 100),
        });
      }
      payments = list;
    }
    context.read<PurchaseBloc>().add(PurchaseUpdateRequested(
      purchaseId: widget.purchase.id,
      description: _descCtrl.text.trim(),
      category: _catCtrl.text.trim().isEmpty ? null : _catCtrl.text.trim(),
      totalAmount: amount,
      payments: payments,
    ));
  }
}

// ─── Delete Purchase Dialog ───

class _DeletePurchaseDialog extends StatefulWidget {
  const _DeletePurchaseDialog({
    required this.purchase,
    required this.onDeleted,
  });
  final Purchase purchase;
  final VoidCallback onDeleted;

  @override
  State<_DeletePurchaseDialog> createState() => _DeletePurchaseDialogState();
}

class _DeletePurchaseDialogState extends State<_DeletePurchaseDialog> {
  final _reasonCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<PurchaseBloc, PurchaseBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == PurchaseBlocStatus.success ||
              curr.status == PurchaseBlocStatus.error),
      listener: (context, state) {
        if (state.status == PurchaseBlocStatus.success) {
          setState(() => _loading = false);
          Navigator.of(context).pop();
          widget.onDeleted();
        } else if (state.status == PurchaseBlocStatus.error) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? 'Ошибка'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: AppColors.error),
            SizedBox(width: 10),
            Text('Удалить покупку'),
          ],
        ),
        content: SizedBox(
          width: context.isDesktop ? 380 : double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Покупка ${widget.purchase.transactionCode} будет удалена. '
                'Данные сохранятся в истории удалений.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _reasonCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Причина (необязательно)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
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
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.delete_rounded),
            label: const Text('Удалить'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          ),
        ],
      ),
    );
  }

  void _submit() {
    setState(() => _loading = true);
    context.read<PurchaseBloc>().add(PurchaseDeleteRequested(
      purchaseId: widget.purchase.id,
      reason: _reasonCtrl.text.trim().isEmpty ? null : _reasonCtrl.text.trim(),
    ));
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isHighlight;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isHighlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: isHighlight
                  ? Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      )
                  : Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty State ───

class _EmptyState extends StatelessWidget {
  final VoidCallback? onCreate;
  const _EmptyState({this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shopping_cart_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: AppSpacing.md),
          Text('Покупок пока нет',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  )),
          const SizedBox(height: AppSpacing.sm),
          const Text('Нажмите «Новая покупка» чтобы добавить'),
          if (onCreate != null) ...[
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Новая покупка'),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Client search field (поиск по имени, телефону, коду) ───

/// Bottom sheet with searchable client list — fixes tap selection.
class _ClientPickerSheet extends StatefulWidget {
  const _ClientPickerSheet({
    required this.clients,
    required this.matchClient,
    this.initialQuery = '',
  });

  final List<Client> clients;
  final bool Function(Client c, String q) matchClient;
  final String initialQuery;

  @override
  State<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends State<_ClientPickerSheet> {
  late final TextEditingController _searchCtrl;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.initialQuery);
    _query = widget.initialQuery;
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text.trim()));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Client> get _filtered =>
      widget.clients.where((c) => widget.matchClient(c, _query)).toList();

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Поиск по имени, телефону, коду...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_off_outlined),
            title: const Text('— Без клиента'),
            onTap: () => Navigator.of(context).pop<Client?>(null),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final c = filtered[i];
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(c.name),
                  subtitle: Text('${c.phone} • ${c.clientCode}'),
                  onTap: () => Navigator.of(context).pop<Client?>(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientSearchField extends StatefulWidget {
  const _ClientSearchField({
    required this.clients,
    required this.selectedId,
    required this.selectedName,
    required this.onSelected,
  });

  final List<Client> clients;
  final String? selectedId;
  final String? selectedName;
  final void Function(String? id, String? name) onSelected;

  @override
  State<_ClientSearchField> createState() => _ClientSearchFieldState();
}

class _ClientSearchFieldState extends State<_ClientSearchField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  static bool _matchClient(Client c, String q) {
    if (q.isEmpty) return true;
    final qLower = q.toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'[^\d]'), '');
    if (c.name.toLowerCase().contains(qLower)) return true;
    if (c.counterpartyId.toLowerCase().contains(qLower)) return true;
    if (c.clientCode.toLowerCase().contains(qLower)) return true;
    if (c.phone.isNotEmpty && c.phone.contains(q)) return true;
    if (qDigits.isNotEmpty && c.phone.isNotEmpty) {
      final phoneDigits = c.phone.replaceAll(RegExp(r'[^\d]'), '');
      if (phoneDigits.isNotEmpty &&
          (phoneDigits.contains(qDigits) || qDigits.contains(phoneDigits))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _showPicker() async {
    final result = await showModalBottomSheet<Client?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ClientPickerSheet(
        clients: widget.clients,
        matchClient: _matchClient,
        initialQuery: _controller.text.trim(),
      ),
    );
    if (!mounted) return;
    if (result == null) {
      widget.onSelected(null, null);
      _controller.clear();
    } else {
      widget.onSelected(result.id, result.name);
      _controller.text = result.name;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.text = widget.selectedName ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ClientSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedName != widget.selectedName) {
      _controller.text = widget.selectedName ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      decoration: InputDecoration(
        labelText: 'Клиент / Контрагент',
        hintText: 'Поиск по имени, телефону, коду...',
        prefixIcon: const Icon(Icons.person_outline_rounded),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.selectedId != null)
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  widget.onSelected(null, null);
                  _controller.clear();
                },
              ),
            IconButton(
              icon: const Icon(Icons.arrow_drop_down),
              onPressed: _showPicker,
            ),
          ],
        ),
      ),
      onTap: _showPicker, // tap anywhere opens search picker
      readOnly: true, // force use of picker for selection
    );
  }
}

// ─── Create Purchase Dialog ───

class _PaymentRowData {
  String accountId = '';
  String accountName = '';
  /// [AccountType.name] for the selected branch account.
  String accountType = '';
  String currency = 'USD';
  final TextEditingController amountCtrl = TextEditingController();
}

class _CreatePurchaseDialog extends StatefulWidget {
  final List<Branch> branches;
  final List<Client> clients;
  final BranchRepository branchRepo;

  const _CreatePurchaseDialog({
    required this.branches,
    required this.clients,
    required this.branchRepo,
  });

  @override
  State<_CreatePurchaseDialog> createState() =>
      _CreatePurchaseDialogState();
}

class _CreatePurchaseDialogState
    extends State<_CreatePurchaseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();

  String _branchId = '';
  String _currency = 'USD';
  String? _clientId;
  String? _clientName;

  final List<_PaymentRowData> _rows = [_PaymentRowData()];
  List<BranchAccount> _accounts = [];
  StreamSubscription<List<BranchAccount>>? _accountsSub;

  @override
  void initState() {
    super.initState();
    if (widget.branches.isNotEmpty) {
      _branchId = widget.branches.first.id;
      _loadAccounts(_branchId);
    }
  }

  void _loadAccounts(String branchId) {
    _accountsSub?.cancel();
    _accountsSub =
        widget.branchRepo.watchBranchAccounts(branchId).listen((accs) {
      if (mounted) {
        setState(() {
          _accounts = accs;
          for (final r in _rows) {
            if (_accounts.isNotEmpty && r.accountId.isEmpty) {
              r.accountId = _accounts.first.id;
              r.accountName = _accounts.first.name;
              r.accountType = _accounts.first.type.name;
              r.currency = _accounts.first.currency;
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _categoryCtrl.dispose();
    _accountsSub?.cancel();
    for (final r in _rows) {
      r.amountCtrl.dispose();
    }
    super.dispose();
  }

  double get _totalAmount {
    return _rows.fold(0.0, (sum, r) {
      return sum + (double.tryParse(r.amountCtrl.text) ?? 0);
    });
  }

  void _addPaymentRow() {
    setState(() {
      final row = _PaymentRowData();
      if (_accounts.isNotEmpty) {
        row.accountId = _accounts.first.id;
        row.accountName = _accounts.first.name;
        row.accountType = _accounts.first.type.name;
        row.currency = _accounts.first.currency;
      }
      _rows.add(row);
    });
  }

  void _removeRow(int index) {
    if (_rows.length == 1) return;
    setState(() {
      _rows[index].amountCtrl.dispose();
      _rows.removeAt(index);
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_branchId.isEmpty) {
      _showError('Выберите филиал');
      return;
    }
    if (_rows.any((r) => r.accountId.isEmpty)) {
      _showError('Выберите счёт для каждого платежа');
      return;
    }
    final total = _totalAmount;
    if (total <= 0) {
      _showError('Сумма должна быть больше 0');
      return;
    }

    final payments = _rows.map((r) {
      return {
        'accountId': r.accountId,
        'accountName': r.accountName,
        'amount': double.tryParse(r.amountCtrl.text) ?? 0.0,
        'currency': r.currency,
        if (r.accountType.isNotEmpty) 'accountType': r.accountType,
      };
    }).toList();

    context.read<PurchaseBloc>().add(PurchaseCreateRequested(
          branchId: _branchId,
          clientId: _clientId,
          clientName: _clientName,
          description: _descCtrl.text.trim(),
          category: _categoryCtrl.text.trim().isEmpty
              ? null
              : _categoryCtrl.text.trim(),
          totalAmount: total,
          currency: _currency,
          payments: payments,
        ));

    if (mounted) Navigator.pop(context);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: context.isDesktop
          ? const EdgeInsets.symmetric(horizontal: 80, vertical: 40)
          : const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 680, maxHeight: 800),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Новая покупка'),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                // ── Branch ──
                DropdownButtonFormField<String>(
                  key: ValueKey('purch-branch-$_branchId'),
                  initialValue: _branchId.isEmpty ? null : _branchId,
                  decoration: const InputDecoration(
                    labelText: 'Филиал *',
                    prefixIcon: Icon(Icons.business_outlined),
                  ),
                  items: widget.branches
                      .map((b) => DropdownMenuItem(
                          value: b.id, child: Text(b.name)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _branchId = v;
                      _accounts = [];
                      for (final r in _rows) {
                        r.accountId = '';
                      }
                    });
                    _loadAccounts(v);
                  },
                  validator: (v) =>
                      v == null ? 'Выберите филиал' : null,
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Client (counterparty) — поиск по имени, телефону, коду ──
                _ClientSearchField(
                  clients: widget.clients,
                  selectedId: _clientId,
                  selectedName: _clientName,
                  onSelected: (id, name) {
                    setState(() {
                      _clientId = id;
                      _clientName = name;
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Description ──
                TextFormField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Описание покупки *',
                    prefixIcon: Icon(Icons.description_outlined),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Введите описание'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Category ──
                TextFormField(
                  controller: _categoryCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Категория (необязательно)',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Currency ──
                DropdownButtonFormField<String>(
                  key: ValueKey('purch-curr-$_currency'),
                  initialValue: _currency,
                  decoration: const InputDecoration(
                    labelText: 'Валюта расчёта',
                    prefixIcon: Icon(Icons.currency_exchange),
                  ),
                  items: CurrencyUtils.supported
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(CurrencyUtils.display(c)),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _currency = v ?? 'USD'),
                ),
                const SizedBox(height: AppSpacing.xl),

                // ── Payment rows ──
                Row(
                  children: [
                    Text('Источники оплаты',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addPaymentRow,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Добавить счёт'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),

                ..._rows.asMap().entries.map((entry) {
                  final i = entry.key;
                  final row = entry.value;
                  return _PaymentRowWidget(
                    index: i,
                    row: row,
                    accounts: _accounts,
                    canRemove: _rows.length > 1,
                    onAccountChanged: (acct) {
                      setState(() {
                        row.accountId = acct.id;
                        row.accountName = acct.name;
                        row.accountType = acct.type.name;
                        row.currency = acct.currency;
                      });
                    },
                    onRemove: () => _removeRow(i),
                    onAmountChanged: () => setState(() {}),
                  );
                }),

                const SizedBox(height: AppSpacing.md),

                // ── Total preview ──
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color:
                            AppColors.primary.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Итого к оплате',
                          style: theme.textTheme.titleSmall),
                      Text(
                        '${CurrencyUtils.flag(_currency)} ${CurrencyUtils.symbol(_currency)} ${_totalAmount.toStringAsFixed(2)} $_currency',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Payment breakdown bar ──
                if (_totalAmount > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Row(
                      children: _rows.asMap().entries.map((entry) {
                        final i = entry.key;
                        final row = entry.value;
                        final amt =
                            double.tryParse(row.amountCtrl.text) ??
                                0;
                        final pct = _totalAmount > 0
                            ? (amt / _totalAmount)
                            : 0.0;
                        const colors = [
                          Color(0xFF4CAF50),
                          Color(0xFF2196F3),
                          Color(0xFFFF9800),
                          Color(0xFF9C27B0),
                        ];
                        final color = colors[i % colors.length];
                        return Expanded(
                          flex: (pct * 1000).round().clamp(1, 1000),
                          child: Tooltip(
                            message:
                                '${row.accountName}: ${(pct * 100).toStringAsFixed(1)}%',
                            child: Container(
                              height: 8,
                              color: color,
                              margin: const EdgeInsets.only(right: 1),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: FilledButton(
                onPressed: _submit,
                child: const Text('Записать покупку'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Payment Row Widget ───

class _PaymentRowWidget extends StatelessWidget {
  final int index;
  final _PaymentRowData row;
  final List<BranchAccount> accounts;
  final bool canRemove;
  final ValueChanged<BranchAccount> onAccountChanged;
  final VoidCallback onRemove;
  final VoidCallback onAmountChanged;

  const _PaymentRowWidget({
    required this.index,
    required this.row,
    required this.accounts,
    required this.canRemove,
    required this.onAccountChanged,
    required this.onRemove,
    required this.onAmountChanged,
  });

  static const _colors = [
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _colors[index % _colors.length];

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: color,
              child: Text('${index + 1}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white)),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: accounts.isEmpty
                  ? const Text('Загрузка счетов...',
                      style:
                          TextStyle(color: Colors.grey, fontSize: 13))
                  : DropdownButtonFormField<String>(
                      key: ValueKey('pay-acc-${row.accountId}'),
                      initialValue: row.accountId.isEmpty
                          ? null
                          : row.accountId,
                      decoration: const InputDecoration(
                        labelText: 'Счёт',
                        isDense: true,
                      ),
                      items: accounts
                          .map((a) => DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  '${a.name} (${a.currency})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final acct =
                            accounts.firstWhere((a) => a.id == v);
                        onAccountChanged(acct);
                      },
                    ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 120,
              child: TextFormField(
                controller: row.amountCtrl,
                decoration: InputDecoration(
                  labelText: 'Сумма',
                  isDense: true,
                  suffixText: row.currency,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                onChanged: (_) => onAmountChanged(),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Введите';
                  if ((double.tryParse(v) ?? -1) <= 0) return '> 0';
                  return null;
                },
              ),
            ),
            if (canRemove) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    size: 20),
                onPressed: onRemove,
                color: Theme.of(context).colorScheme.error,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
