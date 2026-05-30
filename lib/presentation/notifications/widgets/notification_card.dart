import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/notification.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Компактная карточка уведомления: 3-px цветной borderLeft по типу,
/// иконка-аватар в категории-цвете, mono-таймстамп справа, pulsing-точка
/// слева для непрочитанных (через TweenAnimationBuilder). Тап → onTap.
class NotificationCard extends StatefulWidget {
  const NotificationCard({
    super.key,
    required this.notification,
    required this.onTap,
  });

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  State<NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<NotificationCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (!widget.notification.isRead) {
      _pulseCtrl.repeat();
    }
  }

  @override
  void didUpdateWidget(NotificationCard old) {
    super.didUpdateWidget(old);
    if (!widget.notification.isRead && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat();
    } else if (widget.notification.isRead && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  AppNotification get notification => widget.notification;
  VoidCallback get onTap => widget.onTap;

  Color get _accent {
    switch (notification.type) {
      case NotificationType.incomingTransfer:
        return AppColors.secondary;
      case NotificationType.transferConfirmed:
        return AppColors.warning;
      case NotificationType.transferDispatched:
        return AppColors.purple;
      case NotificationType.transferIssued:
        return AppColors.primary;
      case NotificationType.transferAmended:
        return AppColors.warning;
      case NotificationType.systemAlert:
        return AppColors.darkTextTertiary;
    }
  }

  IconData get _icon {
    switch (notification.type) {
      case NotificationType.incomingTransfer:
        return AppIcons.call_received;
      case NotificationType.transferConfirmed:
        return AppIcons.check_circle_outline;
      case NotificationType.transferDispatched:
        return AppIcons.local_shipping;
      case NotificationType.transferIssued:
        return AppIcons.check_circle;
      case NotificationType.transferAmended:
        return AppIcons.edit_note;
      case NotificationType.systemAlert:
        return AppIcons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = !notification.isRead;
    final accent = _accent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: unread
                ? accent.withValues(alpha: 0.08)
                : scheme.surface.withValues(alpha: 0.5),
            border: Border(
              left: BorderSide(color: accent, width: 3),
              top: BorderSide(
                color: scheme.outline.withValues(alpha: 0.12),
              ),
              right: BorderSide(
                color: scheme.outline.withValues(alpha: 0.12),
              ),
              bottom: BorderSide(
                color: scheme.outline.withValues(alpha: 0.12),
              ),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(_icon, size: 17, color: accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: unread
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 6),
                          // Pulse-wave: точка пульсирует — ring expands &
                          // fades. Слегка привлекает внимание без
                          // навязчивости.
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: AnimatedBuilder(
                              animation: _pulseCtrl,
                              builder: (ctx, _) {
                                final t = _pulseCtrl.value;
                                final ringSize = 7 + 9 * t;
                                final ringOpacity = (1 - t) * 0.5;
                                return Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: ringSize,
                                      height: ringSize,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accent.withValues(
                                            alpha: ringOpacity),
                                      ),
                                    ),
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        color: accent,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accent.withValues(
                                                alpha: 0.5),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notification.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            notification.type.displayName,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatTime(notification.createdAt),
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime d) {
    final local = d.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    String two(int n) => n.toString().padLeft(2, '0');

    // Сегодня → HH:mm
    if (DateTime(now.year, now.month, now.day) ==
        DateTime(local.year, local.month, local.day)) {
      return '${two(local.hour)}:${two(local.minute)}';
    }
    // Вчера → «вчера HH:mm»
    final yesterday = now.subtract(const Duration(days: 1));
    if (DateTime(yesterday.year, yesterday.month, yesterday.day) ==
        DateTime(local.year, local.month, local.day)) {
      return 'вчера ${two(local.hour)}:${two(local.minute)}';
    }
    // Эта неделя → «Сб 14:32»
    if (diff.inDays < 7) {
      const ru = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
      return '${ru[local.weekday - 1]} ${two(local.hour)}:${two(local.minute)}';
    }
    // Старше → дата
    return '${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
  }
}
