import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/transfers/widgets/accept_transfer_account_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/dispatch_courier_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/edit_transfer_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_status_chip.dart';

/// Управление в-полёте переводами: три таба по статусам, под каждым —
/// своё действие (Принять / Отдать курьеру / Выдать).
class ManageTransfersPage extends StatefulWidget {
  const ManageTransfersPage({super.key});

  @override
  State<ManageTransfersPage> createState() => _ManageTransfersPageState();
}

class _ManageTransfersPageState extends State<ManageTransfersPage>
    with SingleTickerProviderStateMixin {
  String? _branchFilter;
  late final TabController _tabs;

  static const _statuses = <TransferStatus>[
    TransferStatus.created,
    TransferStatus.toDelivery,
    TransferStatus.withCourier,
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _statuses.length, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _load() {
    // Загружаем все не-финальные переводы; фильтрация по статусу — client-side
    // по табу, чтобы переключение было мгновенным.
    context.read<TransferBloc>().add(TransfersLoadRequested(
          branchId: _branchFilter,
          startDate: null,
          endDate: null,
        ));
  }

  /// Релевантные для текущего пользователя переводы внутри одного статуса.
  /// `created` и `withCourier` интересны принимающему филиалу; `toDelivery`
  /// — отправляющему (он отдаёт курьеру).
  List<Transfer> _scopedForUser(
    List<Transfer> all,
    TransferStatus status,
    List<String> userBranchIds,
    bool isAdmin,
  ) {
    final filtered = all.where((t) => t.status == status);
    if (isAdmin) return filtered.toList();
    return filtered.where((t) {
      switch (status) {
        case TransferStatus.created:
        case TransferStatus.withCourier:
          return userBranchIds.contains(t.toBranchId);
        case TransferStatus.toDelivery:
          return userBranchIds.contains(t.fromBranchId);
        case TransferStatus.delivered:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.select<AuthBloc, dynamic>((b) => b.state.user);
    final allBranches = context.select<DashboardBloc, List<Branch>>(
      (bloc) => bloc.state.branches,
    );
    final branchAccounts =
        context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
      (bloc) => bloc.state.branchAccounts,
    );
    final branches = filterBranchesByAccess(allBranches, user);
    final isAdmin = user?.role.isAdminOrCreator == true ||
        user?.role.isDirector == true;
    final myBranchIds = isAdmin
        ? allBranches.map((b) => b.id).toList()
        : (user?.assignedBranchIds as List<String>? ?? const <String>[]);

    final state = context.watch<TransferBloc>().state;
    final all = state.transfers;
    final perStatus = {
      for (final s in _statuses)
        s: _scopedForUser(all, s, myBranchIds, isAdmin),
    };

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (ctx, st) {
        if (st.status == TransferBlocStatus.success) {
          _load();
          if ((st.successMessage ?? '').isNotEmpty) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: Text(st.successMessage!),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        if (st.status == TransferBlocStatus.error &&
            (st.errorMessage ?? '').isNotEmpty) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(
              content: Text(st.errorMessage!),
              backgroundColor: Theme.of(ctx).colorScheme.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            _Header(
              branches: branches,
              branchFilter: _branchFilter,
              onBranchChanged: (v) {
                setState(() => _branchFilter = v);
                _load();
              },
            ),
            _StatusTabBar(
              tabs: _tabs,
              counts: {
                for (final s in _statuses) s: perStatus[s]!.length,
              },
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: _statuses.map((s) {
                  final list = perStatus[s]!;
                  if (state.status == TransferBlocStatus.loading &&
                      list.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (list.isEmpty) {
                    return _EmptyState(status: s);
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _load(),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.md,
                      ),
                      itemCount: list.length,
                      itemBuilder: (ctx, i) {
                        final t = list[i];
                        final isCard =
                            _isCardAccount(branchAccounts, t);
                        return _ManageTransferTile(
                          transfer: t,
                          isCard: isCard,
                          branches: allBranches,
                          branchAccounts: branchAccounts,
                          onAccept: t.isCreated
                              ? () => _handleAccept(context, t)
                              : null,
                          // Курьерская доставка ОПЦИОНАЛЬНА: cash-перевод в
                          // toDelivery может либо «уйти курьеру» (вариант с
                          // tracking — статус withCourier), либо сразу быть
                          // выдан. Card-переводы курьера не используют.
                          onDispatch: t.isToDelivery && !isCard
                              ? () => showDispatchCourierDialog(context, t)
                              : null,
                          // «Выдать» доступно из любого пред-финального
                          // статуса (toDelivery и withCourier) — оператор
                          // решает, нужен ли курьерский шаг.
                          onIssue: (t.isToDelivery || t.isWithCourier)
                              ? () => _handleIssue(context, t)
                              : null,
                          onAmend: t.isCreated
                              ? () => _showEditDialog(context, t)
                              : null,
                        );
                      },
                    ),
                  );
                }).toList(),
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

  /// Открыть полный editor для pending перевода.
  void _showEditDialog(BuildContext context, Transfer t) {
    showDialog(
      context: context,
      builder: (ctx) => EditTransferDialog(
        transfer: t,
        onSaved: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  /// Тип счёта получателя: true если КАРТА (курьер пропускается).
  bool _isCardAccount(
    Map<String, List<BranchAccount>> branchAccounts,
    Transfer t,
  ) {
    if (t.toAccountId.isEmpty) return false;
    final list = branchAccounts[t.toBranchId];
    if (list == null) return false;
    final acc = list.where((a) => a.id == t.toAccountId).firstOrNull;
    return acc?.type == AccountType.card;
  }

  /// Выдача получателю: используем partial-RPC даже для «выдать всё»,
  /// чтобы корректно списать баланс с физического счёта (карта/касса) и
  /// записать ledger debit. Без этого касса оставалась бы с лишними деньгами.
  void _handleIssue(BuildContext context, Transfer t) {
    final remaining = t.remainingToIssue;
    if (remaining <= 0) return;
    if (t.toAccountId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'У перевода нет счёта выдачи — выдайте через детальный диалог.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    context.read<TransferBloc>().add(TransferIssuePartialRequested(
          transferId: t.id,
          amount: remaining,
          fromAccountId: t.toAccountId,
        ));
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.branches,
    required this.branchFilter,
    required this.onBranchChanged,
  });

  final List<Branch> branches;
  final String? branchFilter;
  final ValueChanged<String?> onBranchChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(AppIcons.inbox, size: 28, color: AppColors.primary),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Управление переводами',
                style: context.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Принять, отдать курьеру, выдать получателю',
                style: TextStyle(
                  fontSize: 12,
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                ),
              ),
            ],
          ),
          // Spacer внутри Wrap = Expanded внутри Flex-несовместимого parent,
          // Flutter крашит сборку. Wrap сам распределяет элементы; здесь
          // достаточно небольшого зазора.
          const SizedBox(width: AppSpacing.lg),
          if (branches.isNotEmpty)
            DropdownButton<String>(
              value: branchFilter,
              hint: const Text('Все филиалы'),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('Все филиалы')),
                ...branches.map((b) => DropdownMenuItem(
                      value: b.id,
                      child: Text(b.name),
                    )),
              ],
              onChanged: onBranchChanged,
            ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: () => context.go('/transfers'),
            icon: const Icon(AppIcons.arrow_back, size: 18),
            label: const Text('К переводам'),
          ),
        ],
      ),
    );
  }
}

