import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/transfers/widgets/accept_transfer_account_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/amend_pending_transfer_dialog.dart';
import 'package:ethnocount/core/utils/branch_access.dart';

/// Страница управления входящими переводами (принять/отклонить).
class ManageTransfersPage extends StatefulWidget {
  const ManageTransfersPage({super.key});

  @override
  State<ManageTransfersPage> createState() => _ManageTransfersPageState();
}

class _ManageTransfersPageState extends State<ManageTransfersPage> {
  String? _branchFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    context.read<TransferBloc>().add(TransfersLoadRequested(
          branchId: _branchFilter,
          statusFilter: TransferStatus.pending,
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
    final myBranchIds = user?.role.isCreator == true
        ? allBranches.map((b) => b.id).toList()
        : (user?.assignedBranchIds ?? []);

    final state = context.watch<TransferBloc>().state;
    final pending = state.transfers.where((t) => t.isPending).toList();
    final incoming = pending
        .where((t) => myBranchIds.contains(t.toBranchId))
        .toList();

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          _load();
        } else if (state.status == TransferBlocStatus.error &&
            (state.errorMessage ?? '').isNotEmpty) {
          final msg = state.errorMessage!;
          if (msg.contains('Счёт получателя') || msg.contains('валюте')) {
            final messenger = ScaffoldMessenger.of(context);
            messenger.clearSnackBars();
            messenger.showSnackBar(
              SnackBar(
                content: Text(msg),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        }
      },
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
                      const Icon(Icons.inbox_rounded, size: 28, color: AppColors.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Управление переводами',
                          style: context.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => context.go('/transfers'),
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('К переводам'),
                      ),
                      if (branches.isNotEmpty) ...[
                        const SizedBox(width: AppSpacing.sm),
                        DropdownButton<String>(
                          value: _branchFilter,
                          hint: const Text('Все филиалы'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Входящие')),
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
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Входящие переводы на подтверждение',
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
          if (state.status == TransferBlocStatus.loading && incoming.isEmpty)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (incoming.isEmpty)
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
                      'Нет входящих переводов',
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
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final t = incoming[index];
                    return _ManageTransferTile(
                      transfer: t,
                      branches: allBranches,
                      branchAccounts: branchAccounts,
                      onAccept: () => _handleAccept(context, t),
                      onReject: () => _showRejectDialog(context, t),
                      onAmend: () => showAmendPendingTransferDialog(context, t),
                    );
                  },
                  childCount: incoming.length,
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  void _handleAccept(BuildContext context, Transfer t) {
    if (t.toAccountId.isNotEmpty) {
      context.read<TransferBloc>().add(TransferConfirmRequested(t.id));
      return;
    }
    showAcceptTransferAccountDialog(context, t);
  }

  void _showRejectDialog(BuildContext context, Transfer t) {
    final reasonCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отклонить перевод'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(
            labelText: 'Причина отклонения',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              context.read<TransferBloc>().add(
                    TransferRejectRequested(
                      t.id,
                      reasonCtrl.text.trim().isEmpty
                          ? 'Отклонён'
                          : reasonCtrl.text.trim(),
                    ),
                  );
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Отклонить'),
          ),
        ],
      ),
    );
  }
}

class _ManageTransferTile extends StatelessWidget {
  const _ManageTransferTile({
    required this.transfer,
    required this.branches,
    this.branchAccounts = const {},
    required this.onAccept,
    required this.onReject,
    required this.onAmend,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onAmend;

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
    final isCrossCurrency = t.currency != recvCur;

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
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Ожидает',
                    style: TextStyle(
                      color: Colors.orange,
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
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Списание', style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                    Text('${t.totalDebitAmount.formatCurrencyNoDecimals()} ${t.currency}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ],
                ),
                if (isCrossCurrency) ...[
                  const SizedBox(width: AppSpacing.lg),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Курс ${t.currency}→$recvCur', style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                      Text('×${t.exchangeRate}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.lg),
                ],
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Получат', style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
                    Text('${t.receiverGetsConverted.formatCurrencyNoDecimals()} $recvCur',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.success)),
                  ],
                ),
              ],
            ),
            if (t.commission > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Комиссия: ${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                    style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
              ),
            if (t.amendmentHistory.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  'История изменений (${t.amendmentHistory.length})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                  ),
                ),
                children: [
                  ...t.amendmentHistory.map((e) {
                    final lines = e.changes.entries.map((ce) {
                      final v = ce.value;
                      if (v is Map) {
                        return '${ce.key}: ${v['from']} → ${v['to']}';
                      }
                      return ce.key;
                    }).join('\n');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${e.at.toLocal().toString().substring(0, 16)}\n'
                          '${e.note != null && e.note!.isNotEmpty ? '${e.note!}\n' : ''}'
                          '$lines',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? AppColors.darkTextSecondary
                                : AppColors.lightTextSecondary,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onAmend,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Исправить'),
                ),
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Отклонить'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Принять'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
