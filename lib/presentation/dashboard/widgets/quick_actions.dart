import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/routing/route_names.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

class TreasuryQuickActions extends StatelessWidget {
  const TreasuryQuickActions({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final canBranchTopUp =
        context.read<AuthBloc>().state.user?.canBranchTopUp ?? false;
    final actions = [
      _Action(
        Icons.add_circle_outline_rounded,
        'Новый перевод',
        () => context.goNamed(RouteNames.createTransfer),
        AppColors.primary,
      ),
      _Action(
        Icons.receipt_long_rounded,
        'Журнал',
        () => context.go('/ledger'),
        AppColors.secondary,
      ),
      _Action(
        Icons.upload_file_rounded,
        'Импорт',
        () => context.go('/bank-import'),
        AppColors.primary,
        subtitle: 'из банка',
      ),
      if (canBranchTopUp)
        _Action(
          Icons.add_business_rounded,
          'Пополнение',
          () => context.go('/transfers/topup'),
          AppColors.secondary,
          subtitle: 'филиала',
        ),
      _Action(
        Icons.notifications_active_outlined,
        'Уведомления',
        () => context.go('/notifications'),
        AppColors.warning,
      ),
    ];

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: actions
            .map(
              (a) => Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _CompactIconAction(action: a),
              ),
            )
            .toList(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = AppSpacing.sm;
        final cols = constraints.maxWidth >= 360 ? 3 : 2;
        final tileW = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: actions
              .map(
                (a) => SizedBox(
                  width: tileW,
                  child: _QuickActionTile(action: a),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _Action {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  final String? subtitle;

  const _Action(
    this.icon,
    this.label,
    this.onTap,
    this.color, {
    this.subtitle,
  });
}

/// Header row: icon-only + tooltip (no long text on buttons).
class _CompactIconAction extends StatelessWidget {
  const _CompactIconAction({required this.action});

  final _Action action;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: action.subtitle != null
          ? '${action.label} ${action.subtitle}'
          : action.label,
      child: Material(
        color: action.color.withValues(alpha: 0.12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: action.onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(action.icon, size: 22, color: action.color),
          ),
        ),
      ),
    );
  }
}

/// Overview / mobile: large icon + short caption (icon reads first).
class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action});

  final _Action action;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final border = isDark ? AppColors.darkBorder : AppColors.lightBorder;

    return Material(
      color: isDark ? AppColors.darkCard : AppColors.lightSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(color: border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: action.color.withValues(alpha: isDark ? 0.18 : 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(action.icon, color: action.color, size: 26),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                action.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
              if (action.subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  action.subtitle!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
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
