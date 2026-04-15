import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/ledger/bloc/ledger_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/desktop_data_grid.dart';
import 'package:ethnocount/presentation/common/widgets/filter_panel.dart';
import 'package:ethnocount/presentation/common/widgets/animated_counter.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';
import 'package:ethnocount/presentation/common/widgets/export_dialog.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/core/di/injection.dart';

String _ledgerAccountLabel(
  LedgerEntry e,
  Map<String, List<BranchAccount>> branchAccounts,
  Map<String, BranchAccount> flatById,
) {
  final list = branchAccounts[e.branchId];
  BranchAccount? acc;
  if (list != null) {
    for (final a in list) {
      if (a.id == e.accountId) {
        acc = a;
        break;
      }
    }
  }
  acc ??= flatById[e.accountId];
  if (acc != null) {
    return '${acc.name} (${acc.currency})';
  }
  final shortId = e.accountId.length > 10
      ? '${e.accountId.substring(0, 8)}…'
      : e.accountId;
  return '$shortId (${e.currency})';
}

String? _ledgerBranchSubtitle(LedgerEntry e, List<Branch> branches) {
  for (final b in branches) {
    if (b.id == e.branchId) {
      return b.name;
    }
  }
  return null;
}

class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key, this.initialBranchId, this.initialAccountId});
  final String? initialBranchId;
  final String? initialAccountId;

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  final _exportService = sl<ServerExportService>();
  bool _isExporting = false;
  String? _selectedBranchId;
  String? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    if (widget.initialBranchId != null) {
      _selectedBranchId = widget.initialBranchId;
      _selectedAccountId = widget.initialAccountId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<DashboardBloc>().add(
          DashboardBranchSelected(widget.initialBranchId!),
        );
        _loadLedger();
      });
    }
  }

  void _maybeAutoSelectSingleBranch(BuildContext context) {
    final user = context.read<AuthBloc>().state.user;
    final allBranches = context.read<DashboardBloc>().state.branches;
    final branches = filterBranchesByAccess(allBranches, user);
    if (branches.length == 1 && _selectedBranchId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _selectedBranchId = branches.first.id;
          _selectedAccountId = null;
        });
        context.read<DashboardBloc>().add(DashboardBranchSelected(branches.first.id));
        _loadLedger();
      });
    }
  }
  LedgerReferenceType? _referenceFilter;
  DateTimeRange? _dateRange;
  TrinaGridStateManager? _gridStateManager;

  void _loadLedger() {
    if (_selectedBranchId == null) return;
    context.read<LedgerBloc>().add(LedgerLoadRequested(
          branchId: _selectedBranchId!,
          accountId: _selectedAccountId,
          startDate: _dateRange?.start,
          endDate: _dateRange?.end,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final dashState = context.watch<DashboardBloc>().state;
    final user = context.watch<AuthBloc>().state.user;
    final allBranches = dashState.branches;
    final branches = filterBranchesByAccess(allBranches, user);
    final accounts = _selectedBranchId != null
        ? (dashState.branchAccounts[_selectedBranchId] ?? [])
        : <BranchAccount>[];

    _maybeAutoSelectSingleBranch(context);

    final showBranchSelector = branches.length > 1;

    return DataGridShortcuts(
      stateManager: _gridStateManager,
      onExport: _onExport,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < 520;
                final titleStyle = context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Главная книга', style: titleStyle),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () => context.go('/bank-import'),
                              icon: const Icon(Icons.upload_file_rounded, size: 18),
                              label: const FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text('Импорт', style: TextStyle(fontSize: 13)),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _isExporting ? null : _onExport,
                              icon: _isExporting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.download_rounded, size: 18),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _isExporting ? '…' : 'Экспорт',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Главная книга',
                        style: titleStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton.tonalIcon(
                      onPressed: () => context.go('/bank-import'),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: const Text(
                        'Импорт из банка',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _isExporting ? null : _onExport,
                      icon: _isExporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded, size: 16),
                      label: Text(
                        _isExporting ? 'Загрузка...' : 'Экспорт',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Filters
          FilterPanel(
            onReset: () {
              setState(() {
                _selectedBranchId = showBranchSelector ? null : branches.firstOrNull?.id;
                _selectedAccountId = null;
                _referenceFilter = null;
                _dateRange = null;
              });
            },
            children: [
              if (showBranchSelector)
                FilterDropdown<String>(
                  label: 'Филиал',
                  items: branches.map((b) => b.id).toList(),
                  value: _selectedBranchId,
                  itemLabel: (id) => branches.firstWhere((b) => b.id == id).name,
                  width: 180,
                  onChanged: (val) {
                    setState(() {
                      _selectedBranchId = val;
                      _selectedAccountId = null;
                    });
                    if (val != null) {
                      context.read<DashboardBloc>().add(DashboardBranchSelected(val));
                    }
                    _loadLedger();
                  },
                ),
              if (accounts.isNotEmpty)
                FilterDropdown<String>(
                  label: 'Счёт',
                  items: accounts.map((a) => a.id).toList(),
                  value: _selectedAccountId,
                  itemLabel: (id) {
                    final acc = accounts.firstWhere((a) => a.id == id);
                    return '${acc.name} (${acc.currency})';
                  },
                  width: 200,
                  onChanged: (val) {
                    setState(() => _selectedAccountId = val);
                    _loadLedger();
                  },
                ),
              FilterDropdown<LedgerReferenceType>(
                label: 'Тип',
                items: LedgerReferenceType.values,
                value: _referenceFilter,
                itemLabel: (t) => t.displayName,
                width: 160,
                onChanged: (val) => setState(() => _referenceFilter = val),
              ),
              DateRangeFilter(
                startDate: _dateRange?.start,
                endDate: _dateRange?.end,
                onChanged: (range) {
                  setState(() => _dateRange = range);
                  _loadLedger();
                },
              ),
            ],
          ),

          // Balance summary bar
          BlocBuilder<LedgerBloc, LedgerBlocState>(
            builder: (context, state) {
              if (state.accountBalance != null) {
                return _BalanceSummaryBar(
                  balance: state.accountBalance!,
                  entryCount: state.entries.length,
                );
              }
              return const SizedBox.shrink();
            },
          ),

          // Content
          Expanded(
            child: _selectedBranchId == null
                ? _buildSelectBranchPrompt(context, branches.isEmpty)
                : BlocBuilder<LedgerBloc, LedgerBlocState>(
                    builder: (context, state) {
                      if (state.status == LedgerBlocStatus.loading &&
                          state.entries.isEmpty) {
                        return _buildLoadingSkeleton();
                      }

                      if (state.entries.isEmpty) {
                        return _buildEmptyState(context);
                      }

                      final filtered = _referenceFilter != null
                          ? state.entries
                              .where((e) => e.referenceType == _referenceFilter)
                              .toList()
                          : state.entries;

                      final flatAccounts = <String, BranchAccount>{};
                      for (final list in dashState.branchAccounts.values) {
                        for (final acc in list) {
                          flatAccounts[acc.id] = acc;
                        }
                      }

                      if (context.isDesktop) {
                        return StreamBuilder<List<AppUser>>(
                          stream: sl<UserRemoteDataSource>().watchUsers(),
                          builder: (ctx, userSnap) {
                            final userNames = <String, String>{};
                            for (final u in userSnap.data ?? []) {
                              userNames[u.id] = u.displayName.isNotEmpty
                                  ? u.displayName
                                  : (u.email.isNotEmpty ? u.email : '—');
                            }
                            return _buildDesktopGrid(
                              filtered,
                              userNames,
                              flatAccounts,
                              dashState.branchAccounts,
                            );
                          },
                        );
                      }

                      return _buildMobileLedgerTable(
                        context,
                        filtered,
                        dashState.branchAccounts,
                        flatAccounts,
                        dashState.branches,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static String _userDisplay(Map<String, String> userNames, String userId) {
    final name = userNames[userId];
    return (name != null && name.isNotEmpty) ? name : '—';
  }

  Widget _buildDesktopGrid(
    List<LedgerEntry> entries, [
    Map<String, String> userNames = const {},
    Map<String, BranchAccount> flatAccounts = const {},
    Map<String, List<BranchAccount>> branchAccounts = const {},
  ]) {
    final columns = [
      FinancialColumns.text(title: 'Дата', field: 'date', width: 150, frozen: true),
      FinancialColumns.text(title: 'Счёт', field: 'account', width: 180),
      FinancialColumns.text(title: 'Тип операции', field: 'refType', width: 130),
      FinancialColumns.text(title: 'Описание', field: 'description', width: 300),
      FinancialColumns.number(title: 'Дебет', field: 'debit', isCurrency: true, width: 120),
      FinancialColumns.number(title: 'Кредит', field: 'credit', isCurrency: true, width: 120),
      FinancialColumns.text(title: 'Валюта', field: 'currency', width: 80),
      FinancialColumns.text(title: 'Ссылка', field: 'refId', width: 100),
      FinancialColumns.text(title: 'Создал', field: 'createdBy', width: 100),
    ];

    final rows = entries.map((e) => TrinaRow(cells: {
          'date': TrinaCell(value: e.createdAt.historyFormatted),
          'account': TrinaCell(
              value: _ledgerAccountLabel(e, branchAccounts, flatAccounts)),
          'refType': TrinaCell(value: e.referenceType.displayName),
          'description': TrinaCell(value: e.description),
          'debit': TrinaCell(value: e.type == LedgerEntryType.debit ? e.amount : 0.0),
          'credit': TrinaCell(value: e.type == LedgerEntryType.credit ? e.amount : 0.0),
          'currency': TrinaCell(value: e.currency),
          'refId': TrinaCell(value: e.referenceId.length > 8 ? e.referenceId.substring(0, 8) : e.referenceId),
          'createdBy': TrinaCell(value: _userDisplay(userNames, e.createdBy)),
        })).toList();

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: DesktopDataGrid(
        gridId: 'ledger',
        columns: columns,
        rows: rows,
        frozenColumns: 1,
        showPagination: entries.length > 50,
        onLoaded: (event) {
          _gridStateManager = event.stateManager;
        },
      ),
    );
  }

  /// Horizontal-scroll table on phone — avoids ListTile overflow and reads as a table.
  Widget _buildMobileLedgerTable(
    BuildContext context,
    List<LedgerEntry> entries,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, BranchAccount> flatAccounts,
    List<Branch> branches,
  ) {
    final isDark = context.isDark;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: SingleChildScrollView(
                child: DataTable(
                  headingRowHeight: 40,
                  dataRowMinHeight: 44,
                  dataRowMaxHeight: 72,
                  columnSpacing: AppSpacing.md,
                  horizontalMargin: AppSpacing.sm,
                  headingTextStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                  ),
                  columns: const [
                    DataColumn(label: Text('Дата')),
                    DataColumn(label: Text('Тип')),
                    DataColumn(label: Text('Счёт')),
                    DataColumn(label: Text('Описание')),
                    DataColumn(label: Text('Сумма'), numeric: true),
                  ],
                  rows: entries.map((entry) {
                    final isCredit = entry.type == LedgerEntryType.credit;
                    final accLine =
                        _ledgerAccountLabel(entry, branchAccounts, flatAccounts);
                    final branchLine = _ledgerBranchSubtitle(entry, branches);
                    return DataRow(
                      cells: [
                        DataCell(Text(
                          entry.createdAt.historyFormatted,
                          style: const TextStyle(fontSize: 12),
                        )),
                        DataCell(Text(
                          entry.referenceType.displayName,
                          style: const TextStyle(fontSize: 11),
                        )),
                        DataCell(
                          SizedBox(
                            width: 120,
                            child: Text(
                              accLine,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                        DataCell(
                          SizedBox(
                            width: 160,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  entry.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (branchLine != null)
                                  Text(
                                    branchLine,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isDark
                                          ? AppColors.darkTextSecondary
                                          : AppColors.lightTextSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            '${isCredit ? '+' : '−'}${entry.amount.formatCurrency()} ${entry.currency}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'JetBrains Mono',
                              color: isCredit ? AppColors.success : AppColors.error,
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectBranchPrompt(BuildContext context, bool noBranches) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            noBranches ? Icons.lock_outline : Icons.account_tree_outlined,
            size: 64,
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            noBranches
                ? 'Нет доступных филиалов'
                : 'Выберите филиал для просмотра журнала',
            style: context.textTheme.titleMedium?.copyWith(
              color: context.isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Записи в журнале отсутствуют',
            style: context.textTheme.titleMedium?.copyWith(
              color: context.isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: List.generate(
          10,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ShimmerLoading.listTile(),
          ),
        ),
      ),
    );
  }

  Future<void> _onExport() async {
    if (_selectedBranchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала выберите филиал')),
      );
      return;
    }
    if (_isExporting) return;
    final settings = await showDialog<ExportSettings>(
      context: context,
      builder: (ctx) => ExportDialog(
        title: 'Настройки экспорта журнала',
        columns: ExportColumnPresets.ledger,
      ),
    );
    if (settings == null || !mounted) return;
    setState(() => _isExporting = true);
    try {
      final url = await _exportService.exportLedger(
        branchId: _selectedBranchId!,
        startDate: _dateRange?.start,
        endDate: _dateRange?.end,
        exportSettings: settings,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            url == null
                ? 'Нет данных для экспорта.'
                : 'Экспорт завершён. Файл сохранён.',
          ),
          duration: const Duration(seconds: 3),
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

class _BalanceSummaryBar extends StatelessWidget {
  const _BalanceSummaryBar({
    required this.balance,
    required this.entryCount,
  });

  final double balance;
  final int entryCount;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.primary.withValues(alpha: 0.05)
            : AppColors.primary.withValues(alpha: 0.03),
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Text(
            'Баланс: ',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
          Flexible(
            child: AnimatedCounter(
              value: balance,
              decimalPlaces: 2,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrains Mono',
                color: balance >= 0 ? AppColors.success : AppColors.error,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              '$entryCount записей',
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
