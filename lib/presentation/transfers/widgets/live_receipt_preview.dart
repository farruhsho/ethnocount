import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_branding.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';

/// Tilted "thermal-printer" receipt preview matching the
/// `transfer-create-desktop` reference design.
///
/// Perforated top/bottom edges (bg-colored dots), ETHNO TREASURY header,
/// route pills, hero received amount, line items, operator + signature.
/// Pure presentation — takes all numbers via constructor, no BLoCs.
class LiveReceiptPreview extends StatelessWidget {
  const LiveReceiptPreview({
    super.key,
    required this.fromBranchName,
    required this.fromBranchCode,
    required this.fromCountryFlag,
    required this.toBranchName,
    required this.toBranchCode,
    required this.toCountryFlag,
    required this.fromCurrency,
    required this.toCurrency,
    required this.amount,
    required this.received,
    required this.rate,
    required this.commissionLabel,
    required this.commission,
    required this.commissionCurrency,
    required this.commissionPayer,
    required this.totalDebit,
    required this.senderName,
    required this.senderPhone,
    required this.receiverName,
    required this.receiverPhone,
    required this.description,
    required this.operatorName,
    required this.operatorBranchCode,
    required this.draftId,
    this.insufficient = false,
    this.compact = false,
  });

  final String fromBranchName;
  final String fromBranchCode;
  final String fromCountryFlag;
  final String toBranchName;
  final String toBranchCode;
  final String toCountryFlag;
  final String fromCurrency;
  final String toCurrency;
  final double amount;
  final double received;
  final double rate;
  final String commissionLabel;
  final double commission;
  final String commissionCurrency;
  final String commissionPayer;
  final double totalDebit;
  final String senderName;
  final String senderPhone;
  final String receiverName;
  final String receiverPhone;
  final String description;
  final String operatorName;
  final String operatorBranchCode;
  final String draftId;
  final bool insufficient;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pageBg = Theme.of(context).scaffoldBackgroundColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(),
        const SizedBox(height: AppSpacing.md),
        Transform.rotate(
          angle: -0.007, // ≈ -0.4°
          child: _ReceiptCard(
            pageBg: pageBg,
            fromBranchName: fromBranchName,
            fromBranchCode: fromBranchCode,
            fromCountryFlag: fromCountryFlag,
            toBranchName: toBranchName,
            toBranchCode: toBranchCode,
            toCountryFlag: toCountryFlag,
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            amount: amount,
            received: received,
            rate: rate,
            commissionLabel: commissionLabel,
            commission: commission,
            commissionCurrency: commissionCurrency,
            commissionPayer: commissionPayer,
            totalDebit: totalDebit,
            senderName: senderName,
            senderPhone: senderPhone,
            receiverName: receiverName,
            receiverPhone: receiverPhone,
            description: description,
            operatorName: operatorName,
            operatorBranchCode: operatorBranchCode,
            draftId: draftId,
            insufficient: insufficient,
            compact: compact,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(AppIcons.receipt_long, size: 14, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          'ПРЕДПРОСМОТР КВИТАНЦИИ',
          style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: AppColors.darkTextSecondary,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.12),
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            'ЧЕРНОВИК',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({
    required this.pageBg,
    required this.fromBranchName,
    required this.fromBranchCode,
    required this.fromCountryFlag,
    required this.toBranchName,
    required this.toBranchCode,
    required this.toCountryFlag,
    required this.fromCurrency,
    required this.toCurrency,
    required this.amount,
    required this.received,
    required this.rate,
    required this.commissionLabel,
    required this.commission,
    required this.commissionCurrency,
    required this.commissionPayer,
    required this.totalDebit,
    required this.senderName,
    required this.senderPhone,
    required this.receiverName,
    required this.receiverPhone,
    required this.description,
    required this.operatorName,
    required this.operatorBranchCode,
    required this.draftId,
    required this.insufficient,
    required this.compact,
  });

  final Color pageBg;
  final String fromBranchName;
  final String fromBranchCode;
  final String fromCountryFlag;
  final String toBranchName;
  final String toBranchCode;
  final String toCountryFlag;
  final String fromCurrency;
  final String toCurrency;
  final double amount;
  final double received;
  final double rate;
  final String commissionLabel;
  final double commission;
  final String commissionCurrency;
  final String commissionPayer;
  final double totalDebit;
  final String senderName;
  final String senderPhone;
  final String receiverName;
  final String receiverPhone;
  final String description;
  final String operatorName;
  final String operatorBranchCode;
  final String draftId;
  final bool insufficient;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final cardChild = Container(
      padding: EdgeInsets.fromLTRB(
        compact ? 18 : 22,
        compact ? 18 : 22,
        compact ? 18 : 24,
        14,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A2138), Color(0xFF161C30)],
        ),
        borderRadius: radius,
        border: Border.all(color: AppColors.darkBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 70,
            offset: const Offset(0, 30),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(draftId: draftId),
          const SizedBox(height: 18),
          _RoutePills(
            fromFlag: fromCountryFlag,
            fromCode: fromBranchCode,
            fromCity: fromBranchName,
            toFlag: toCountryFlag,
            toCode: toBranchCode,
            toCity: toBranchName,
          ),
          const SizedBox(height: 18),
          _Hero(
            amount: amount,
            received: received,
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            insufficient: insufficient,
          ),
          _Lines(
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            rate: rate,
            commissionLabel: commissionLabel,
            commission: commission,
            commissionCurrency: commissionCurrency,
            commissionPayer: commissionPayer,
            totalDebit: totalDebit,
            senderName: senderName,
            senderPhone: senderPhone,
            receiverName: receiverName,
            receiverPhone: receiverPhone,
            description: description,
          ),
          const SizedBox(height: 14),
          _Footer(
            operatorName: operatorName,
            operatorBranchCode: operatorBranchCode,
          ),
        ],
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        cardChild,
        Positioned(top: -8, left: 6, right: 6, child: _PerforatedRow(bg: pageBg)),
        Positioned(bottom: -8, left: 6, right: 6, child: _PerforatedRow(bg: pageBg)),
      ],
    );
  }
}

