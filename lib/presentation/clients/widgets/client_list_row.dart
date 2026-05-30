import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/domain/entities/client.dart';

/// Compact client row from `clients-desktop` reference: gradient avatar
/// with initials, code-pill (CNT-XXXX) + name, phone or sub line, primary
/// balance right-aligned (red if any wallet < 0), "+N валют" indicator
/// when the client has more than one currency.
class ClientListRow extends StatelessWidget {
  const ClientListRow({
    super.key,
    required this.client,
    required this.balance,
    required this.selected,
    required this.onTap,
    this.hasTelegram = false,
  });

  final Client client;
  final ClientBalance? balance;
  final bool selected;
  final VoidCallback onTap;
  final bool hasTelegram;

  static const _gradients = <List<Color>>[
    [Color(0xFF00D1A0), Color(0xFF4C7CF5)],
    [Color(0xFF4C7CF5), Color(0xFF9B59B6)],
    [Color(0xFFFFAA2B), Color(0xFFFF4757)],
    [Color(0xFF00D1A0), Color(0xFFFFAA2B)],
    [Color(0xFF9B59B6), Color(0xFF4C7CF5)],
  ];

  String _initials() {
    final parts = client.name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  List<Color> _gradient() {
    final hash = client.id.hashCode.abs();
    return _gradients[hash % _gradients.length];
  }

  bool get _hasNegative {
    final b = balance;
    if (b == null) return false;
    if (b.balance < 0) return true;
    for (final v in b.balancesByCurrency.values) {
      if (v < 0) return true;
    }
    return false;
  }

  int get _extraCurrencies {
    final b = balance;
    if (b == null) return 0;
    final all = b.balancesByCurrency.keys.toSet();
    all.add(b.currency);
    return all.length - 1;
  }

  String _formattedCode() {
    // Normalize "CL-2026-000142" / arbitrary code → "CNT-0142" to match
    // the design's compact pill. Falls back to the raw code if there are
    // no digits to extract.
    final digits = client.clientCode.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return client.clientCode;
    final trimmed = digits.length > 4
        ? digits.substring(digits.length - 4)
        : digits.padLeft(4, '0');
    return 'CNT-$trimmed';
  }

  @override
  Widget build(BuildContext context) {
    final negativeBal = _hasNegative;
    final extra = _extraCurrencies;
    final balanceText = balance == null
        ? '—'
        : balance!.balance.formatCurrencyNoDecimals();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              decoration: BoxDecoration(
                color: selected ? AppColors.darkCardHover : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? AppColors.darkBorder
                      : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  _Avatar(
                    initials: _initials(),
                    gradient: _gradient(),
                    telegram: hasTelegram,
                    archived: !client.isActive,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppColors.darkSurface,
                                border:
                                    Border.all(color: AppColors.darkBorder),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                _formattedCode(),
                                style: GoogleFonts.jetBrainsMono(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.darkTextTertiary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                client.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: client.isActive
                                      ? AppColors.darkTextPrimary
                                      : AppColors.darkTextTertiary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          client.phone.isEmpty ? '—' : client.phone,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            color: AppColors.darkTextTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        balanceText,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: negativeBal
                              ? AppColors.error
                              : AppColors.darkTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        balance?.currency ?? client.currency,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: AppColors.darkTextTertiary,
                        ),
                      ),
                      if (extra > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.secondary
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(100),
                            ),
                            child: Text(
                              '+$extra валют',
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (selected)
          Positioned(
            left: -2,
            top: 10,
            bottom: 10,
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

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.initials,
    required this.gradient,
    required this.telegram,
    required this.archived,
  });
  final String initials;
  final List<Color> gradient;
  final bool telegram;
  final bool archived;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: archived
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: gradient,
                    ),
              color: archived ? AppColors.darkCardHover : null,
              border: archived
                  ? Border.all(color: AppColors.darkBorder)
                  : null,
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: archived
                    ? AppColors.darkTextTertiary
                    : AppColors.darkBg,
                height: 1,
              ),
            ),
          ),
          if (telegram)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: AppColors.telegram,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: AppColors.darkSurface, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  'T',
                  style: GoogleFonts.inter(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
