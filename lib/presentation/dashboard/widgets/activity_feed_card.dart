import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

enum ActivityFilter { all, incoming, outgoing, transfers }

extension on ActivityFilter {
  String get label => switch (this) {
        ActivityFilter.all => 'Все',
        ActivityFilter.incoming => 'Поступления',
        ActivityFilter.outgoing => 'Расходы',
        ActivityFilter.transfers => 'Переводы',
      };
}

class ActivityItem {
  const ActivityItem({
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.currency,
    required this.icon,
    required this.color,
    required this.time,
    this.kind = ActivityFilter.transfers,
  });
  final String title;
  final String subtitle;
  final double amount;
  final String currency;
  final IconData icon;
  final Color color;
  final DateTime time;
  final ActivityFilter kind;
}

/// Лента событий: подписана на `TransferRepository.watchTransfers()` и
/// показывает 12 самых свежих переводов всех статусов. Цвет/иконка зависят
/// от статуса. Chip-фильтр: Все / Поступления / Расходы / Переводы.
class ActivityFeedCard extends StatelessWidget {
  const ActivityFeedCard({
    super.key,
    this.title = 'Лента событий',
  });

  final String title;

  /// Маппинг Transfer → ActivityItem (статус → иконка/цвет).
  static ActivityItem _itemFor(Transfer t) {
    final (icon, color, kind, label) = switch (t.status) {
      TransferStatus.pending => (
        Icons.pending_actions_rounded,
        AppColors.warning,
        ActivityFilter.transfers,
        'Перевод создан',
      ),
      TransferStatus.confirmed => (
        Icons.task_alt_rounded,
        AppColors.secondary,
        ActivityFilter.transfers,
        'Перевод подтверждён',
      ),
      TransferStatus.issued => (
        Icons.payments_rounded,
        AppColors.primary,
        ActivityFilter.outgoing,
        'Выдан получателю',
      ),
      TransferStatus.rejected => (
        Icons.cancel_outlined,
        AppColors.error,
        ActivityFilter.transfers,
        'Отклонён',
      ),
      TransferStatus.cancelled => (
        Icons.do_disturb_alt_rounded,
        AppColors.darkTextSecondary,
        ActivityFilter.transfers,
        'Отменён',
      ),
    };
    return ActivityItem(
      title: '$label · #${t.transactionCode ?? t.id.substring(0, 6)}',
      subtitle: '${t.senderName ?? '—'} → ${t.receiverName ?? '—'}',
      amount: t.amount,
      currency: t.currency,
      icon: icon,
      color: color,
      time: (t.issuedAt ?? t.confirmedAt ?? t.cancelledAt ?? t.rejectedAt ?? t.createdAt),
      kind: kind,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Transfer>>(
      stream: sl<TransferRepository>().watchTransfers(),
      builder: (context, snap) {
        final all = snap.data ?? const <Transfer>[];
        DateTime ts(Transfer t) => t.issuedAt ??
            t.confirmedAt ??
            t.cancelledAt ??
            t.rejectedAt ??
            t.createdAt;
        final sorted = [...all]..sort((a, b) => ts(b).compareTo(ts(a)));
        final items = sorted
            .take(12)
            .map(_itemFor)
            .toList();
        return _ActivityFeedView(
          title: title,
          items: items,
          loading: snap.connectionState == ConnectionState.waiting && all.isEmpty,
        );
      },
    );
  }
}

class _ActivityFeedView extends StatefulWidget {
  const _ActivityFeedView({
    required this.title,
    required this.items,
    required this.loading,
  });
  final String title;
  final List<ActivityItem> items;
  final bool loading;

  @override
  State<_ActivityFeedView> createState() => _ActivityFeedCardState();
}

class _ActivityFeedCardState extends State<_ActivityFeedView> {
  ActivityFilter _filter = ActivityFilter.all;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final filtered = _filter == ActivityFilter.all
        ? widget.items
        : widget.items.where((i) => i.kind == _filter).toList();

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? AppColors.darkTextPrimary
                  : AppColors.lightTextPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ActivityFilter.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final f = ActivityFilter.values[i];
                final selected = f == _filter;
                return InkWell(
                  onTap: () => setState(() => _filter = f),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primary.withValues(alpha: 0.12)
                          : (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.04),
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusFull),
                      border: selected
                          ? Border.all(
                              color:
                                  AppColors.primary.withValues(alpha: 0.4),
                              width: 0.5,
                            )
                          : null,
                    ),
                    child: Text(
                      f.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: selected ? AppColors.primary : secondary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: Text(
                  'Нет событий',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ),
            )
          else
            for (var i = 0; i < filtered.length; i++) ...[
              _ActivityRow(item: filtered[i]),
              if (i != filtered.length - 1)
                Divider(
                  height: AppSpacing.sm,
                  thickness: 0.4,
                  color: secondary.withValues(alpha: 0.15),
                ),
            ],
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item});
  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(item.icon, color: item.color, size: 16),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  item.subtitle,
                  style: TextStyle(fontSize: 10.5, color: secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${_compact(item.amount)} ${item.currency}',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: item.color,
                ),
              ),
              Text(
                item.time.historyFormatted,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: secondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}
