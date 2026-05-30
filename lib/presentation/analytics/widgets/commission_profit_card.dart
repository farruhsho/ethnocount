import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/data/datasources/remote/analytics_remote_ds.dart';
import 'package:ethnocount/domain/entities/commission_profit.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

/// Период — пресет для быстрого выбора даты в фильтре карточки.
enum CommissionProfitPeriod {
  today,
  yesterday,
  week,
  month,
  year,
  all,
}

extension on CommissionProfitPeriod {
  String get label {
    switch (this) {
      case CommissionProfitPeriod.today:
        return 'Сегодня';
      case CommissionProfitPeriod.yesterday:
        return 'Вчера';
      case CommissionProfitPeriod.week:
        return 'Неделя';
      case CommissionProfitPeriod.month:
        return 'Месяц';
      case CommissionProfitPeriod.year:
        return 'Год';
      case CommissionProfitPeriod.all:
        return 'Всё время';
    }
  }

  /// Returns `(start, end)`. End is exclusive (next-day boundary).
  (DateTime?, DateTime?) range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    switch (this) {
      case CommissionProfitPeriod.today:
        return (today, tomorrow);
      case CommissionProfitPeriod.yesterday:
        return (today.subtract(const Duration(days: 1)), today);
      case CommissionProfitPeriod.week:
        return (today.subtract(const Duration(days: 7)), tomorrow);
      case CommissionProfitPeriod.month:
        return (DateTime(now.year, now.month, 1), tomorrow);
      case CommissionProfitPeriod.year:
        return (DateTime(now.year, 1, 1), tomorrow);
      case CommissionProfitPeriod.all:
        return (null, null);
    }
  }
}

/// Self-contained analytics card: commission income per branch × currency
/// with a period filter chip strip. Designed to drop into the existing
/// analytics page as a regular Column child.
///
/// Visibility: accountants see only their assigned branches (passes
/// `accessibleBranchIds(user)` to the RPC); creator/director see all.
class CommissionProfitCard extends StatefulWidget {
  const CommissionProfitCard({super.key});

  @override
  State<CommissionProfitCard> createState() => _CommissionProfitCardState();
}

class _CommissionProfitCardState extends State<CommissionProfitCard> {
  final _ds = sl<AnalyticsRemoteDataSource>();
  CommissionProfitPeriod _period = CommissionProfitPeriod.month;
  CommissionProfitReport? _report;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final user = context.read<AuthBloc>().state.user;
    final allowed = accessibleBranchIds(user); // null = creator/director
    final (start, end) = _period.range();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await _ds.fetchCommissionProfit(
        start: start,
        end: end,
        branchIds: allowed?.toList(),
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(onRefresh: _reload),
          const SizedBox(height: AppSpacing.md),
          _PeriodChips(
            value: _period,
            onChanged: (p) {
              setState(() => _period = p);
              _reload();
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorBox(error: _error!, onRetry: _reload)
          else if (_report == null || _report!.isEmpty)
            const _EmptyBox()
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TotalsStrip(totals: _report!.totals),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'По филиалам и валютам',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _BranchTable(rows: _report!.rows),
              ],
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh});
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(AppIcons.payments,
              size: 18, color: AppColors.primary),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Прибыль с комиссий',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'По филиалам и валютам за выбранный период',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Обновить',
          onPressed: onRefresh,
          icon: const Icon(AppIcons.refresh, size: 18),
          color: scheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

class _PeriodChips extends StatelessWidget {
  const _PeriodChips({required this.value, required this.onChanged});
  final CommissionProfitPeriod value;
  final ValueChanged<CommissionProfitPeriod> onChanged;
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final p in CommissionProfitPeriod.values) ...[
            _Chip(
              label: p.label,
              active: p == value,
              onTap: () => onChanged(p),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? AppColors.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            border: Border.all(
              color: active
                  ? AppColors.primary
                  : scheme.outline.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals});
  final List<CommissionProfitTotal> totals;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (totals.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Text(
          'За выбранный период нет операций.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: totals.map((t) => _TotalTile(total: t)).toList(),
    );
  }
}

class _TotalTile extends StatelessWidget {
  const _TotalTile({required this.total});
  final CommissionProfitTotal total;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      constraints: const BoxConstraints(minWidth: 150),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            total.currency,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            total.totalCommission.formatCurrencyNoDecimals(),
            style: GoogleFonts.jetBrainsMono(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${total.transferCount} ${_plural(total.transferCount)}',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _plural(int n) {
    final m100 = n % 100;
    final m10 = n % 10;
    if (m100 >= 11 && m100 <= 14) return 'переводов';
    if (m10 == 1) return 'перевод';
    if (m10 >= 2 && m10 <= 4) return 'перевода';
    return 'переводов';
  }
}

class _BranchTable extends StatelessWidget {
  const _BranchTable({required this.rows});
  final List<CommissionProfitRow> rows;

  @override
  Widget build(BuildContext context) {
    // Группируем по branch: [{branchName, code, [(currency, count, amount)]}]
    final groups = <String, List<CommissionProfitRow>>{};
    for (final r in rows) {
      groups.putIfAbsent(r.branchId, () => []).add(r);
    }
    final orderedBranchIds = groups.keys.toList()
      ..sort((a, b) => groups[a]!.first.branchName
          .compareTo(groups[b]!.first.branchName));

    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < orderedBranchIds.length; i++) ...[
            _BranchBlock(
              branchName: groups[orderedBranchIds[i]]!.first.branchName,
              branchCode: groups[orderedBranchIds[i]]!.first.branchCode,
              rows: groups[orderedBranchIds[i]]!,
              isLast: i == orderedBranchIds.length - 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _BranchBlock extends StatelessWidget {
  const _BranchBlock({
    required this.branchName,
    required this.branchCode,
    required this.rows,
    required this.isLast,
  });
  final String branchName;
  final String branchCode;
  final List<CommissionProfitRow> rows;
  final bool isLast;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: scheme.outline.withValues(alpha: 0.12),
                ),
              ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.25),
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  branchCode,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  branchName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      r.currency,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${r.transferCount} ${_pluralRu(r.transferCount)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    r.totalCommission.formatCurrencyNoDecimals(),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _pluralRu(int n) {
    final m100 = n % 100;
    final m10 = n % 10;
    if (m100 >= 11 && m100 <= 14) return 'переводов';
    if (m10 == 1) return 'перевод';
    if (m10 >= 2 && m10 <= 4) return 'перевода';
    return 'переводов';
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.18),
          style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.inbox,
              size: 28, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
          const SizedBox(height: 8),
          Text(
            'Нет комиссионных операций',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'За выбранный период комиссии не начислялись.',
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(AppIcons.error_outline,
              size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Не удалось загрузить отчёт',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.error,
                  ),
                ),
                Text(
                  error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.error,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
