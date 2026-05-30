import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// A bucket shown as a single status filter chip. `status == null` means
/// the "Все" / all bucket.
class TransferFilterBucket {
  const TransferFilterBucket({
    required this.status,
    required this.label,
    required this.count,
    required this.color,
  });
  final TransferStatus? status;
  final String label;
  final int count;
  final Color color;
}

/// Horizontal pill-chip filter row from the `transfers-desktop` reference.
/// Each chip carries an optional status-color dot and a mono count badge.
/// Scrolls horizontally on narrow widths.
class TransferFilterChips extends StatelessWidget {
  const TransferFilterChips({
    super.key,
    required this.buckets,
    required this.selected,
    required this.onSelected,
  });

  /// Ordered list of filter buckets (use `status: null` for "Все").
  final List<TransferFilterBucket> buckets;
  final TransferStatus? selected;
  final ValueChanged<TransferStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Row(
        children: [
          for (final b in buckets) ...[
            _Chip(
              bucket: b,
              active: b.status == selected,
              onTap: () => onSelected(b.status),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// Helper that derives the canonical "all + per-status" bucket list from a
  /// transfers collection. Counts respect the live filter set.
  static List<TransferFilterBucket> bucketsFor({
    required int totalCount,
    required Map<TransferStatus, int> perStatusCount,
  }) {
    return [
      TransferFilterBucket(
        status: null,
        label: 'Все',
        count: totalCount,
        color: AppColors.darkTextSecondary,
      ),
      TransferFilterBucket(
        status: TransferStatus.created,
        label: 'Ожидают',
        count: perStatusCount[TransferStatus.created] ?? 0,
        color: AppColors.warning,
      ),
      TransferFilterBucket(
        status: TransferStatus.toDelivery,
        label: 'К выдаче',
        count: perStatusCount[TransferStatus.toDelivery] ?? 0,
        color: AppColors.secondary,
      ),
      TransferFilterBucket(
        status: TransferStatus.withCourier,
        label: 'У курьера',
        count: perStatusCount[TransferStatus.withCourier] ?? 0,
        color: AppColors.purple,
      ),
      TransferFilterBucket(
        status: TransferStatus.delivered,
        label: 'Выданы',
        count: perStatusCount[TransferStatus.delivered] ?? 0,
        color: AppColors.primary,
      ),
    ];
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.bucket,
    required this.active,
    required this.onTap,
  });
  final TransferFilterBucket bucket;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = bucket.color;
    final hasDot = bucket.status != null;
    // Plain Container (no AnimatedContainer) — the implicit animation
    // re-decorates the InkWell's child mid-hover on Flutter web and can
    // trip the `_debugDuringDeviceUpdate` assertion. A snap state change
    // is fine for a discrete filter chip.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(
              color: active ? accent : AppColors.darkBorder,
              width: active ? 1.2 : 1,
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasDot) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                bucket.label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? accent : AppColors.darkTextSecondary,
                ),
              ),
              const SizedBox(width: 7),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active
                      ? accent.withValues(alpha: 0.18)
                      : AppColors.darkCard,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  '${bucket.count}',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: active ? accent : AppColors.darkTextTertiary,
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
