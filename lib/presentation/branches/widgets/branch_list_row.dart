import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/presentation/transfers/widgets/live_receipt_preview.dart'
    show flagForBranchCountry, shortBranchCode;

/// "Branch row" card matching `branches-desktop` reference: 42-px flag tile
/// with a status dot in the corner, code-pill + name on the top line,
/// accounts/staff/warning summary in the middle, base-currency balance
/// right-aligned. Selected state shows a 3-px primary accent strip on the
/// left and a card-2 background.
class BranchListRow extends StatelessWidget {
  const BranchListRow({
    super.key,
    required this.branch,
    required this.selected,
    required this.onTap,
    required this.accountsCount,
    required this.staffCount,
    required this.baseBalance,
    this.hasWarning = false,
  });

  final Branch branch;
  final bool selected;
  final VoidCallback onTap;
  final int accountsCount;
  final int staffCount;
  final double baseBalance;
  final bool hasWarning;

  Color get _statusColor {
    if (!branch.isActive) return AppColors.darkTextDisabled;
    if (hasWarning) return AppColors.warning;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(11, 11, 11, 11),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.darkCardHover
                    : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? AppColors.darkBorder
                      : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  _FlagTile(
                    flag: flagForBranchCountry(branch.address),
                    statusColor: _statusColor,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TopLine(
                          code: shortBranchCode(branch.name,
                              explicitCode: branch.code),
                          name: branch.name,
                          archived: !branch.isActive,
                        ),
                        const SizedBox(height: 4),
                        _SubLine(
                          accountsCount: accountsCount,
                          staffCount: staffCount,
                          warning: hasWarning,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _BalanceColumn(
                    balance: baseBalance,
                    currency: branch.baseCurrency,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (selected)
          Positioned(
            left: -2,
            top: 12,
            bottom: 12,
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}

class _FlagTile extends StatelessWidget {
  const _FlagTile({required this.flag, required this.statusColor});
  final String flag;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 42,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              border: Border.all(color: AppColors.darkBorder),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Text(flag, style: const TextStyle(fontSize: 22)),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.darkSurface,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: 0.4),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopLine extends StatelessWidget {
  const _TopLine({
    required this.code,
    required this.name,
    required this.archived,
  });
  final String code;
  final String name;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            code,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.darkTextSecondary,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: archived
                  ? AppColors.darkTextTertiary
                  : AppColors.darkTextPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _SubLine extends StatelessWidget {
  const _SubLine({
    required this.accountsCount,
    required this.staffCount,
    required this.warning,
  });
  final int accountsCount;
  final int staffCount;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final mutedStyle = GoogleFonts.inter(
      fontSize: 11,
      color: AppColors.darkTextTertiary,
    );
    final warnStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: AppColors.warning,
    );
    return DefaultTextStyle.merge(
      style: mutedStyle,
      child: Row(
        children: [
          Text('$accountsCount счёта'),
          const _Dot(),
          Text('$staffCount чел.'),
          if (warning) ...[
            const _Dot(),
            Icon(AppIcons.error_outline,
                size: 10, color: AppColors.warning),
            const SizedBox(width: 3),
            Text('Внимание', style: warnStyle),
          ],
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 5),
      child: Text('·', style: TextStyle(color: AppColors.darkTextDisabled)),
    );
  }
}

class _BalanceColumn extends StatelessWidget {
  const _BalanceColumn({required this.balance, required this.currency});
  final double balance;
  final String currency;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          balance.formatCurrencyNoDecimals(),
          style: GoogleFonts.jetBrainsMono(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.darkTextPrimary,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          currency,
          style: GoogleFonts.inter(
            fontSize: 10.5,
            color: AppColors.darkTextTertiary,
          ),
        ),
      ],
    );
  }
}