class _PerforatedRow extends StatelessWidget {
  const _PerforatedRow({required this.bg});
  final Color bg;
  @override
  Widget build(BuildContext context) {
    // Fixed 20-dot count (was a LayoutBuilder). The receipt card width is
    // bounded by the 480-px right column → at ~14 px dot + 4 px gap that's
    // ~26 dots fitting, but 20 reads as the visual rhythm on both desktop
    // and the mobile review step. Removing LayoutBuilder also avoids the
    // Flutter web mouse_tracker race even though there are no MouseRegions
    // here directly — it keeps the layout pass predictable.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: List.generate(
        20,
        (_) => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.draftId});
  final String draftId;
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            gradient: AppColors.primaryGradient,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            kAppMonogram,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: AppColors.darkBg,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${kAppDisplayName.toUpperCase()} TREASURY',
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                'INTER-BRANCH TRANSFER',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: AppColors.darkTextTertiary,
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              draftId,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              _formatNow(),
              style: GoogleFonts.jetBrainsMono(
                fontSize: 9.5,
                color: AppColors.darkTextDisabled,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatNow() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }
}

class _RoutePills extends StatelessWidget {
  const _RoutePills({
    required this.fromFlag,
    required this.fromCode,
    required this.fromCity,
    required this.toFlag,
    required this.toCode,
    required this.toCity,
  });
  final String fromFlag;
  final String fromCode;
  final String fromCity;
  final String toFlag;
  final String toCode;
  final String toCity;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _Pill(flag: fromFlag, code: fromCode, city: fromCity, accent: AppColors.warning)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(AppIcons.arrow_forward, size: 16, color: AppColors.primary),
        ),
        Expanded(child: _Pill(flag: toFlag, code: toCode, city: toCity, accent: AppColors.primary)),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.flag,
    required this.code,
    required this.city,
    required this.accent,
  });
  final String flag;
  final String code;
  final String city;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 9, 10, 9),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        border: Border(left: BorderSide(color: accent, width: 3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.darkCardHover,
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.center,
            child: Text(flag, style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  code,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
                Text(
                  city,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkTextPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.amount,
    required this.received,
    required this.fromCurrency,
    required this.toCurrency,
    required this.insufficient,
  });
  final double amount;
  final double received;
  final String fromCurrency;
  final String toCurrency;
  final bool insufficient;

  @override
  Widget build(BuildContext context) {
    final hasAmount = amount > 0;
    final color = insufficient ? AppColors.error : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.darkBorder, style: BorderStyle.solid),
          bottom: BorderSide(color: AppColors.darkBorder, style: BorderStyle.solid),
        ),
      ),
      child: Column(
        children: [
          Text(
            'К ПОЛУЧЕНИЮ',
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasAmount ? received.formatCurrencyNoDecimals() : '—',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.7,
              color: color,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            toCurrency,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 8),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: GoogleFonts.inter(
                fontSize: 11,
                color: AppColors.darkTextTertiary,
              ),
              children: [
                const TextSpan(text: 'Отправлено: '),
                TextSpan(
                  text:
                      '${amount.formatCurrencyNoDecimals()} $fromCurrency',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({
    required this.fromCurrency,
    required this.toCurrency,
    required this.rate,
    required this.commissionLabel,
    required this.commission,
    required this.commissionCurrency,
    required this.commissionPayer,
    required this.totalDebit,
    required this.senderName,
    required this.senderPhone,
    required this.receiverName,
    required this.receiverPhone,
    required this.description,
  });
  final String fromCurrency;
  final String toCurrency;
  final double rate;
  final String commissionLabel;
  final double commission;
  final String commissionCurrency;
  final String commissionPayer;
  final double totalDebit;
  final String senderName;
  final String senderPhone;
  final String receiverName;
  final String receiverPhone;
  final String description;

  @override
  Widget build(BuildContext context) {
    final rateStr = fromCurrency == toCurrency
        ? '1.000000'
        : '1 $fromCurrency = ${_fmtRate(rate)} $toCurrency';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.darkBorder),
        ),
      ),
      child: Column(
        children: [
          _ReceiptLine(label: 'Курс', value: rateStr, mono: true),
          _ReceiptLine(
            label: commissionLabel,
            value: '${commission.formatCurrency()} $commissionCurrency',
            sub: commissionPayer,
            mono: true,
          ),
          _ReceiptLine(
            label: 'Списание',
            value: '${totalDebit.formatCurrencyNoDecimals()} $fromCurrency',
            mono: true,
          ),
          _ReceiptLine(
            label: 'Отправитель',
            value: senderName.isEmpty ? '—' : senderName,
          ),
          if (senderPhone.isNotEmpty)
            _ReceiptLine(label: '· телефон', value: senderPhone, mono: true, small: true),
          _ReceiptLine(
            label: 'Получатель',
            value: receiverName.isEmpty ? '—' : receiverName,
          ),
          if (receiverPhone.isNotEmpty)
            _ReceiptLine(label: '· телефон', value: receiverPhone, mono: true, small: true),
          if (description.isNotEmpty)
            _ReceiptLine(label: 'Назначение', value: description, wrap: true),
        ],
      ),
    );
  }

  String _fmtRate(double r) {
    if (r <= 0) return '—';
    if (r < 1) return r.toStringAsFixed(6);
    if (r >= 1000) return r.toStringAsFixed(0);
    return r.toStringAsFixed(r == r.roundToDouble() ? 0 : 4);
  }
}

