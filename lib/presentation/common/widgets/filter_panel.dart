import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';

/// Reusable filter panel for desktop pages.
/// Displays horizontally on desktop, collapsible on mobile.
class FilterPanel extends StatelessWidget {
  const FilterPanel({
    super.key,
    required this.children,
    this.onReset,
    this.trailing,
  });

  final List<Widget> children;
  final VoidCallback? onReset;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.filter_list_rounded,
            size: 18,
            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: children,
            ),
          ),
          if (onReset != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.clear_all, size: 16),
              label: const Text('Сброс', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Compact filter chip for dropdown selections.
class FilterDropdown<T> extends StatelessWidget {
  const FilterDropdown({
    super.key,
    required this.label,
    required this.items,
    this.value,
    required this.onChanged,
    this.itemLabel,
    this.width = 180,
  });

  final String label;
  final List<T> items;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String Function(T)? itemLabel;
  final double width;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return SizedBox(
      width: width,
      height: 36,
      child: DropdownButtonFormField<T>(
        key: ValueKey('filter-$label-$value'),
        value: value,
        isDense: true,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              width: 0.5,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              width: 0.5,
            ),
          ),
          filled: true,
          fillColor: isDark ? AppColors.darkSurface : Colors.white,
        ),
        style: TextStyle(
          fontSize: 13,
          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        ),
        items: [
          DropdownMenuItem<T>(
            value: null,
            child: Text('Все', style: TextStyle(
              fontSize: 13,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            )),
          ),
          ...items.map((item) => DropdownMenuItem<T>(
                value: item,
                child: Text(
                  itemLabel?.call(item) ?? item.toString(),
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              )),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Date range selector for filter panels.
class DateRangeFilter extends StatelessWidget {
  const DateRangeFilter({
    super.key,
    this.startDate,
    this.endDate,
    required this.onChanged,
    this.label = 'Период',
  });

  final DateTime? startDate;
  final DateTime? endDate;
  final ValueChanged<DateTimeRange?> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final hasRange = startDate != null && endDate != null;

    return SizedBox(
      height: 36,
      child: OutlinedButton.icon(
        onPressed: () async {
          final range = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2020),
            lastDate: DateTime.now().add(const Duration(days: 1)),
            initialDateRange: hasRange
                ? DateTimeRange(start: startDate!, end: endDate!)
                : null,
            builder: (context, child) {
              return Theme(
                data: Theme.of(context).copyWith(
                  dialogTheme: DialogThemeData(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                child: child!,
              );
            },
          );
          onChanged(range);
        },
        icon: const Icon(Icons.date_range, size: 16),
        label: Text(
          hasRange
              ? '${_formatShort(startDate!)} – ${_formatShort(endDate!)}'
              : label,
          style: TextStyle(
            fontSize: 12,
            color: hasRange
                ? (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary)
                : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
          ),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          side: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            width: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  String _formatShort(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }
}
