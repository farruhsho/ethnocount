import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_filter_chips.dart';

/// «Командный центр» фильтров над таблицей переводов.
///
/// Раньше были две раздельные полоски (status-чипы + legacy FilterPanel
/// в light-теме), а dark-тема обходилась голыми чипами. Оператор не
/// видел сразу, какой период / филиал / партнёр сейчас активен — фильтр
/// казалось бы был «всегда сброшен».
///
/// Этот виджет собирает всё в один card-row:
///   1. Status-chips (existing TransferFilterChips) — слева.
///   2. Branch dropdown (single-select; «Все филиалы» = null).
///   3. Date range picker — «period button» с понятным лейблом
///      («Сегодня / Май / 12–18 мая» в зависимости от выбора).
///   4. Partner filter — три варианта (Все / Только через партнёра /
///      Без партнёра) — стек-чипы.
///   5. Search field — мульти-поле «код / телефон / имя».
///   6. Reset all — крестик справа, активен только когда хоть что-то
///      выбрано.
///
/// Состояние не хранится: всё извне через колбэки.
class TransferFilterBar extends StatelessWidget {
  const TransferFilterBar({
    super.key,
    required this.buckets,
    required this.statusFilter,
    required this.onStatusChanged,
    required this.branches,
    required this.branchFilter,
    required this.onBranchChanged,
    required this.dateRange,
    required this.onDateRangeChanged,
    required this.partnerMode,
    required this.onPartnerModeChanged,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onResetAll,
  });

  final List<TransferFilterBucket> buckets;
  final TransferStatus? statusFilter;
  final ValueChanged<TransferStatus?> onStatusChanged;

  final List<Branch> branches;
  final String? branchFilter;
  final ValueChanged<String?> onBranchChanged;

  final DateTimeRange? dateRange;
  final ValueChanged<DateTimeRange?> onDateRangeChanged;

  /// 'all' | 'partner' | 'direct'
  final String partnerMode;
  final ValueChanged<String> onPartnerModeChanged;

  final String searchQuery;
  final ValueChanged<String> onSearchChanged;

  final VoidCallback onResetAll;

  bool get _hasActiveFilters =>
      statusFilter != null ||
      branchFilter != null ||
      dateRange != null ||
      partnerMode != 'all' ||
      searchQuery.isNotEmpty;

