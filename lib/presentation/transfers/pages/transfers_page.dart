import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/routing/route_names.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/desktop_data_grid.dart';
import 'package:ethnocount/presentation/common/widgets/filter_panel.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';
import 'package:ethnocount/presentation/common/widgets/export_dialog.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/presentation/transfers/widgets/accept_transfer_account_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/edit_transfer_dialog.dart';

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  final _exportService = sl<ServerExportService>();
  bool _isExporting = false;
  TransferStatus? _statusFilter;
  String? _branchFilter;
  DateTimeRange? _dateRange;
  TrinaGridStateManager? _gridStateManager;

  @override
  void initState() {
    super.initState();
    _loadTransfers();
  }

  void _loadTransfers() {
    context.read<TransferBloc>().add(TransfersLoadRequested(
          statusFilter: _statusFilter,
          branchId: _branchFilter,
          startDate: _dateRange?.start,
          endDate: _dateRange?.end,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final user = context.select<AuthBloc, dynamic>((b) => b.state.user);
    final canManageTransfers = user?.canManageTransfers ?? false;
    final canBranchTopUp = user?.canBranchTopUp ?? false;
    final allBranches = context.select<DashboardBloc, List<Branch>>(
      (bloc) => bloc.state.branches,
    );
    final branches = filterBranchesByAccess(allBranches, user);

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          _loadTransfers();
          if (state.successMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.successMessage!),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        if (state.status == TransferBlocStatus.error &&
            state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage!),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: DataGridShortcuts(
      stateManager: _gridStateManager,
      onExport: _onExport,
      child: Column(
        children: [
          // Page header
          _buildHeader(context, canManageTransfers, canBranchTopUp),

          // Filter panel
          FilterPanel(
            onReset: () {
              setState(() {
                _statusFilter = null;
                _branchFilter = null;
                _dateRange = null;
              });
              _loadTransfers();
            },
            trailing: FilledButton.icon(
              onPressed: _isExporting ? null : _onExport,
              icon: _isExporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, size: 16),
              label: Text(
                _isExporting ? 'Загрузка...' : 'Excel',
                style: const TextStyle(fontSize: 13),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            children: [
              FilterDropdown<TransferStatus>(
                label: 'Статус',
                items: TransferStatus.values,
                value: _statusFilter,
                itemLabel: (s) => s.displayName,
                width: 150,
                onChanged: (val) {
                  setState(() => _statusFilter = val);
                  _loadTransfers();
                },
              ),
              FilterDropdown<String>(
                label: 'Филиал',
                items: branches.map((b) => b.id).toList(),
                value: _branchFilter,
                itemLabel: (id) => branches.firstWhere((b) => b.id == id).name,
                width: 180,
                onChanged: (val) {
                  setState(() => _branchFilter = val);
                  _loadTransfers();
                },
              ),
              DateRangeFilter(
                startDate: _dateRange?.start,
                endDate: _dateRange?.end,
                onChanged: (range) {
                  setState(() => _dateRange = range);
                  _loadTransfers();
                },
              ),
            ],
          ),

          // Data grid
          Expanded(
            child: BlocBuilder<TransferBloc, TransferBlocState>(
              builder: (context, state) {
                if (state.status == TransferBlocStatus.loading &&
                    state.transfers.isEmpty) {
                  return _buildLoadingSkeleton();
                }

                if (state.transfers.isEmpty) {
                  final hasFilters =
                      _statusFilter != null || _branchFilter != null || _dateRange != null;
                  return _buildEmptyState(
                    context,
                    canManageTransfers,
                    hasActiveFilters: hasFilters,
                    onResetFilters: hasFilters
                        ? () {
                            setState(() {
                              _statusFilter = null;
                              _branchFilter = null;
                              _dateRange = null;
                            });
                            _loadTransfers();
                          }
                        : null,
                  );
                }

                if (context.isDesktop) {
                  final branchAccounts = context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
                    (bloc) => bloc.state.branchAccounts,
                  );
                  return StreamBuilder<List<AppUser>>(
                    stream: sl<UserRemoteDataSource>().watchUsers(),
                    builder: (ctx, userSnap) {
                      final userNames = <String, String>{};
                      for (final u in userSnap.data ?? []) {
                        userNames[u.id] = u.displayName.isNotEmpty
                            ? u.displayName
                            : (u.email.isNotEmpty ? u.email : '—');
                      }
                      if (!userSnap.hasData && userSnap.connectionState == ConnectionState.waiting) {
                        return _buildLoadingSkeleton();
                      }
                      return _buildDesktopGrid(
                        context,
                        state.transfers,
                        allBranches,
                        branchAccounts,
                        canManageTransfers,
                        userNames,
                      );
                    },
                  );
                }

                final branchAccounts = context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
                  (bloc) => bloc.state.branchAccounts,
                );
                return _buildMobileList(
                  context,
                  state.transfers,
                  allBranches,
                  branchAccounts,
                  canManageTransfers,
                );
              },
            ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildHeader(BuildContext context, bool canManageTransfers, bool canBranchTopUp) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Переводы',
                style: context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Между филиалами: создание, приём и фильтры',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => context.goNamed(RouteNames.acceptedTransfers),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Принятые'),
          ),
          if (canBranchTopUp)
            OutlinedButton.icon(
              onPressed: () => context.go('/transfers/topup'),
              icon: const Icon(Icons.add_business_rounded, size: 18),
              label: const Text('Пополнение филиала'),
            ),
          if (canManageTransfers) ...[
            OutlinedButton.icon(
              onPressed: () => context.go('/transfers/manage'),
              icon: const Icon(Icons.inbox_rounded, size: 18),
              label: const Text('Управление'),
            ),
            FilledButton.icon(
              onPressed: () => context.goNamed(RouteNames.createTransfer),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Новый перевод'),
            ),
          ],
        ],
      ),
    );
  }

  /// Показываем имя пользователя, не UID. Если не найден — «—».
  static String _userDisplay(Map<String, String> userNames, String userId) {
    final name = userNames[userId];
    return (name != null && name.isNotEmpty) ? name : '—';
  }

  Widget _buildDesktopGrid(
    BuildContext context,
    List<Transfer> transfers,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers, [
    Map<String, String> userNames = const {},
  ]) {
    String branchName(String id) {
      final match = branches.where((b) => b.id == id);
      return match.isNotEmpty ? match.first.name : id;
    }

    String accountName(String id) {
      for (final list in branchAccounts.values) {
        final acc = list.where((a) => a.id == id).firstOrNull;
        if (acc != null) return acc.name;
      }
      return id;
    }

    final columns = [
      FinancialColumns.text(title: 'Код', field: 'code', width: 100, frozen: true),
      FinancialColumns.text(title: 'Дата', field: 'date', width: 95),
      FinancialColumns.text(title: 'Филиал отправителя', field: 'from', width: 140),
      FinancialColumns.text(title: 'Счёт отправителя', field: 'fromAccount', width: 140),
      FinancialColumns.text(title: 'Имя отправителя', field: 'senderName', width: 120),
      FinancialColumns.text(title: 'Телефон отправителя', field: 'senderPhone', width: 120),
      FinancialColumns.text(title: 'Филиал получателя', field: 'to', width: 140),
      FinancialColumns.text(title: 'Имя получателя', field: 'receiverName', width: 120),
      FinancialColumns.text(title: 'Телефон получателя', field: 'receiverPhone', width: 120),
      FinancialColumns.text(title: 'Сумма', field: 'amountDisplay', width: 100),
      FinancialColumns.text(title: 'Валюта отправителя', field: 'fromCurrency', width: 75),
      FinancialColumns.text(title: 'Курс', field: 'rate', width: 60),
      FinancialColumns.text(title: 'Конвертировано', field: 'convertedDisplay', width: 100),
      FinancialColumns.text(title: 'Валюта получателя', field: 'toCurrency', width: 75),
      FinancialColumns.text(title: 'Комиссия', field: 'commissionDisplay', width: 90),
      FinancialColumns.status(title: 'Статус', field: 'status', width: 80),
      FinancialColumns.text(title: 'Создал', field: 'createdBy', width: 85),
      FinancialColumns.text(title: 'Принял', field: 'confirmedBy', width: 85),
    ];

    final rows = transfers.map((t) {
      final sentCur = t.currency;
      final recvCur = t.toCurrency ?? t.currency;
      final sentText = t.isSplitCurrency
          ? t.splitPartsDisplay
          : '${t.totalDebitAmount.formatCurrencyNoDecimals()} $sentCur';
      final recvAmount = t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;
      final recvText = '${recvAmount.formatCurrencyNoDecimals()} $recvCur';
      final rateDisplay = sentCur != recvCur
          ? t.exchangeRate.toString()
          : '—';
      final commissionText = t.commission > 0
          ? '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}'
          : '—';

      return TrinaRow(cells: {
        'code': TrinaCell(value: t.transactionCode ?? t.id.substring(0, 8)),
        'date': TrinaCell(value: t.createdAt.fullFormatted),
        'from': TrinaCell(value: branchName(t.fromBranchId)),
        'fromAccount': TrinaCell(value: accountName(t.fromAccountId)),
        'senderName': TrinaCell(value: t.senderName ?? '—'),
        'senderPhone': TrinaCell(value: t.senderPhone ?? '—'),
        'to': TrinaCell(value: branchName(t.toBranchId)),
        'receiverName': TrinaCell(value: t.receiverName ?? '—'),
        'receiverPhone': TrinaCell(value: t.receiverPhone ?? '—'),
        'amountDisplay': TrinaCell(value: sentText),
        'fromCurrency': TrinaCell(value: sentCur),
        'rate': TrinaCell(value: rateDisplay),
        'convertedDisplay': TrinaCell(value: recvText),
        'toCurrency': TrinaCell(value: recvCur),
        'commissionDisplay': TrinaCell(value: commissionText),
        'status': TrinaCell(value: t.status.name),
        'createdBy': TrinaCell(value: _userDisplay(userNames, t.createdBy)),
        'confirmedBy': TrinaCell(value: t.confirmedBy != null ? _userDisplay(userNames, t.confirmedBy!) : '—'),
      });
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: DesktopDataGrid(
        gridId: 'transfers',
        columns: columns,
        rows: rows,
        frozenColumns: 1,
        showPagination: transfers.length > 50,
        onLoaded: (event) {
          _gridStateManager = event.stateManager;
        },
        onRowDoubleTap: (event) {
          final idx = event.rowIdx;
          if (idx >= 0 && idx < transfers.length) {
            _showTransferDetailDialog(
              context,
              transfers[idx],
              branches,
              branchAccounts,
              userNames,
              canManageTransfers,
            );
          }
        },
      ),
    );
  }

  Widget _buildMobileList(
    BuildContext context,
    List<Transfer> transfers,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: transfers.length,
      itemBuilder: (context, index) {
        final t = transfers[index];
        return _TransferCard(
          transfer: t,
          branches: branches,
          branchAccounts: branchAccounts,
          canManageTransfers: canManageTransfers,
          onEdit: t.isPending && canManageTransfers
              ? () => _showEditTransferDialog(context, t)
              : null,
          onConfirm: t.isPending
              ? () => _handleConfirmTransfer(context, t)
              : null,
          onReject: t.isPending
              ? () => context
                  .read<TransferBloc>()
                  .add(TransferRejectRequested(t.id, 'Отклонён'))
              : null,
          onIssue: t.isConfirmed
              ? () => context
                  .read<TransferBloc>()
                  .add(TransferIssueRequested(t.id))
              : null,
        );
      },
    );
  }

  Widget _buildLoadingSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: 8,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ShimmerLoading.listTile(),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    bool canManageTransfers, {
    bool hasActiveFilters = false,
    VoidCallback? onResetFilters,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 72,
              color: context.isDark
                  ? AppColors.darkTextTertiary
                  : AppColors.lightTextTertiary,
            ),
            SizedBox(height: AppSpacing.sectionGap),
            Text(
              hasActiveFilters ? 'Нет переводов по фильтрам' : 'Переводы пока отсутствуют',
              textAlign: TextAlign.center,
              style: context.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: context.isDark
                    ? AppColors.darkTextPrimary
                    : AppColors.lightTextPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hasActiveFilters
                  ? 'Сбросьте период, статус или филиал — возможно, записи скрыты фильтром.'
                  : 'Создайте первый перевод между филиалами или пополните счёт через «Пополнение филиала».',
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
              ),
            ),
            SizedBox(height: AppSpacing.sectionGap),
            if (hasActiveFilters && onResetFilters != null)
              OutlinedButton.icon(
                onPressed: onResetFilters,
                icon: const Icon(Icons.filter_alt_off_rounded, size: 20),
                label: const Text('Сбросить фильтры'),
              ),
            if (hasActiveFilters && onResetFilters != null) const SizedBox(height: AppSpacing.sm),
            if (canManageTransfers)
              FilledButton.icon(
                onPressed: () => context.goNamed(RouteNames.createTransfer),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xxl,
                    vertical: AppSpacing.md,
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 22),
                label: const Text('Создать перевод'),
              ),
          ],
        ),
      ),
    );
  }

  void _showEditTransferDialog(BuildContext context, Transfer t) {
    showDialog(
      context: context,
      builder: (ctx) => EditTransferDialog(
        transfer: t,
        onSaved: () => Navigator.of(ctx).pop(),
        allowAmountEdit: t.isPending,
      ),
    );
  }

  void _handleConfirmTransfer(BuildContext context, Transfer t) {
    if (t.toAccountId.isNotEmpty) {
      context.read<TransferBloc>().add(TransferConfirmRequested(t.id));
      return;
    }
    showAcceptTransferAccountDialog(context, t);
  }

  void _showTransferDetailDialog(
    BuildContext context,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
    bool canManageTransfers,
  ) {
    String branchName(String id) {
      final match = branches.where((b) => b.id == id);
      return match.isNotEmpty ? match.first.name : id;
    }

    String accountName(String id) {
      for (final list in branchAccounts.values) {
        final acc = list.where((a) => a.id == id).firstOrNull;
        if (acc != null) return acc.name;
      }
      return id;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.transactionCode ?? 'Перевод'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow('Филиал отправителя', branchName(t.fromBranchId)),
                if (t.senderName != null && t.senderName!.isNotEmpty)
                  _DetailRow('Имя отправителя', t.senderName!),
                if (t.senderPhone != null && t.senderPhone!.isNotEmpty)
                  _DetailRow('Телефон отправителя', t.senderPhone!),
                _DetailRow('Филиал получателя', branchName(t.toBranchId)),
                if (t.receiverName != null && t.receiverName!.isNotEmpty)
                  _DetailRow('Имя получателя', t.receiverName!),
                if (t.receiverPhone != null && t.receiverPhone!.isNotEmpty)
                  _DetailRow('Телефон получателя', t.receiverPhone!),
                _DetailRow('Счёт отправителя', accountName(t.fromAccountId)),
                if (t.description != null && t.description!.isNotEmpty)
                  _DetailRow('Назначение', t.description!),
                _DetailRow('Валюта отправителя', t.currency),
                _DetailRow('Валюта получателя', t.toCurrency ?? t.currency),
                _DetailRow('Списание с отправителя', '${t.totalDebitAmount.formatCurrencyNoDecimals()} ${t.currency}'),
              _DetailRow('Получатель получит', '${(t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted).formatCurrencyNoDecimals()} ${t.toCurrency ?? t.currency}'),
              if (t.commission > 0)
                  _DetailRow('Комиссия', '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}'),
                if (t.senderInfo != null && t.senderInfo!.isNotEmpty)
                  _DetailRow('Карта отправителя', t.senderInfo!),
                if (t.receiverInfo != null && t.receiverInfo!.isNotEmpty)
                  _DetailRow('Карта получателя', t.receiverInfo!),
                if ((t.toCurrency ?? t.currency) != t.currency)
                  _DetailRow('Курс ${t.currency} → ${t.toCurrency ?? t.currency}', t.exchangeRate.toString()),
                _DetailRow('Статус', t.status.displayName),
                _DetailRow('Создал', _userDisplay(userNames, t.createdBy)),
                if (t.confirmedBy != null)
                  _DetailRow('Принял', _userDisplay(userNames, t.confirmedBy!)),
                if (t.issuedBy != null)
                  _DetailRow('Выдал', userNames[t.issuedBy!] ?? t.issuedBy!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
          if (canManageTransfers)
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _showEditTransferDialog(context, t);
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Изменить'),
            ),
          if (t.isPending) ...[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                context.read<TransferBloc>().add(TransferRejectRequested(t.id, 'Отклонён'));
              },
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
              child: const Text('Отклонить'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _handleConfirmTransfer(context, t);
              },
              child: const Text('Принять'),
            ),
          ],
          if (t.isConfirmed) ...[
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                context.read<TransferBloc>().add(TransferIssueRequested(t.id));
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text('Выдать'),
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _onExport() async {
    if (_isExporting) return;
    final settings = await showDialog<ExportSettings>(
      context: context,
      builder: (ctx) => ExportDialog(
        title: 'Настройки экспорта переводов',
        columns: ExportColumnPresets.transfers,
      ),
    );
    if (settings == null || !mounted) return;
    setState(() => _isExporting = true);
    try {
      final url = await _exportService.exportTransfers(
        branchId: _branchFilter,
        startDate: _dateRange?.start,
        endDate: _dateRange?.end,
        exportSettings: settings,
      );
      if (!mounted) return;
      final period = _dateRange != null
          ? ' ${_dateRange!.start.day.toString().padLeft(2, '0')}.${_dateRange!.start.month.toString().padLeft(2, '0')}–${_dateRange!.end.day.toString().padLeft(2, '0')}.${_dateRange!.end.month.toString().padLeft(2, '0')}.${_dateRange!.end.year}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            url != null
                ? 'Скачан: История переводов$period (Excel)'
                : 'Нет данных для экспорта переводов.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка экспорта: $e')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.branches,
    this.branchAccounts = const {},
    this.canManageTransfers = false,
    this.onEdit,
    this.onConfirm,
    this.onReject,
    this.onIssue,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final bool canManageTransfers;
  final VoidCallback? onEdit;
  final VoidCallback? onConfirm;
  final VoidCallback? onReject;
  final VoidCallback? onIssue;

  String _branchName(String id) {
    final match = branches.where((b) => b.id == id);
    return match.isNotEmpty ? match.first.name : id.substring(0, 8);
  }

  String _accountName(String id) {
    for (final list in branchAccounts.values) {
      final acc = list.where((a) => a.id == id).firstOrNull;
      if (acc != null) return acc.name;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final t = transfer;
    final sentCur = t.currency;
    final recvCur = t.toCurrency ?? t.currency;
    final isCrossCurrency = sentCur != recvCur;

    final (statusColor, statusLabel) = switch (t.status) {
      TransferStatus.pending => (AppColors.warning, 'Ожидание'),
      TransferStatus.confirmed => (AppColors.success, 'Принят'),
      TransferStatus.issued => (Colors.teal, 'Выдан'),
      TransferStatus.rejected => (AppColors.error, 'Отклонён'),
      TransferStatus.cancelled => (Colors.grey, 'Отменён'),
    };

    final secondaryColor =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    final isMobile = !context.isDesktop;
    return Card(
      elevation: 0,
      margin: EdgeInsets.only(bottom: AppSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(isMobile ? AppSpacing.lg : AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: route + status
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_branchName(t.fromBranchId)} → ${_branchName(t.toBranchId)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Transaction code + account
            if (t.transactionCode != null)
              Text(
                t.transactionCode!,
                style: TextStyle(
                  fontSize: 11,
                  color: secondaryColor,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            if (t.senderName != null && t.senderName!.isNotEmpty)
              Text(
                'Отправитель: ${t.senderName}${t.senderPhone != null && t.senderPhone!.isNotEmpty ? ' • ${t.senderPhone}' : ''}',
                style: TextStyle(fontSize: 11, color: secondaryColor),
              ),
            if (t.receiverName != null && t.receiverName!.isNotEmpty)
              Text(
                'Получатель: ${t.receiverName}${t.receiverPhone != null && t.receiverPhone!.isNotEmpty ? ' • ${t.receiverPhone}' : ''}',
                style: TextStyle(fontSize: 11, color: secondaryColor),
              ),
            Text(
              'Счёт: ${_accountName(t.fromAccountId)}',
              style: TextStyle(fontSize: 11, color: secondaryColor),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Sent → Received amounts
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  // Sent
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Отдали',
                          style: TextStyle(fontSize: 10, color: secondaryColor, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${t.totalDebitAmount.formatCurrencyNoDecimals()} $sentCur',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrains Mono',
                            color: Color(0xFFE53935),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Arrow + rate
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      children: [
                        const Icon(Icons.arrow_forward_rounded, size: 18),
                        if (isCrossCurrency)
                          Text(
                            '×${t.exchangeRate}',
                            style: TextStyle(fontSize: 9, color: secondaryColor),
                          ),
                      ],
                    ),
                  ),
                  // Received
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Получат',
                          style: TextStyle(fontSize: 10, color: secondaryColor, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted).formatCurrencyNoDecimals()} $recvCur',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrains Mono',
                            color: Color(0xFF43A047),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Commission + date
            const SizedBox(height: 6),
            Row(
              children: [
                if (t.commission > 0)
                  Text(
                    'Комиссия: ${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                    style: TextStyle(fontSize: 11, color: secondaryColor),
                  ),
                const Spacer(),
                Text(
                  t.createdAt.historyFormatted,
                  style: TextStyle(fontSize: 11, color: secondaryColor),
                ),
              ],
            ),

            // Edit / Confirm / Reject / Issue actions
            if ((t.isPending && (onEdit != null || onConfirm != null || onReject != null)) ||
                (t.isConfirmed && onIssue != null)) ...[
              SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (t.isPending && onEdit != null)
                    OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Изменить'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  if (t.isPending && onReject != null)
                    TextButton(
                      onPressed: onReject,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.error,
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('Отклонить'),
                    ),
                  if (t.isPending && onConfirm != null)
                    FilledButton(
                      onPressed: onConfirm,
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      child: const Text('Принять'),
                    ),
                  if (t.isConfirmed && onIssue != null)
                    FilledButton.icon(
                      onPressed: onIssue,
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('Выдать'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal,
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
