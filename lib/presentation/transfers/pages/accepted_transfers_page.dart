import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/desktop_data_grid.dart';
import 'package:ethnocount/presentation/transfers/widgets/edit_transfer_dialog.dart';
import 'package:ethnocount/core/utils/branch_access.dart';

/// Экран принятых переводов (confirmed + issued) с деталями: курс, налом, по карте.
class AcceptedTransfersPage extends StatefulWidget {
  const AcceptedTransfersPage({super.key});

  @override
  State<AcceptedTransfersPage> createState() => _AcceptedTransfersPageState();
}

class _AcceptedTransfersPageState extends State<AcceptedTransfersPage> {
  String? _branchFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    context.read<TransferBloc>().add(TransfersLoadRequested(
          branchId: _branchFilter,
          statusFilter: null,
          startDate: null,
          endDate: null,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final user = context.select<AuthBloc, dynamic>((b) => b.state.user);
    final allBranches = context.select<DashboardBloc, List<Branch>>(
      (bloc) => bloc.state.branches,
    );
    final branchAccounts = context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
      (bloc) => bloc.state.branchAccounts,
    );
    final branches = filterBranchesByAccess(allBranches, user);
    final state = context.watch<TransferBloc>().state;
    final transfers = state.transfers
        .where((t) => t.isConfirmed || t.isIssued)
        .toList();

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          curr.status == TransferBlocStatus.success,
      listener: (context, _) => _load(),
      child: Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 28, color: AppColors.success),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        'Принятые переводы',
                        style: context.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (branches.isNotEmpty)
                        DropdownButton<String>(
                          value: _branchFilter,
                          hint: const Text('Все филиалы'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Все филиалы')),
                            ...branches.map((b) => DropdownMenuItem(
                                  value: b.id,
                                  child: Text(b.name),
                                )),
                          ],
                          onChanged: (v) {
                            setState(() {
                              _branchFilter = v;
                              _load();
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Принятые и выданные переводы • курс • налом / по карте',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.isDark
                          ? AppColors.darkTextSecondary
                          : AppColors.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (state.status == TransferBlocStatus.loading && transfers.isEmpty)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (transfers.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 64,
                      color: context.isDark
                          ? AppColors.darkTextTertiary
                          : AppColors.lightTextTertiary,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Нет принятых переводов',
                      style: TextStyle(
                        color: context.isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (context.isDesktop)
            SliverFillRemaining(
              hasScrollBody: true,
              child: Builder(
                builder: (ctx) {
                  final branchAccounts = ctx.select<DashboardBloc, Map<String, List<BranchAccount>>>(
                    (bloc) => bloc.state.branchAccounts,
                  );
                  return StreamBuilder<List<AppUser>>(
                    stream: sl<UserRemoteDataSource>().watchUsers(),
                    builder: (_, userSnap) {
                      final userNames = <String, String>{};
                      for (final u in userSnap.data ?? []) {
                        userNames[u.id] = u.displayName.isNotEmpty
                            ? u.displayName
                            : (u.email.isNotEmpty ? u.email : '—');
                      }
                      if (!userSnap.hasData && userSnap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return _buildAcceptedDesktopTable(
                        ctx,
                        transfers,
                        allBranches,
                        branchAccounts,
                        userNames,
                      );
                    },
                  );
                },
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final t = transfers[index];
                    return _AcceptedTransferTile(
                      transfer: t,
                      branches: allBranches,
                      branchAccounts: branchAccounts,
                      onIssue: t.isConfirmed
                          ? () => context
                              .read<TransferBloc>()
                              .add(TransferIssueRequested(t.id))
                          : null,
                      onEdit: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => EditTransferDialog(
                            transfer: t,
                            onSaved: () => Navigator.of(ctx).pop(),
                            allowAmountEdit: false,
                          ),
                        );
                      },
                    );
                  },
                  childCount: transfers.length,
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  static String _userDisplay(Map<String, String> userNames, String userId) {
    final name = userNames[userId];
    return (name != null && name.isNotEmpty) ? name : '—';
  }

  Widget _buildAcceptedDesktopTable(
    BuildContext context,
    List<Transfer> transfers,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
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

    final columns = [
      FinancialColumns.text(title: 'Код', field: 'code', width: 100, frozen: true),
      FinancialColumns.text(title: 'Дата', field: 'date', width: 95),
      FinancialColumns.text(title: 'Филиал отправителя', field: 'from', width: 140),
      FinancialColumns.text(title: 'Счёт отправителя', field: 'fromAccount', width: 140),
      FinancialColumns.text(title: 'Имя отправителя', field: 'senderName', width: 120),
      FinancialColumns.text(title: 'Филиал получателя', field: 'to', width: 140),
      FinancialColumns.text(title: 'Имя получателя', field: 'receiverName', width: 120),
      FinancialColumns.text(title: 'Сумма', field: 'amountDisplay', width: 100),
      FinancialColumns.text(title: 'Валюта отправителя', field: 'fromCurrency', width: 75),
      FinancialColumns.text(title: 'Курс', field: 'rate', width: 60),
      FinancialColumns.text(title: 'Конвертировано', field: 'convertedDisplay', width: 100),
      FinancialColumns.text(title: 'Валюта получателя', field: 'toCurrency', width: 75),
      FinancialColumns.text(title: 'Комиссия', field: 'commissionDisplay', width: 90),
      FinancialColumns.text(title: 'Счёт получателя', field: 'toAccount', width: 100),
      FinancialColumns.status(title: 'Статус', field: 'status', width: 80),
      FinancialColumns.text(title: 'Создал', field: 'createdBy', width: 100),
      FinancialColumns.text(title: 'Принял', field: 'confirmedBy', width: 100),
    ];

    return FutureBuilder<Map<String, BranchAccount>>(
      future: _loadAllAccounts(transfers),
      builder: (ctx, accSnap) {
        final accMap = accSnap.data ?? {};
        final rows = transfers.map((t) {
          final sentCur = t.currency;
          final recvCur = t.toCurrency ?? t.currency;
          final sentText = t.isSplitCurrency
              ? t.splitPartsDisplay
              : '${t.totalDebitAmount.formatCurrencyNoDecimals()} $sentCur';
          final recvText = '${(t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted).formatCurrencyNoDecimals()} $recvCur';
          final rateDisplay = sentCur != recvCur ? t.exchangeRate.toString() : '—';
          final commissionText = t.commission > 0
              ? '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}'
              : '—';
          final toAcc = t.toAccountId.isNotEmpty ? accMap[t.toAccountId] : null;

          return TrinaRow(cells: {
            'code': TrinaCell(value: t.transactionCode ?? t.id.substring(0, 8)),
            'date': TrinaCell(value: t.createdAt.fullFormatted),
            'from': TrinaCell(value: branchName(t.fromBranchId)),
            'fromAccount': TrinaCell(value: accountName(t.fromAccountId)),
            'senderName': TrinaCell(value: t.senderName ?? '—'),
            'to': TrinaCell(value: branchName(t.toBranchId)),
            'receiverName': TrinaCell(value: t.receiverName ?? '—'),
            'amountDisplay': TrinaCell(value: sentText),
            'fromCurrency': TrinaCell(value: sentCur),
            'rate': TrinaCell(value: rateDisplay),
            'convertedDisplay': TrinaCell(value: recvText),
            'toCurrency': TrinaCell(value: recvCur),
            'commissionDisplay': TrinaCell(value: commissionText),
            'toAccount': TrinaCell(value: toAcc?.name ?? '—'),
            'status': TrinaCell(value: t.isIssued ? 'issued' : 'confirmed'),
            'createdBy': TrinaCell(value: _userDisplay(userNames, t.createdBy)),
            'confirmedBy': TrinaCell(value: t.confirmedBy != null ? _userDisplay(userNames, t.confirmedBy!) : '—'),
          });
        }).toList();

        return Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: DesktopDataGrid(
            gridId: 'accepted_transfers',
            columns: columns,
            rows: rows,
            frozenColumns: 1,
            showPagination: transfers.length > 50,
            onRowDoubleTap: (event) {
              final idx = event.rowIdx;
              if (idx >= 0 && idx < transfers.length) {
                final t = transfers[idx];
                showDialog(
                  context: context,
                  builder: (ctx) => EditTransferDialog(
                    transfer: t,
                    onSaved: () => Navigator.of(ctx).pop(),
                    allowAmountEdit: false,
                  ),
                );
              }
            },
          ),
        );
      },
    );
  }

  Future<Map<String, BranchAccount>> _loadAllAccounts(List<Transfer> transfers) async {
    final repo = sl<BranchRepository>();
    final accMap = <String, BranchAccount>{};
    final ids = <String>{};
    for (final t in transfers) {
      if (t.fromAccountId.isNotEmpty) ids.add(t.fromAccountId);
      if (t.toAccountId.isNotEmpty) ids.add(t.toAccountId);
    }
    for (final id in ids) {
      final r = await repo.getBranchAccount(id);
      r.fold((_) {}, (a) => accMap[id] = a);
    }
    return accMap;
  }
}

class _AcceptedTransferTile extends StatelessWidget {
  const _AcceptedTransferTile({
    required this.transfer,
    required this.branches,
    this.branchAccounts = const {},
    this.onIssue,
    this.onEdit,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final VoidCallback? onIssue;
  final VoidCallback? onEdit;

  String _branchName(String id) {
    final match = branches.where((b) => b.id == id);
    return match.isNotEmpty ? match.first.name : id;
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
    final recvCur = t.toCurrency ?? t.currency;

    return FutureBuilder<({BranchAccount? fromAcc, BranchAccount? toAcc})>(
      future: _loadAccounts(t),
      builder: (context, snap) {
        final fromAcc = snap.data?.fromAcc;
        final toAcc = snap.data?.toAcc;
        final toType = toAcc?.type.displayName ?? '—';
        final isCash = toAcc?.type == AccountType.cash;
        final isCard = toAcc?.type == AccountType.card;

        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            side: BorderSide(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_branchName(t.fromBranchId)} → ${_branchName(t.toBranchId)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (t.isIssued ? Colors.teal : AppColors.success)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        t.isIssued ? 'Выдан' : 'Принят',
                        style: TextStyle(
                          color: t.isIssued ? Colors.teal : AppColors.success,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (t.transactionCode != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      t.transactionCode!,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                if (t.senderName != null && t.senderName!.isNotEmpty)
                  Text('Отправитель: ${t.senderName}${t.senderPhone != null && t.senderPhone!.isNotEmpty ? ' • ${t.senderPhone}' : ''}',
                      style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                if (t.receiverName != null && t.receiverName!.isNotEmpty)
                  Text('Получатель: ${t.receiverName}${t.receiverPhone != null && t.receiverPhone!.isNotEmpty ? ' • ${t.receiverPhone}' : ''}',
                      style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                Text('Счёт отправителя: ${_accountName(t.fromAccountId)}',
                    style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                if (toAcc != null)
                  Text('Счёт получателя: ${toAcc.name} (${toType})',
                      style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                const SizedBox(height: AppSpacing.md),
                // Сумма, валюта, курс, налом/карта
                Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _InfoChip(
                      icon: Icons.arrow_upward,
                      label: 'Списано: ${t.totalDebitAmount.formatCurrencyNoDecimals()} ${t.currency}',
                      color: const Color(0xFFE53935),
                    ),
                    _InfoChip(
                      icon: Icons.payments,
                      label: 'Выдано: ${t.convertedAmount.formatCurrencyNoDecimals()} $recvCur',
                      color: AppColors.primary,
                    ),
                    _InfoChip(
                      icon: Icons.currency_exchange,
                      label: '${t.currency} → $recvCur: ${t.exchangeRate}',
                      color: AppColors.secondary,
                    ),
                    if (t.commission > 0)
                      _InfoChip(
                        icon: Icons.percent,
                        label: 'Комиссия: ${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                        color: Colors.orange,
                      ),
                    _InfoChip(
                      icon: isCash ? Icons.payments : Icons.credit_card,
                      label: isCash ? 'Наличные' : (isCard ? 'Карта' : toType),
                      color: isCash ? Colors.green : Colors.blue,
                    ),
                    if (fromAcc != null)
                      _InfoChip(
                        icon: Icons.account_balance_wallet,
                        label: 'Счёт отправителя: ${fromAcc.name}',
                        color: Colors.grey,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(
                      t.createdAt.toIso8601String().split('T').first,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.darkTextTertiary
                            : AppColors.lightTextTertiary,
                      ),
                    ),
                    if (onEdit != null || onIssue != null) ...[
                      const Spacer(),
                      if (onEdit != null)
                        OutlinedButton.icon(
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('Изменить'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                          ),
                        ),
                      if (onEdit != null && onIssue != null)
                        const SizedBox(width: 8),
                      if (onIssue != null)
                        FilledButton.icon(
                          onPressed: onIssue,
                          icon: const Icon(Icons.check_circle_outline, size: 16),
                          label: const Text('Выдать'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.teal,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<({BranchAccount? fromAcc, BranchAccount? toAcc})> _loadAccounts(
      Transfer t) async {
    final repo = sl<BranchRepository>();
    final fromResult = await repo.getBranchAccount(t.fromAccountId);
    final toResult = await repo.getBranchAccount(t.toAccountId);
    return (
      fromAcc: fromResult.fold((_) => null, (a) => a),
      toAcc: toResult.fold((_) => null, (a) => a),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
