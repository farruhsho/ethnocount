import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_branding.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';

/// Top chrome bar from the `transfer-create-desktop` reference: gradient
/// monogram tile, breadcrumb (ETHNO › Переводы › Новый перевод), "session
/// secured" pulse pill on the right, and a Cancel button with the Esc hint.
///
/// Implements [PreferredSizeWidget] so it can be dropped straight into a
/// [Scaffold.appBar] slot on desktop+dark theme.
class TransferTopChrome extends StatelessWidget implements PreferredSizeWidget {
  const TransferTopChrome({
    super.key,
    required this.operatorName,
    required this.operatorBranchCode,
    required this.onCancel,
    this.crumbs = const ['Переводы', 'Новый перевод'],
  });

  final String operatorName;
  final String operatorBranchCode;
  final VoidCallback onCancel;
  final List<String> crumbs;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xCC07091C),
        border: Border(
          bottom: BorderSide(color: AppColors.darkBorder, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          _Monogram(),
          const SizedBox(width: 12),
          ..._buildCrumbs(),
          const Spacer(),
          _SecureSessionPill(
            operatorName: operatorName,
            operatorBranchCode: operatorBranchCode,
          ),
          const SizedBox(width: 10),
          _CancelButton(onTap: onCancel),
        ],
      ),
    );
  }

  List<Widget> _buildCrumbs() {
    final widgets = <Widget>[
      Text(
        kAppDisplayName.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: AppColors.darkTextTertiary,
        ),
      ),
    ];
    for (var i = 0; i < crumbs.length; i++) {
      widgets.add(const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(
          Icons.chevron_right,
          size: 14,
          color: AppColors.darkTextDisabled,
        ),
      ));
      final isLast = i == crumbs.length - 1;
      widgets.add(Text(
        crumbs[i],
        style: GoogleFonts.inter(
          fontSize: isLast ? 13 : 12.5,
          fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
          color: isLast
              ? AppColors.darkTextPrimary
              : AppColors.darkTextSecondary,
        ),
      ));
    }
    return widgets;
  }
}

class _Monogram extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Text(
        kAppMonogram,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w900,
          color: AppColors.darkBg,
          height: 1,
        ),
      ),
    );
  }
}

class _SecureSessionPill extends StatelessWidget {
  const _SecureSessionPill({
    required this.operatorName,
    required this.operatorBranchCode,
  });
  final String operatorName;
  final String operatorBranchCode;

  @override
  Widget build(BuildContext context) {
    final operatorChunk = operatorName.isEmpty
        ? ''
        : ' · $operatorName${operatorBranchCode.isEmpty ? '' : ' · $operatorBranchCode'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.6),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Сессия защищена',
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: AppColors.darkTextSecondary,
            ),
          ),
          if (operatorChunk.isNotEmpty)
            Text(
              operatorChunk,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
        ],
      ),
    );
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppIcons.close,
                  size: 13, color: AppColors.darkTextSecondary),
              const SizedBox(width: 6),
              Text(
                'Отменить',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.darkTextSecondary,
                ),
              ),
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.darkSurface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Esc',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
