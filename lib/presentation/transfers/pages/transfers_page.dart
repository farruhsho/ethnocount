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
import 'package:ethnocount/domain/entities/transfer_issuance.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/domain/services/transfer_invoice_service.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/desktop_data_grid.dart';
import 'package:ethnocount/presentation/common/widgets/filter_panel.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';
import 'package:ethnocount/presentation/common/widgets/responsive_sheet.dart';
import 'package:ethnocount/presentation/common/widgets/export_dialog.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
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
  final _invoiceService = sl<TransferInvoiceService>();
  bool _isExporting = false;
  bool _isInvoiceSaving = false;
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

    final isMobile = !context.isDesktop;

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
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: isMobile && canManageTransfers
            ? FloatingActionButton.extended(
                onPressed: () => context.goNamed(RouteNames.createTransfer),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Новый перевод'),
              )
            : null,
        body: Column(
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
    ),
    );
  }

  Widget _buildHeader(BuildContext context, bool canManageTransfers, bool canBranchTopUp) {
    final isMobile = !context.isDesktop;

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Переводы',
                style: context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Принятые',
              onPressed: () => context.goNamed(RouteNames.acceptedTransfers),
              icon: const Icon(Icons.check_circle_outline),
            ),
            if (canBranchTopUp)
              IconButton(
                tooltip: 'Пополнение филиала',
                onPressed: () => context.go('/transfers/topup'),
                icon: const Icon(Icons.add_business_rounded),
              ),
            if (canManageTransfers)
              IconButton(
                tooltip: 'Управление переводами',
                onPressed: () => context.go('/transfers/manage'),
                icon: const Icon(Icons.inbox_rounded),
              ),
          ],
        ),
      );
    }

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
    return RefreshIndicator(
      onRefresh: () async => _loadTransfers(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.sm,
          80, // extra space so FAB never hides the last card
        ),
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
            onDetails: () => _showTransferDetailSheet(
              context,
              t,
              branches,
              branchAccounts,
              canManageTransfers,
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: 8,
      itemBuilder: (context, index) => Padding(
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
    if (hasActiveFilters && onResetFilters != null) {
      return EmptyState(
        icon: Icons.filter_alt_off_rounded,
        title: 'Нет переводов по фильтрам',
        subtitle:
            'Сбросьте период, статус или филиал — возможно, записи скрыты фильтром.',
        actionLabel: 'Сбросить фильтры',
        actionIcon: Icons.filter_alt_off_rounded,
        onAction: onResetFilters,
      );
    }
    return EmptyState(
      icon: Icons.inbox_outlined,
      title: 'Переводы пока отсутствуют',
      subtitle:
          'Создайте первый перевод между филиалами или пополните счёт через «Пополнение филиала».',
      actionLabel: canManageTransfers ? 'Создать перевод' : null,
      actionIcon: Icons.add_rounded,
      onAction: canManageTransfers
          ? () => context.goNamed(RouteNames.createTransfer)
          : null,
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

  void _showTransferDetailSheet(
    BuildContext context,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers,
  ) {
    // Mobile flow doesn't have eager user names — try the cached user list
    // from UserRemoteDataSource.watchUsers() so signatures aren't blank.
    showResponsiveSheet<void>(
      context: context,
      builder: (ctx) {
        final transferBloc = context.read<TransferBloc>();
        return BlocProvider.value(
          value: transferBloc,
          child: StreamBuilder<List<AppUser>>(
            stream: sl<UserRemoteDataSource>().watchUsers(),
            builder: (innerCtx, snap) {
              final userNames = <String, String>{};
              for (final u in snap.data ?? const <AppUser>[]) {
                userNames[u.id] = u.displayName.isNotEmpty
                    ? u.displayName
                    : (u.email.isNotEmpty ? u.email : '—');
              }
              return _TransferDetailContent(
                transfer: t,
                branches: branches,
                branchAccounts: branchAccounts,
                userNames: userNames,
                canManageTransfers: canManageTransfers,
                onEdit: () {
                  Navigator.of(innerCtx).pop();
                  _showEditTransferDialog(context, t);
                },
                onConfirm: () {
                  Navigator.of(innerCtx).pop();
                  _handleConfirmTransfer(context, t);
                },
                onReject: () {
                  Navigator.of(innerCtx).pop();
                  context
                      .read<TransferBloc>()
                      .add(TransferRejectRequested(t.id, 'Отклонён'));
                },
                onIssueAll: () {
                  Navigator.of(innerCtx).pop();
                  context.read<TransferBloc>().add(TransferIssueRequested(t.id));
                },
                onIssuePartial: () async {
                  final result = await _showPartialIssueDialog(innerCtx, t);
                  if (result != null && context.mounted) {
                    Navigator.of(innerCtx).pop();
                    context.read<TransferBloc>().add(TransferIssuePartialRequested(
                          transferId: t.id,
                          amount: result.amount,
                          note: result.note,
                        ));
                  }
                },
                onClose: () => Navigator.of(innerCtx).pop(),
                onDownloadInvoice: () => _handleDownloadInvoice(
                  innerCtx,
                  t,
                  branches,
                  branchAccounts,
                  userNames,
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showTransferDetailDialog(
    BuildContext context,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
    bool canManageTransfers,
  ) {
    final transferBloc = context.read<TransferBloc>();

    showResponsiveSheet<void>(
      context: context,
      builder: (ctx) {
        final content = _TransferDetailContent(
          transfer: t,
          branches: branches,
          branchAccounts: branchAccounts,
          userNames: userNames,
          canManageTransfers: canManageTransfers,
          onEdit: () {
            Navigator.of(ctx).pop();
            _showEditTransferDialog(context, t);
          },
          onConfirm: () {
            Navigator.of(ctx).pop();
            _handleConfirmTransfer(context, t);
          },
          onReject: () {
            Navigator.of(ctx).pop();
            context
                .read<TransferBloc>()
                .add(TransferRejectRequested(t.id, 'Отклонён'));
          },
          onIssueAll: () {
            Navigator.of(ctx).pop();
            context.read<TransferBloc>().add(TransferIssueRequested(t.id));
          },
          onIssuePartial: () async {
            final result = await _showPartialIssueDialog(ctx, t);
            if (result != null && context.mounted) {
              Navigator.of(ctx).pop();
              context.read<TransferBloc>().add(TransferIssuePartialRequested(
                    transferId: t.id,
                    amount: result.amount,
                    note: result.note,
                  ));
            }
          },
          onClose: () => Navigator.of(ctx).pop(),
          onDownloadInvoice: () => _handleDownloadInvoice(
            ctx,
            t,
            branches,
            branchAccounts,
            userNames,
          ),
        );
        return BlocProvider.value(
          value: transferBloc,
          child: content,
        );
      },
    );
  }

  Future<_PartialIssueResult?> _showPartialIssueDialog(
    BuildContext sheetContext,
    Transfer t,
  ) async {
    final repo = sl<TransferRepository>();
    // Refresh transfer just before showing the dialog so the remaining
    // amount reflects any tranches issued by other users since this list
    // was fetched.
    final fresh = await repo.getTransfer(t.id);
    final actual = fresh.fold((_) => t, (loaded) => loaded);
    if (!mounted) return null;
    if (!sheetContext.mounted) return null;
    final cur = actual.toCurrency ?? actual.currency;
    final remaining = actual.remainingToIssue;
    if (remaining <= 0) {
      ScaffoldMessenger.of(sheetContext).showSnackBar(
        const SnackBar(content: Text('Нет остатка к выдаче.')),
      );
      return null;
    }
    return showDialog<_PartialIssueResult>(
      context: sheetContext,
      barrierDismissible: false,
      builder: (_) => _PartialIssueDialog(
        transactionCode: actual.transactionCode ?? actual.id.substring(0, 8),
        remaining: remaining,
        currency: cur,
        alreadyIssued: actual.issuedAmount,
        totalAmount: actual.convertedAmount,
      ),
    );
  }

  Future<void> _handleDownloadInvoice(
    BuildContext sheetContext,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
  ) async {
    if (_isInvoiceSaving) return;
    setState(() => _isInvoiceSaving = true);

    final branchNames = <String, String>{
      for (final b in branches) b.id: b.name,
    };
    final accountNames = <String, String>{
      for (final list in branchAccounts.values)
        for (final a in list) a.id: a.name,
    };

    final messenger = ScaffoldMessenger.of(context);

    // Pull the latest payout tranches so the invoice carries up-to-date
    // history. Soft-fail to an empty list — the invoice still renders.
    List<TransferIssuance> issuances = const [];
    if (t.issuedAmount > 0 || t.isIssued) {
      try {
        issuances =
            await sl<TransferRemoteDataSource>().fetchIssuances(t.id);
      } catch (_) {/* ignore */}
    }

    try {
      final ok = await _invoiceService.exportInvoice(
        t,
        branchNames: branchNames,
        accountNames: accountNames,
        userNames: userNames,
        issuances: issuances,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'Инвойс ${t.transactionCode ?? ''} сохранён (Word)'
              : 'Не удалось сформировать инвойс.'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Ошибка инвойса: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isInvoiceSaving = false);
    }
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
    this.onDetails,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final bool canManageTransfers;
  final VoidCallback? onEdit;
  final VoidCallback? onConfirm;
  final VoidCallback? onReject;
  final VoidCallback? onDetails;

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
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onDetails,
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
                  fontSize: 12,
                  color: secondaryColor,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            if (t.senderName != null && t.senderName!.isNotEmpty)
              Text(
                'Отправитель: ${t.senderName}${t.senderPhone != null && t.senderPhone!.isNotEmpty ? ' • ${t.senderPhone}' : ''}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (t.receiverName != null && t.receiverName!.isNotEmpty)
              Text(
                'Получатель: ${t.receiverName}${t.receiverPhone != null && t.receiverPhone!.isNotEmpty ? ' • ${t.receiverPhone}' : ''}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              'Счёт: ${_accountName(t.fromAccountId)}',
              style: TextStyle(fontSize: 12, color: secondaryColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
                          style: TextStyle(fontSize: 11, color: secondaryColor, fontWeight: FontWeight.w500),
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
                            style: TextStyle(fontSize: 10, color: secondaryColor),
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
                          style: TextStyle(fontSize: 11, color: secondaryColor, fontWeight: FontWeight.w500),
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

            // Partial issuance progress (compact bar) — only for confirmed
            // transfers with at least one tranche issued. Keeps the card
            // glanceable while still flagging incomplete payouts.
            if (t.isConfirmed && t.issuedAmount > 0) ...[
              const SizedBox(height: 8),
              _CardPayoutProgress(transfer: t),
            ],

            // Commission + date
            const SizedBox(height: 6),
            Row(
              children: [
                if (t.commission > 0)
                  Flexible(
                    child: Text(
                      'Комиссия: ${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const Spacer(),
                Text(
                  t.createdAt.historyFormatted,
                  style: TextStyle(fontSize: 12, color: secondaryColor),
                ),
              ],
            ),

            // Edit / Confirm / Reject actions. Issuance (partial or full)
            // is intentionally surfaced only inside the detail dialog so the
            // operator sees remaining balance and history before paying out.
            if (t.isPending && (onEdit != null || onConfirm != null || onReject != null)) ...[
              SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (onEdit != null)
                    OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Изменить'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  if (onReject != null)
                    TextButton(
                      onPressed: onReject,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.error,
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text('Отклонить'),
                    ),
                  if (onConfirm != null)
                    FilledButton(
                      onPressed: onConfirm,
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                      child: const Text('Принять'),
                    ),
                ],
              ),
            ],
            if (t.isConfirmed) ...[
              SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onDetails,
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: Text(t.isPartiallyIssued
                      ? 'Продолжить выдачу'
                      : 'Открыть для выдачи'),
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.teal,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

// ─── Detail dialog content ─────────────────────────────────────────────
//
// Single source of truth for the per-transfer detail UI. Renders:
//   • header (transaction code, status badge)
//   • parties (откуда / куда: филиал, счёт, имя, телефон, реквизиты)
//   • split-currency parts table (when present)
//   • accounting figures: списание / получит / комиссия / курс
//   • signatures (создал / принял / выдал / отклонил / отменил)
//   • amendment history (правки до подтверждения)
//   • actions: Скачать инвойс (Word), [Изменить], [Отклонить], [Принять], [Выдать]

class _TransferDetailContent extends StatelessWidget {
  const _TransferDetailContent({
    required this.transfer,
    required this.branches,
    required this.branchAccounts,
    required this.userNames,
    required this.canManageTransfers,
    required this.onEdit,
    required this.onConfirm,
    required this.onReject,
    required this.onIssueAll,
    required this.onIssuePartial,
    required this.onClose,
    required this.onDownloadInvoice,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final Map<String, String> userNames;
  final bool canManageTransfers;
  final VoidCallback onEdit;
  final VoidCallback onConfirm;
  final VoidCallback onReject;
  final VoidCallback onIssueAll;
  final VoidCallback onIssuePartial;
  final VoidCallback onClose;
  final VoidCallback onDownloadInvoice;

  String _branchName(String id) {
    final match = branches.where((b) => b.id == id);
    return match.isNotEmpty ? match.first.name : id;
  }

  String _accountName(String id) {
    if (id.isEmpty) return '—';
    for (final list in branchAccounts.values) {
      final acc = list.where((a) => a.id == id).firstOrNull;
      if (acc != null) return acc.name;
    }
    return id;
  }

  String _userDisplay(String? id) {
    if (id == null || id.isEmpty) return '—';
    final n = userNames[id];
    if (n != null && n.isNotEmpty) return n;
    return id.length >= 8 ? id.substring(0, 8) : id;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final body = _buildBody(context);
    final actions = _buildActions(context);
    final title = transfer.transactionCode ?? 'Перевод';

    if (isDesktop) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title bar
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: context.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Body
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                  child: body,
                ),
              ),
              // Actions
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: context.isDark
                          ? AppColors.darkBorder
                          : AppColors.lightBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ResponsiveSheetScaffold(
      title: title,
      trailing: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: onClose,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: actions,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final t = transfer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusHeader(transfer: t),
        const SizedBox(height: AppSpacing.md),
        _PartiesBlock(
          fromBranch: _branchName(t.fromBranchId),
          fromAccount: _accountName(t.fromAccountId),
          toBranch: _branchName(t.toBranchId),
          toAccount: _accountName(t.toAccountId),
          transfer: t,
        ),
        const SizedBox(height: AppSpacing.md),
        if (t.isSplitCurrency) ...[
          _SplitPartsBlock(
            transfer: t,
            accountNameResolver: _accountName,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _AmountsBlock(transfer: t),
        if (t.isConfirmed || t.isIssued || t.issuedAmount > 0) ...[
          const SizedBox(height: AppSpacing.md),
          _PayoutProgressBlock(
            transfer: t,
            userResolver: _userDisplay,
          ),
        ],
        if (t.commission > 0) ...[
          const SizedBox(height: AppSpacing.md),
          _CommissionBlock(transfer: t),
        ],
        if (t.description != null && t.description!.trim().isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            title: 'Назначение платежа',
            child: Text(
              t.description!.trim(),
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _SignaturesBlock(
          transfer: t,
          userResolver: _userDisplay,
        ),
        if (t.amendmentHistory.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _AmendmentsBlock(
            transfer: t,
            userResolver: _userDisplay,
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    final t = transfer;
    return [
      OutlinedButton.icon(
        onPressed: onDownloadInvoice,
        icon: const Icon(Icons.description_outlined, size: 18),
        label: const Text('Скачать инвойс'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
      if (canManageTransfers && t.isPending)
        OutlinedButton.icon(
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Изменить'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        ),
      if (t.isPending) ...[
        TextButton(
          onPressed: onReject,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.error,
            minimumSize: const Size(0, 44),
          ),
          child: const Text('Отклонить'),
        ),
        FilledButton(
          onPressed: onConfirm,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Принять'),
        ),
      ],
      if (t.isConfirmed) ...[
        OutlinedButton.icon(
          onPressed: onIssuePartial,
          icon: const Icon(Icons.payments_outlined, size: 18),
          label: const Text('Выдать частично'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.teal,
            side: const BorderSide(color: Colors.teal),
            minimumSize: const Size(0, 44),
          ),
        ),
        FilledButton.icon(
          onPressed: onIssueAll,
          icon: const Icon(Icons.check_circle_outline, size: 18),
          label: Text(t.isPartiallyIssued
              ? 'Выдать остаток'
              : 'Выдать всё'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.teal,
            minimumSize: const Size(0, 44),
          ),
        ),
      ],
    ];
  }
}

/// Card-shaped section with optional title.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.padding});

  final String title;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: context.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final (statusColor, statusLabel) = switch (t.status) {
      TransferStatus.pending => (AppColors.warning, 'Ожидание'),
      TransferStatus.confirmed => (AppColors.success, 'Принят'),
      TransferStatus.issued => (Colors.teal, 'Выдан'),
      TransferStatus.rejected => (AppColors.error, 'Отклонён'),
      TransferStatus.cancelled => (Colors.grey, 'Отменён'),
    };
    final secondaryColor = context.isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (t.transactionCode != null && t.transactionCode!.isNotEmpty)
                Text(
                  t.transactionCode!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrains Mono',
                    color: secondaryColor,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                'Создан: ${t.createdAt.fullFormatted}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            statusLabel,
            style: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _PartiesBlock extends StatelessWidget {
  const _PartiesBlock({
    required this.fromBranch,
    required this.fromAccount,
    required this.toBranch,
    required this.toAccount,
    required this.transfer,
  });

  final String fromBranch;
  final String fromAccount;
  final String toBranch;
  final String toAccount;
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isMobile = !context.isDesktop;
    final from = _PartyCard(
      title: 'Отправитель',
      branch: fromBranch,
      account: fromAccount,
      name: t.senderName,
      phone: t.senderPhone,
      info: t.senderInfo,
      icon: Icons.north_east_rounded,
      accentColor: const Color(0xFFE53935),
    );
    final to = _PartyCard(
      title: 'Получатель',
      branch: toBranch,
      account: toAccount.isNotEmpty ? toAccount : null,
      name: t.receiverName,
      phone: t.receiverPhone,
      info: t.receiverInfo,
      icon: Icons.south_west_rounded,
      accentColor: const Color(0xFF43A047),
    );

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          from,
          const SizedBox(height: AppSpacing.sm),
          to,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: from),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: to),
      ],
    );
  }
}

class _PartyCard extends StatelessWidget {
  const _PartyCard({
    required this.title,
    required this.branch,
    this.account,
    this.name,
    this.phone,
    this.info,
    required this.icon,
    required this.accentColor,
  });

  final String title;
  final String branch;
  final String? account;
  final String? name;
  final String? phone;
  final String? info;
  final IconData icon;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    Widget kv(String label, String? value) {
      final v = (value ?? '').trim();
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 12, height: 1.35),
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(color: secondary),
              ),
              TextSpan(
                text: v,
                style: TextStyle(
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: accentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            branch,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          kv('Счёт', account),
          kv('Имя', name),
          kv('Телефон', phone),
          kv('Реквизиты', info),
        ],
      ),
    );
  }
}

class _SplitPartsBlock extends StatelessWidget {
  const _SplitPartsBlock({
    required this.transfer,
    required this.accountNameResolver,
  });

  final Transfer transfer;
  final String Function(String) accountNameResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final parts = t.transferParts ?? const [];
    if (parts.isEmpty) return const SizedBox.shrink();

    final isDark = context.isDark;
    final headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      color: isDark
          ? AppColors.darkTextSecondary
          : AppColors.lightTextSecondary,
    );

    // Per-currency totals (e.g. 500 USD + 30 000 RUB)
    final byCurrency = <String, double>{};
    for (final p in parts) {
      byCurrency[p.currency] = (byCurrency[p.currency] ?? 0) + p.amount;
    }

    return _SectionCard(
      title: 'Разделение по счетам отправителя',
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('Счёт', style: headerStyle)),
                Expanded(flex: 3,
                    child: Text('Сумма', style: headerStyle, textAlign: TextAlign.right)),
                Expanded(flex: 2,
                    child: Text('Валюта', style: headerStyle, textAlign: TextAlign.center)),
              ],
            ),
          ),
          const Divider(height: 1),
          // Parts
          ...parts.map((p) {
            final accName = p.accountName.isNotEmpty
                ? p.accountName
                : accountNameResolver(p.accountId);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Text(
                      accName,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      p.amount.formatCurrencyNoDecimals(),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      p.currency,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  'Итого:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                  ),
                ),
                ...byCurrency.entries.map((e) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${e.value.formatCurrencyNoDecimals()} ${e.key}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountsBlock extends StatelessWidget {
  const _AmountsBlock({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final recvCur = t.toCurrency ?? t.currency;
    final isCross = recvCur != t.currency;
    final receiverAmount = t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;

    Widget metric(String label, String value, {Color? color}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: secondary, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFamily: 'JetBrains Mono',
              color: color,
            ),
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'Сумма перевода',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: metric(
                  'Списание (Дебет)',
                  '${t.totalDebitAmount.formatCurrencyNoDecimals()} ${t.currency}',
                  color: const Color(0xFFE53935),
                ),
              ),
              if (isCross)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      const Icon(Icons.swap_horiz_rounded, size: 18),
                      Text(
                        '×${t.exchangeRate}',
                        style: TextStyle(fontSize: 10, color: secondary),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: metric(
                    'Получит (Кредит)',
                    '${receiverAmount.formatCurrencyNoDecimals()} $recvCur',
                    color: const Color(0xFF43A047),
                  ),
                ),
              ),
            ],
          ),
          if (isCross) ...[
            const SizedBox(height: 8),
            Text(
              'Курс ${t.currency} → $recvCur: ${t.exchangeRate}    •    Конвертированная сумма: ${t.convertedAmount.formatCurrencyNoDecimals()} $recvCur',
              style: TextStyle(fontSize: 11, color: secondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommissionBlock extends StatelessWidget {
  const _CommissionBlock({required this.transfer});
  final Transfer transfer;

  String _modeLabel(CommissionMode m) {
    switch (m) {
      case CommissionMode.fromSender:
        return 'Отдельно с отправителя';
      case CommissionMode.fromTransfer:
        return 'Внутри суммы перевода';
      case CommissionMode.toReceiver:
        return 'Сверх суммы (получателю)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return _SectionCard(
      title: 'Комиссия',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const SizedBox(width: 10),
              if (t.commissionType == CommissionType.percentage)
                _Pill(label: '${t.commissionValue}%', color: AppColors.warning)
              else
                const _Pill(label: 'Фикс.', color: Colors.blueGrey),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Режим: ${_modeLabel(t.commissionMode)}',
            style: TextStyle(fontSize: 12, color: secondary),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SignaturesBlock extends StatelessWidget {
  const _SignaturesBlock({required this.transfer, required this.userResolver});
  final Transfer transfer;
  final String Function(String?) userResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final rows = <(String, String, IconData, Color)>[];
    rows.add((
      'Создал',
      '${userResolver(t.createdBy)} • ${t.createdAt.historyFormatted}',
      Icons.add_box_outlined,
      Colors.blueGrey,
    ));
    if (t.confirmedAt != null) {
      rows.add((
        'Принял',
        '${userResolver(t.confirmedBy)} • ${t.confirmedAt!.historyFormatted}',
        Icons.check_circle_outline,
        AppColors.success,
      ));
    }
    if (t.issuedAt != null) {
      rows.add((
        'Выдал',
        '${userResolver(t.issuedBy)} • ${t.issuedAt!.historyFormatted}',
        Icons.payments_outlined,
        Colors.teal,
      ));
    }
    if (t.rejectedAt != null) {
      final reason = (t.rejectionReason != null && t.rejectionReason!.trim().isNotEmpty)
          ? '\nПричина: ${t.rejectionReason!.trim()}'
          : '';
      rows.add((
        'Отклонил',
        '${userResolver(t.rejectedBy)} • ${t.rejectedAt!.historyFormatted}$reason',
        Icons.cancel_outlined,
        AppColors.error,
      ));
    }
    if (t.cancelledAt != null) {
      final reason = (t.cancellationReason != null && t.cancellationReason!.trim().isNotEmpty)
          ? '\nПричина: ${t.cancellationReason!.trim()}'
          : '';
      rows.add((
        'Отменил',
        '${userResolver(t.cancelledBy)} • ${t.cancelledAt!.historyFormatted}$reason',
        Icons.block_outlined,
        Colors.grey,
      ));
    }

    return _SectionCard(
      title: 'Подписи и операции',
      child: Column(
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(r.$3, size: 16, color: r.$4),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: Text(
                      r.$1,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r.$2,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Progress + history block for partial issuance. Pulls tranches from
/// `transfer_issuances` via the repository realtime stream so the list
/// updates instantly when another user issues a tranche.
class _PayoutProgressBlock extends StatelessWidget {
  const _PayoutProgressBlock({
    required this.transfer,
    required this.userResolver,
  });

  final Transfer transfer;
  final String Function(String?) userResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final cur = t.toCurrency ?? t.currency;
    final total = t.convertedAmount;
    final issued = t.issuedAmount;
    final remaining = (total - issued).clamp(0.0, double.infinity);
    final progress = total > 0 ? (issued / total).clamp(0.0, 1.0) : 0.0;

    String label;
    Color barColor;
    if (t.isIssued) {
      label = 'Полностью выдано';
      barColor = Colors.teal;
    } else if (issued > 0) {
      label = 'Частично выдано';
      barColor = AppColors.warning;
    } else {
      label = 'Ожидает выдачи';
      barColor = AppColors.success;
    }

    return _SectionCard(
      title: 'Выдача получателю',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$label: ${issued.formatCurrencyNoDecimals()} / ${total.formatCurrencyNoDecimals()} $cur',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: barColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor:
                  (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          if (remaining > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Остаток к выдаче: ${remaining.formatCurrencyNoDecimals()} $cur',
              style: TextStyle(fontSize: 12, color: secondary),
            ),
          ],
          const SizedBox(height: 12),
          StreamBuilder<List<TransferIssuance>>(
            stream: sl<TransferRepository>().watchIssuances(t.id),
            builder: (ctx, snap) {
              final list = snap.data ?? const <TransferIssuance>[];
              if (list.isEmpty) {
                return Text(
                  snap.connectionState == ConnectionState.waiting
                      ? 'Загрузка истории выдач…'
                      : 'Выдач ещё не было.',
                  style: TextStyle(fontSize: 12, color: secondary),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'История выдач (${list.length})',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: secondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (var i = 0; i < list.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.teal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.teal,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${list[i].amount.formatCurrencyNoDecimals()} ${list[i].currency}'
                                  '   •   ${list[i].issuedAt.historyFormatted}'
                                  '   •   ${userResolver(list[i].issuedBy)}',
                                  style: const TextStyle(fontSize: 12, height: 1.35),
                                ),
                                if (list[i].note != null && list[i].note!.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      list[i].note!.trim(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: secondary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AmendmentsBlock extends StatelessWidget {
  const _AmendmentsBlock({required this.transfer, required this.userResolver});
  final Transfer transfer;
  final String Function(String?) userResolver;

  String _formatChange(MapEntry<String, dynamic> e) {
    final v = e.value;
    if (v is Map) {
      final from = v['from']?.toString() ?? '—';
      final to = v['to']?.toString() ?? '—';
      return '${e.key}: $from → $to';
    }
    return '${e.key}: $v';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return _SectionCard(
      title: 'История изменений',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in transfer.amendmentHistory)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: AppColors.warning,
                      width: 3,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${userResolver(e.userId)} • ${e.at.historyFormatted}',
                      style: TextStyle(
                        fontSize: 11,
                        color: secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (e.changes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      ...e.changes.entries.map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _formatChange(c),
                            style: const TextStyle(
                                fontSize: 12, height: 1.35),
                          ),
                        ),
                      ),
                    ],
                    if (e.note != null && e.note!.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Прим.: ${e.note!.trim()}',
                        style: TextStyle(
                            fontSize: 12, color: secondary, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact payout progress shown inside a transfer card on the list view.
/// Designed to stay glanceable when there are thousands of transfers per day.
class _CardPayoutProgress extends StatelessWidget {
  const _CardPayoutProgress({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final cur = t.toCurrency ?? t.currency;
    final total = t.convertedAmount;
    final issued = t.issuedAmount;
    final remaining = (total - issued).clamp(0.0, double.infinity);
    final progress = total > 0 ? (issued / total).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.payments_outlined, size: 14, color: Colors.teal),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Выдано ${issued.formatCurrencyNoDecimals()} / ${total.formatCurrencyNoDecimals()} $cur',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${(progress * 100).toStringAsFixed(0)}%   •   ост. ${remaining.formatCurrencyNoDecimals()} $cur',
              style: TextStyle(fontSize: 11, color: secondary),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor:
                (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
            valueColor: AlwaysStoppedAnimation(
              progress >= 1 ? Colors.teal : AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }
}

/// Result of a partial-issue dialog: the amount entered and an optional note.
class _PartialIssueResult {
  final double amount;
  final String? note;
  const _PartialIssueResult(this.amount, this.note);
}

class _PartialIssueDialog extends StatefulWidget {
  const _PartialIssueDialog({
    required this.transactionCode,
    required this.remaining,
    required this.currency,
    required this.alreadyIssued,
    required this.totalAmount,
  });

  final String transactionCode;
  final double remaining;
  final String currency;
  final double alreadyIssued;
  final double totalAmount;

  @override
  State<_PartialIssueDialog> createState() => _PartialIssueDialogState();
}

class _PartialIssueDialogState extends State<_PartialIssueDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _submitting = false;

  void _quickAmount(double v) {
    _amountCtrl.text = v.toStringAsFixed(2);
    _formKey.currentState?.validate();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.currency;
    final remaining = widget.remaining;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.payments_outlined, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(child: Text('Выдача ${widget.transactionCode}')),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Сумма перевода: ${widget.totalAmount.formatCurrencyNoDecimals()} $cur',
                        style: const TextStyle(fontSize: 12)),
                    Text('Уже выдано: ${widget.alreadyIssued.formatCurrencyNoDecimals()} $cur',
                        style: const TextStyle(fontSize: 12)),
                    Text(
                      'К выдаче: ${remaining.formatCurrencyNoDecimals()} $cur',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Сумма выдачи *',
                  border: const OutlineInputBorder(),
                  suffixText: cur,
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Введите сумму';
                  final parsed = double.tryParse(v.replaceAll(',', '.').trim());
                  if (parsed == null) return 'Некорректная сумма';
                  if (parsed <= 0) return 'Сумма должна быть больше нуля';
                  if (parsed > remaining + 1e-6) {
                    return 'Не больше ${remaining.formatCurrencyNoDecimals()} $cur';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _QuickChip(
                    label: '25%',
                    onTap: () => _quickAmount(remaining * 0.25),
                  ),
                  _QuickChip(
                    label: '50%',
                    onTap: () => _quickAmount(remaining * 0.5),
                  ),
                  _QuickChip(
                    label: '75%',
                    onTap: () => _quickAmount(remaining * 0.75),
                  ),
                  _QuickChip(
                    label: 'Весь остаток',
                    primary: true,
                    onTap: () => _quickAmount(remaining),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _noteCtrl,
                decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)',
                  border: OutlineInputBorder(),
                  hintText: 'Например: первая часть, наличными',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(null),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _submitting
              ? null
              : () {
                  if (!_formKey.currentState!.validate()) return;
                  setState(() => _submitting = true);
                  final amount = double.parse(
                      _amountCtrl.text.replaceAll(',', '.').trim());
                  final note = _noteCtrl.text.trim();
                  Navigator.of(context).pop(_PartialIssueResult(
                    amount,
                    note.isEmpty ? null : note,
                  ));
                },
          style: FilledButton.styleFrom(backgroundColor: Colors.teal),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Выдать'),
        ),
      ],
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: primary
              ? Colors.teal.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: primary ? Colors.teal : Colors.transparent,
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: primary ? Colors.teal : null,
          ),
        ),
      ),
    );
  }
}
