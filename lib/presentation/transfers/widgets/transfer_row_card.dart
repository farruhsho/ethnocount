import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Compact mobile-friendly transfer row from the `transfers-mobile`
/// reference: status-coloured left accent, FROM→TO branch code pills + a
/// status pill on top, mono amount + receiver/time on the second line, ID
/// muted at the bottom.
class TransferRowCard extends StatelessWidget {
  const TransferRowCard({
    super.key,
    required this.id,
    required this.status,
    required this.fromBranchCode,
    required this.toBranchCode,
    required this.amount,
    required this.currency,
    required this.toCurrency,
    required this.received,
    required this.receiverName,
    required this.createdAt,
    required this.onTap,
    this.dense = false,
    this.partnerName,
  });

  final String id;
  final TransferStatus status;
  final String fromBranchCode;
  final String toBranchCode;
  final double amount;
  final String currency;
  final String toCurrency;
  final double received;
  final String receiverName;
  final DateTime createdAt;
  final VoidCallback onTap;
  final bool dense;

  /// Если перевод выплачен через партнёра — имя counterparty. NULL =
  /// обычный (внутрифирменный) перевод. Используется чтобы оператор
  /// сразу видел в списке: «эта запись через Бахрома в Москве», а не
  /// открывал каждую детальку.
  final String? partnerName;

  Color get _statusColor {
    switch (status) {
      case TransferStatus.created:
        return AppColors.warning;
      case TransferStatus.toDelivery:
        return AppColors.secondary;
      case TransferStatus.withCourier:
        return AppColors.purple;
      case TransferStatus.delivered:
        return AppColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.fromLTRB(12, dense ? 10 : 12, 12, dense ? 10 : 12),
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            border: Border(
              top: const BorderSide(color: AppColors.darkBorder),
              right: const BorderSide(color: AppColors.darkBorder),
              bottom: const BorderSide(color: AppColors.darkBorder),
              left: BorderSide(color: color, width: 3),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopRow(
                fromCode: fromBranchCode,
                toCode: toBranchCode,
                statusLabel: status.displayName,
                statusColor: color,
                partnerName: partnerName,
              ),
              SizedBox(height: dense ? 7 : 9),
              _AmountRow(
                amount: amount,
                currency: currency,
                received: received,
                toCurrency: toCurrency,
                receiverName: receiverName,
                createdAt: createdAt,
              ),
              SizedBox(height: dense ? 5 : 7),
              Text(
                id,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: AppColors.darkTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow({
    required this.fromCode,
    required this.toCode,
    required this.statusLabel,
    required this.statusColor,
    this.partnerName,
  });
  final String fromCode;
  final String toCode;
  final String statusLabel;
  final Color statusColor;
  final String? partnerName;
  @override
  Widget build(BuildContext context) {
    final hasPartner = partnerName != null && partnerName!.trim().isNotEmpty;
    return Row(
      children: [
        _CodePill(fromCode),
        const SizedBox(width: 5),
        Icon(AppIcons.arrow_forward,
            size: 11, color: AppColors.darkTextTertiary),
        const SizedBox(width: 5),
        _CodePill(toCode),
        if (hasPartner) ...[
          const SizedBox(width: 6),
          // Партнёр-чип: иконка ⇄ + имя counterparty в одном пилле.
          // Цвет — purple (как в desktop-колонке «Партнёр»), фон с
          // прозрачностью чтобы не перебивал статус.
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: 0.12),
                border: Border.all(
                  color: AppColors.purple.withValues(alpha: 0.25),
                ),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.swap_horiz,
                      size: 10, color: AppColors.purple),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      partnerName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.purple,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const Spacer(),
        _StatusPill(label: statusLabel, color: statusColor),
      ],
    );
  }
}

class _CodePill extends StatelessWidget {
  const _CodePill(this.code);
  final String code;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.amount,
    required this.currency,
    required this.received,
    required this.toCurrency,
    required this.receiverName,
    required this.createdAt,
  });
  final double amount;
  final String currency;
  final double received;
  final String toCurrency;
  final String receiverName;
  final DateTime createdAt;

  String _fmtTime(DateTime d) {
    final months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)} ${months[d.month - 1]} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${amount.formatCurrencyNoDecimals()} $currency',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.darkTextPrimary,
                ),
              ),
              if (currency != toCurrency && received > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '→ ${received.formatCurrencyNoDecimals()} $toCurrency',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                receiverName.isEmpty ? '—' : receiverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.darkTextPrimary,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _fmtTime(createdAt),
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