class _ReceiptLine extends StatelessWidget {
  const _ReceiptLine({
    required this.label,
    required this.value,
    this.sub,
    this.mono = false,
    this.wrap = false,
    this.small = false,
  });
  final String label;
  final String value;
  final String? sub;
  final bool mono;
  final bool wrap;
  final bool small;
  @override
  Widget build(BuildContext context) {
    final valueStyle = mono
        ? GoogleFonts.jetBrainsMono(
            fontSize: small ? 10.5 : 12,
            fontWeight: FontWeight.w600,
            color: AppColors.darkTextPrimary,
          )
        : GoogleFonts.inter(
            fontSize: small ? 10.5 : 12,
            fontWeight: FontWeight.w600,
            color: AppColors.darkTextPrimary,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: small ? 10.5 : 11.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  maxLines: wrap ? 4 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: valueStyle,
                ),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      sub!,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        color: AppColors.darkTextTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.operatorName,
    required this.operatorBranchCode,
  });
  final String operatorName;
  final String operatorBranchCode;
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ОПЕРАТОР',
              style: GoogleFonts.inter(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: AppColors.darkTextTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              operatorName.isEmpty ? '—' : operatorName,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.darkTextPrimary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              operatorBranchCode.isEmpty ? '' : operatorBranchCode,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 9.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ],
        ),
        const Spacer(),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'ПОДПИСЬ',
              style: GoogleFonts.inter(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: AppColors.darkTextTertiary,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 80,
              height: 34,
              child: CustomPaint(painter: _SignaturePainter()),
            ),
          ],
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(2, 24)
      ..quadraticBezierTo(12, 8, 22, 18)
      ..cubicTo(32, 14, 38, 18, 42, 16)
      ..quadraticBezierTo(50, 4, 60, 22)
      ..cubicTo(68, 18, 74, 16, 78, 14);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_) => false;
}

/// Helper to derive a country flag from a Branch's country/currency.
/// Falls back to a globe emoji when unknown.
String flagForBranchCountry(String? country) {
  if (country == null) return '🌐';
  final c = country.trim().toLowerCase();
  if (c.contains('узб') || c.startsWith('uz')) return '🇺🇿';
  if (c.contains('рос') || c.startsWith('ru')) return '🇷🇺';
  if (c.contains('каз') || c.startsWith('kz')) return '🇰🇿';
  if (c.contains('тур') || c.startsWith('tr')) return '🇹🇷';
  if (c.contains('кит') || c.startsWith('cn')) return '🇨🇳';
  if (c.contains('бел') || c.startsWith('by')) return '🇧🇾';
  if (c.contains('ары') || c.contains('оаэ') || c.startsWith('ae')) {
    return '🇦🇪';
  }
  return '🌐';
}

/// Helper: short uppercase code for a branch — uses [Branch.code] if present,
/// otherwise generates one from the first three letters of the city/name.
String shortBranchCode(String name, {String? explicitCode}) {
  if (explicitCode != null && explicitCode.isNotEmpty) {
    return explicitCode.toUpperCase();
  }
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '—';
  // first letters of each word, max 3 chars
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return parts.take(3).map((p) => p[0]).join().toUpperCase();
  }
  return trimmed.substring(0, trimmed.length.clamp(0, 3)).toUpperCase();
}

