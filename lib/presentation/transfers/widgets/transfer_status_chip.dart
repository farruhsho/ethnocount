import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/transfers/widgets/accept_transfer_account_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/dispatch_courier_dialog.dart';

/// Палитра для статусов перевода в dark-fintech стиле.
/// Используется чипами, badge-ами и pipeline'ом сверху TransfersPage.
class TransferStatusStyle {
  const TransferStatusStyle({
    required this.color,
    required this.label,
    required this.icon,
    required this.shortLabel,
  });

  final Color color;
  final String label;
  final String shortLabel;
  final IconData icon;

  static TransferStatusStyle of(TransferStatus s) {
    switch (s) {
      case TransferStatus.created:
        return const TransferStatusStyle(
          color: AppColors.warning,
          label: 'Создан',
          shortLabel: 'Создан',
          icon: AppIcons.pending_actions,
        );
      case TransferStatus.toDelivery:
        return const TransferStatusStyle(
          color: AppColors.secondary,
          label: 'К выдаче',
          shortLabel: 'К выдаче',
          icon: AppIcons.task_alt,
        );
      case TransferStatus.withCourier:
        return const TransferStatusStyle(
          color: AppColors.info,
          label: 'У курьера',
          shortLabel: 'Курьер',
          icon: AppIcons.local_shipping,
        );
      case TransferStatus.delivered:
        return const TransferStatusStyle(
          color: AppColors.primary,
          label: 'Выдан',
          shortLabel: 'Выдан',
          icon: AppIcons.payments,
        );
    }
  }
}

/// Маленький pill-style чип статуса перевода. С `onTap` ведёт себя как
/// «продвинуть статус» — открывает нужный диалог (Принять / Отдать
/// курьеру / Выдать).
class TransferStatusChip extends StatelessWidget {
  const TransferStatusChip({
    super.key,
    required this.status,
    this.dense = false,
    this.showIcon = false,
    this.onTap,
    this.tooltip,
  });

  final TransferStatus status;
  final bool dense;
  final bool showIcon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final s = TransferStatusStyle.of(status);
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: onTap != null
            ? Border.all(
                color: s.color.withValues(alpha: 0.35),
                width: 0.8,
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(s.icon, size: dense ? 10 : 12, color: s.color),
            const SizedBox(width: 4),
          ],
          Text(
            s.label,
            style: TextStyle(
              color: s.color,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(AppIcons.arrow_forward, size: dense ? 10 : 12, color: s.color),
          ],
        ],
      ),
    );

    Widget result = body;
    if (onTap != null) {
      result = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: body,
        ),
      );
    }

    if (tooltip != null && tooltip!.isNotEmpty) {
      result = Tooltip(message: tooltip!, child: result);
    }
    return result;
  }
}

/// Контекстный «next action» по статусу перевода. Возвращает либо
/// callback который продвинет workflow, либо null если действие сейчас
/// недоступно (deliver уже финал, нет прав, перевод чужой ветки).
///
/// Логика card vs cash:
///   * Если to_account_id типа `card` — переводы доставляются электронно
///     и сразу выдаются: `created → toDelivery → delivered` (без курьера).
///     В статусе toDelivery действие = «Выдать получателю».
///   * Если to_account типа `cash` (или не задан) — нужен физический курьер:
///     `created → toDelivery → withCourier → delivered`.
///     В toDelivery действие = «Отдать курьеру».
class TransferAdvanceAction {
  const TransferAdvanceAction({
    required this.run,
    required this.tooltip,
  });

  final VoidCallback run;
  final String tooltip;

  /// Тип счёта получателя: cash/card. Null если to_account ещё не задан
  /// (бывает у переводов на момент `created`).
  static AccountType? receiverAccountType(BuildContext context, Transfer t) {
    if (t.toAccountId.isEmpty) return null;
    try {
      final accounts = context
          .read<DashboardBloc>()
          .state
          .branchAccounts[t.toBranchId];
      if (accounts == null) return null;
      final match = accounts.where((a) => a.id == t.toAccountId).firstOrNull;
      return match?.type;
    } catch (_) {
      return null;
    }
  }

  /// True если перевод на КАРТУ — курьерская доставка пропускается.
  static bool isCardTransfer(BuildContext context, Transfer t) =>
      receiverAccountType(context, t) == AccountType.card;

  static TransferAdvanceAction? resolve(
    BuildContext context,
    Transfer t, {
    VoidCallback? onShowDetails,
  }) {
    final user = context.read<AuthBloc>().state.user;
    if (user == null) return null;

    bool isInBranch(String branchId) {
      if (user.role.isAdminOrCreator || user.role.isDirector) return true;
      return user.assignedBranchIds.contains(branchId);
    }

    switch (t.status) {
      case TransferStatus.created:
        if (!isInBranch(t.toBranchId)) return null;
        return TransferAdvanceAction(
          tooltip: 'Принять перевод → К выдаче',
          run: () {
            if (t.toAccountId.isNotEmpty) {
              context.read<TransferBloc>().add(TransferConfirmRequested(t.id));
            } else {
              showAcceptTransferAccountDialog(context, t);
            }
          },
        );
      case TransferStatus.toDelivery:
        final card = isCardTransfer(context, t);
        if (card) {
          // Card flow: пропускаем курьера. Жмёт получающий филиал.
          if (!isInBranch(t.toBranchId)) return null;
          if (onShowDetails == null) return null;
          return TransferAdvanceAction(
            tooltip: 'Выдать получателю → Выдан',
            run: onShowDetails,
          );
        }
        // Cash flow: отдать курьеру может только отправляющий филиал.
        if (!isInBranch(t.fromBranchId)) return null;
        return TransferAdvanceAction(
          tooltip: 'Отдать курьеру → У курьера',
          run: () => showDispatchCourierDialog(context, t),
        );
      case TransferStatus.withCourier:
        if (!isInBranch(t.toBranchId)) return null;
        if (onShowDetails == null) return null;
        return TransferAdvanceAction(
          tooltip: 'Открыть выдачу → Выдан',
          run: onShowDetails,
        );
      case TransferStatus.delivered:
        return null;
    }
  }
}