  String _formatDateRange(DateTimeRange r) {
    final s = r.start;
    final e = r.end;
    String two(int n) => n.toString().padLeft(2, '0');
    final months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
    ];
    if (s.year == e.year && s.month == e.month && s.day == e.day) {
      return '${two(s.day)} ${months[s.month - 1]}';
    }
    if (s.year == e.year && s.month == e.month) {
      return '${two(s.day)}–${two(e.day)} ${months[s.month - 1]}';
    }
    return '${two(s.day)} ${months[s.month - 1]} — '
        '${two(e.day)} ${months[e.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder, width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Первая строка — статус-чипы + reset
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final b in buckets) ...[
                        _StatusChip(
                          bucket: b,
                          active: b.status == statusFilter,
                          onTap: () => onStatusChanged(b.status),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ),
              if (_hasActiveFilters)
                _ResetButton(onPressed: onResetAll),
            ],
          ),
          const SizedBox(height: 10),
          // Вторая строка — Filial / Period / Partner / Search
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _BranchSelector(
                  branches: branches,
                  selected: branchFilter,
                  onChanged: onBranchChanged,
                ),
                const SizedBox(width: 8),
                _PeriodButton(
                  range: dateRange,
                  label:
                      dateRange == null ? 'Период' : _formatDateRange(dateRange!),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(now.year - 2),
                      lastDate: now.add(const Duration(days: 1)),
                      initialDateRange: dateRange,
                      helpText: 'Период переводов',
                      saveText: 'Применить',
                    );
                    if (picked != null) onDateRangeChanged(picked);
                  },
                  onClear: dateRange != null
                      ? () => onDateRangeChanged(null)
                      : null,
                ),
                const SizedBox(width: 8),
                _PartnerModeToggle(
                  mode: partnerMode,
                  onChanged: onPartnerModeChanged,
                ),
                const SizedBox(width: 8),
                _SearchField(
                  initial: searchQuery,
                  onChanged: onSearchChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
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
                      : AppColors.darkSurface,
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

class _BranchSelector extends StatelessWidget {
  const _BranchSelector({
    required this.branches,
    required this.selected,
    required this.onChanged,
  });
  final List<Branch> branches;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final sel = selected;
    final label = sel == null
        ? 'Все филиалы'
        : branches.where((b) => b.id == sel).firstOrNull?.name ?? sel;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final picked = await showMenu<String?>(
            context: context,
            position: const RelativeRect.fromLTRB(120, 200, 0, 0),
            color: AppColors.darkCard,
            items: [
              const PopupMenuItem<String?>(
                value: null,
                child: Text('Все филиалы',
                    style: TextStyle(color: AppColors.darkTextPrimary)),
              ),
              for (final b in branches)
                PopupMenuItem<String?>(
                  value: b.id,
                  child: Text(b.name,
                      style: const TextStyle(
                          color: AppColors.darkTextPrimary)),
                ),
            ],
          );
          // showMenu возвращает null если пользователь нажал outside.
          // Чтобы отличить «не трогал» от «выбрал Все филиалы», читаем
          // через sentinel: null-value PopupMenuItem всё равно вернёт null,
          // поэтому пользователю придётся жать «Все филиалы» сознательно.
          if (picked != selected) onChanged(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            border: Border.all(
              color: sel == null
                  ? AppColors.darkBorder
                  : AppColors.secondary.withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.business,
                  size: 14, color: AppColors.darkTextSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: sel == null
                      ? AppColors.darkTextSecondary
                      : AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(AppIcons.expand_more,
                  size: 14, color: AppColors.darkTextSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.range,
    required this.label,
    required this.onTap,
    required this.onClear,
  });
  final DateTimeRange? range;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        border: Border.all(
          color: range == null
              ? AppColors.darkBorder
              : AppColors.secondary.withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.calendar_today,
                        size: 14, color: AppColors.darkTextSecondary),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: range == null
                            ? AppColors.darkTextSecondary
                            : AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onClear != null)
            InkWell(
              onTap: onClear,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                child: Icon(AppIcons.close,
                    size: 14, color: AppColors.darkTextTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _PartnerModeToggle extends StatelessWidget {
  const _PartnerModeToggle({required this.mode, required this.onChanged});
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = const [
      ('all', 'Все'),
      ('partner', '⇄ Через партнёра'),
      ('direct', 'Свои'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final it in items)
            _seg(
              it.$2,
              active: mode == it.$1,
              onTap: () => onChanged(it.$1),
              isPartner: it.$1 == 'partner',
            ),
        ],
      ),
    );
  }

  Widget _seg(String label,
      {required bool active,
      required VoidCallback onTap,
      required bool isPartner}) {
    final accent = isPartner ? AppColors.purple : AppColors.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: active ? accent : AppColors.darkTextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.initial, required this.onChanged});
  final String initial;
  final ValueChanged<String> onChanged;
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(covariant _SearchField old) {
    super.didUpdateWidget(old);
    // Внешний reset (сброс всех фильтров) должен очистить и поле.
    if (widget.initial != _ctrl.text) {
      _ctrl.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: TextField(
        controller: _ctrl,
        onChanged: widget.onChanged,
        style: GoogleFonts.inter(
          fontSize: 12,
          color: AppColors.darkTextPrimary,
        ),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(AppIcons.search,
                size: 14, color: AppColors.darkTextSecondary),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 30, minHeight: 30),
          hintText: 'Код / имя / телефон',
          hintStyle: GoogleFonts.inter(
            fontSize: 12,
            color: AppColors.darkTextTertiary,
          ),
          filled: true,
          fillColor: AppColors.darkSurface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.darkBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.darkBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
                color: AppColors.primary.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Сбросить все фильтры',
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(AppIcons.filter_alt_off,
            size: 16, color: AppColors.warning),
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(6),
      ),
    );
  }
}