class _StatusTabBar extends StatelessWidget {
  const _StatusTabBar({required this.tabs, required this.counts});
  final TabController tabs;
  final Map<TransferStatus, int> counts;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            width: 0.5,
          ),
        ),
      ),
      child: TabBar(
        controller: tabs,
        isScrollable: true,
        labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        indicatorColor: AppColors.primary,
        labelColor:
            isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        unselectedLabelColor:
            isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
        tabs: counts.keys.map((s) {
          final style = TransferStatusStyle.of(s);
          final n = counts[s] ?? 0;
          return Tab(
            height: 52,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(style.icon, size: 16, color: style.color),
                const SizedBox(width: 6),
                Text(style.label, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: style.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$n',
                    style: TextStyle(
                      color: style.color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.status});
  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    final style = TransferStatusStyle.of(status);
    final hint = switch (status) {
      TransferStatus.created => 'Здесь появятся новые переводы для приёма.',
      TransferStatus.toDelivery =>
        'Принятые переводы. Наличные — отдать курьеру, на карту — выдать сразу.',
      TransferStatus.withCourier =>
        'Только наличные переводы у курьера — отметьте «Выдан», когда получатель забрал деньги.',
      TransferStatus.delivered => 'Архив выданных переводов.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.icon,
                size: 56, color: style.color.withValues(alpha: 0.55)),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Пусто в статусе «${style.label}»',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManageTransferTile extends StatelessWidget {
  const _ManageTransferTile({
    required this.transfer,
    required this.isCard,
    required this.branches,
    this.branchAccounts = const {},
    this.onAccept,
    this.onDispatch,
    this.onIssue,
    this.onAmend,
  });

  final Transfer transfer;
  final bool isCard;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final VoidCallback? onAccept;
  final VoidCallback? onDispatch;
  final VoidCallback? onIssue;
  final VoidCallback? onAmend;

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
            // Header row: route + transaction code + status chip
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_branchName(t.fromBranchId)} → ${_branchName(t.toBranchId)}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (t.transactionCode != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            t.transactionCode!,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'JetBrains Mono',
                              color: isDark
                                  ? AppColors.darkTextSecondary
                                  : AppColors.lightTextSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (t.toAccountId.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _PaymentKindChip(isCard: isCard),
                  ),
                TransferStatusChip(status: t.status, showIcon: true),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Sender / receiver info
            if (t.senderName != null && t.senderName!.isNotEmpty)
              _kv(
                context,
                'От',
                '${t.senderName}'
                    '${t.senderPhone != null && t.senderPhone!.isNotEmpty ? ' • ${t.senderPhone}' : ''}',
              ),
            if (t.receiverName != null && t.receiverName!.isNotEmpty)
              _kv(
                context,
                'Кому',
                '${t.receiverName}'
                    '${t.receiverPhone != null && t.receiverPhone!.isNotEmpty ? ' • ${t.receiverPhone}' : ''}',
              ),
            _kv(context, 'Счёт отправителя', _accountName(t.fromAccountId)),
            if (t.isWithCourier &&
                (t.courierName?.isNotEmpty == true ||
                    t.courierPhone?.isNotEmpty == true))
              _kv(
                context,
                'Курьер',
                [t.courierName, t.courierPhone]
                    .whereType<String>()
                    .where((s) => s.isNotEmpty)
                    .join(' • '),
              ),

            const SizedBox(height: AppSpacing.sm),

            // Amounts row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Money(
                  label: 'Списание',
                  amount: t.totalDebitAmount,
                  currency: t.currency,
                ),
                if (isCrossCurrency) ...[
                  const SizedBox(width: AppSpacing.lg),
                  _Rate(
                    from: t.currency,
                    to: recvCur,
                    rate: t.exchangeRate,
                  ),
                ],
                const SizedBox(width: AppSpacing.lg),
                _Money(
                  label: 'Получит',
                  amount: t.receiverGetsConverted,
                  currency: recvCur,
                  highlight: true,
                ),
                if (t.commission > 0) ...[
                  const SizedBox(width: AppSpacing.lg),
                  _Money(
                    label: 'Комиссия',
                    amount: t.commission,
                    currency: t.commissionCurrency,
                    muted: true,
                  ),
                ],
              ],
            ),

            if (t.isWithCourier && t.dispatchedAt != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Отдано курьеру ${t.dispatchedAt!.fullFormatted}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.info,
                ),
              ),
            ],

            const SizedBox(height: AppSpacing.md),

            // Per-status actions
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (onAmend != null)
                  TextButton.icon(
                    onPressed: onAmend,
                    icon: const Icon(AppIcons.edit, size: 16),
                    label: const Text('Исправить'),
                  ),
                if (onAccept != null)
                  FilledButton.icon(
                    onPressed: onAccept,
                    icon: const Icon(AppIcons.check, size: 18),
                    label: const Text('Принять'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.secondary,
                    ),
                  ),
                if (onDispatch != null)
                  FilledButton.icon(
                    onPressed: onDispatch,
                    icon: const Icon(AppIcons.local_shipping, size: 18),
                    label: const Text('Отдать курьеру'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.info,
                    ),
                  ),
                if (onIssue != null)
                  FilledButton.icon(
                    onPressed: onIssue,
                    icon: const Icon(AppIcons.payments, size: 18),
                    label: const Text('Выдать получателю'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final isDark = context.isDark;
    final muted = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 12, color: muted),
          children: [
            TextSpan(text: '$k: '),
            TextSpan(
              text: v,
              style: TextStyle(
                color: isDark
                    ? AppColors.darkTextPrimary
                    : AppColors.lightTextPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Money extends StatelessWidget {
  const _Money({
    required this.label,
    required this.amount,
    required this.currency,
    this.highlight = false,
    this.muted = false,
  });

  final String label;
  final double amount;
  final String currency;
  final bool highlight;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final color = muted
        ? secondary
        : (highlight ? AppColors.primary : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: secondary)),
        Text(
          '${amount.formatCurrencyNoDecimals()} $currency',
          style: TextStyle(
            fontSize: muted ? 13 : 16,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _Rate extends StatelessWidget {
  const _Rate({required this.from, required this.to, required this.rate});
  final String from;
  final String to;
  final double rate;

  @override
  Widget build(BuildContext context) {
    final secondary = context.isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Курс $from→$to',
            style: TextStyle(fontSize: 10, color: secondary)),
        Text(
          '×${rate.toStringAsFixed(rate >= 100 ? 0 : 4)}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Маленький чип «Карта»/«Наличные» — показывает тип счёта получателя,
/// чтобы оператор сразу видел, нужна ли курьерская доставка.
class _PaymentKindChip extends StatelessWidget {
  const _PaymentKindChip({required this.isCard});
  final bool isCard;

  @override
  Widget build(BuildContext context) {
    final color = isCard ? AppColors.secondary : AppColors.warning;
    final icon = isCard ? AppIcons.credit_card : AppIcons.payments;
    final label = isCard ? 'Карта' : 'Наличные';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
