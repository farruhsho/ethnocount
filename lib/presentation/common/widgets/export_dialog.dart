import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';

/// Диалог настройки экспорта: выбор колонок и лимит строк.
class ExportDialog extends StatefulWidget {
  const ExportDialog({
    super.key,
    required this.columns,
    required this.title,
    this.initialSettings,
  });

  final List<ExportColumnDef> columns;
  final String title;
  final ExportSettings? initialSettings;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  late Set<String> _enabledColumns;
  int? _rowLimit;

  @override
  void initState() {
    super.initState();
    _enabledColumns = widget.initialSettings?.enabledColumns.toSet() ??
        widget.columns
            .where((c) => c.defaultEnabled)
            .map((c) => c.id)
            .toSet();
    _rowLimit = widget.initialSettings?.rowLimit;
  }

  void _toggleColumn(String id) {
    setState(() {
      if (_enabledColumns.contains(id)) {
        if (_enabledColumns.length > 1) _enabledColumns = {..._enabledColumns}..remove(id);
      } else {
        _enabledColumns = {..._enabledColumns, id};
      }
    });
  }

  void _selectAll(bool value) {
    setState(() {
      _enabledColumns = value
          ? widget.columns.map((c) => c.id).toSet()
          : <String>{};
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.tune_rounded, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Text(widget.title),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Колонки',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _selectAll(true),
                    child: const Text('Все'),
                  ),
                  TextButton(
                    onPressed: () => _selectAll(false),
                    child: const Text('Снять'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: widget.columns.map((col) {
                  final on = _enabledColumns.contains(col.id);
                  return FilterChip(
                    label: Text(col.label),
                    selected: on,
                    onSelected: (_) => _toggleColumn(col.id),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Лимит строк',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('Все'),
                    selected: _rowLimit == null,
                    onSelected: (s) => setState(() => _rowLimit = null),
                  ),
                  ...ExportColumnPresets.rowLimitOptions.map((n) {
                    final sel = _rowLimit == n;
                    return ChoiceChip(
                      label: Text(_formatNumber(n)),
                      selected: sel,
                      onSelected: (_) => setState(() => _rowLimit = n),
                    );
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _enabledColumns.isEmpty
              ? null
              : () => Navigator.of(context).pop(ExportSettings(
                    enabledColumns: _enabledColumns,
                    rowLimit: _rowLimit,
                  )),
          child: const Text('Экспорт'),
        ),
      ],
    );
  }

  String _formatNumber(int n) {
    if (n >= 1000) return '${n ~/ 1000}K';
    return n.toString();
  }
}
