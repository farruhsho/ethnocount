import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';

/// "Account picker" 3-column grid from the `transfer-create-desktop`
/// reference. Each card shows a currency mono badge, name, balance and a
/// selected checkmark. Reflows to 2 / 1 columns on narrower widths.
///
/// Balances are read via [balanceLookup] so the parent can plug in either a
/// DashboardBloc cache or a stream snapshot without coupling this widget to
/// any specific source.
class AccountPickerGrid extends StatelessWidget {
  const AccountPickerGrid({
    super.key,
    required this.accounts,
    required this.selectedId,
    required this.onSelected,
    required this.balanceLookup,
    this.columns = 3,
  });

  final List<BranchAccount> accounts;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final double Function(String accountId) balanceLookup;

  /// Fixed column count. Default `3` matches the desktop+dark hero. Pass
  /// `1` on mobile bottom sheets.
  final int columns;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.darkCard,
          border: Border.all(
            color: AppColors.darkBorder,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'Сначала выберите филиал отправителя',
            style: GoogleFonts.inter(
              fontSize: 12.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
        ),
      );
    }
    // LayoutBuilder removed for Flutter web mouse_tracker compatibility.
    // The grid now uses a fixed column count chosen via [columns]; callers
    // pass 3 on desktop+dark hero and 1 on mobile.
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: accounts.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 78,
      ),
      itemBuilder: (ctx, i) {
        final a = accounts[i];
        final active = a.id == selectedId;
        final balance = balanceLookup(a.id);
        return _AccountCard(
          account: a,
          balance: balance,
          active: active,
          onTap: () => onSelected(a.id),
        );
      },
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.balance,
    required this.active,
    required this.onTap,
  });
  final BranchAccount account;
  final double balance;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: active ? AppColors.darkCard : AppColors.darkSurface,
            gradient: active
                ? LinearGradient(
                    colors: [
                      AppColors.primary.withValues(alpha: 0.16),
                      Colors.transparent,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? AppColors.primary : AppColors.darkBorder,
              width: active ? 1.2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.primary
                      : AppColors.darkCardHover,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  account.currency,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: active
                        ? AppColors.darkBg
                        : AppColors.darkTextSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Касса ${account.currency}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: AppColors.darkTextTertiary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      balance.formatCurrencyNoDecimals(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: balance < 0
                            ? AppColors.error
                            : AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              if (active)
                Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    AppIcons.check,
                    size: 11,
                    color: AppColors.darkBg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
