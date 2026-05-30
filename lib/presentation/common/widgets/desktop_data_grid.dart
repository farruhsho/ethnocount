import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/services/grid_column_preferences_service.dart';

import 'package:ethnocount/core/icons/app_icons.dart';
/// Professional desktop data grid for financial tables.
/// Supports sorting, filtering, pagination, column resizing,
/// keyboard navigation, row selection, and export.
///
/// Если задан [gridId], настройки (hidden / widths / order / sort)
/// сохраняются per-user в Supabase и автоматически восстанавливаются
/// при следующем открытии — даже на другом устройстве.
class DesktopDataGrid extends StatefulWidget {
  const DesktopDataGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.gridId,
    this.onLoaded,
    this.onSelected,
    this.onRowDoubleTap,
    this.pageSize = 50,
    this.showPagination = true,
    this.showColumnFilter = true,
    this.showHeader = true,
    this.alwaysShowFilters = true,
    this.fetchLazy = false,
    this.onFetch,
    this.totalRows,
    this.headerHeight = 44.0,
    this.rowHeight = 44.0,
    this.frozenColumns = 0,
  });

  final List<TrinaColumn> columns;
  final List<TrinaRow> rows;
  final String? gridId;
  final void Function(TrinaGridOnLoadedEvent)? onLoaded;
  final void Function(TrinaGridOnSelectedEvent)? onSelected;
  final void Function(TrinaGridOnRowDoubleTapEvent)? onRowDoubleTap;
  final int pageSize;
  final bool showPagination;
  final bool showColumnFilter;
  final bool showHeader;

  /// Показывать строку поиска под каждым заголовком всегда. Чтобы юзер
  /// мог фильтровать по любой колонке без лишних кликов.
  final bool alwaysShowFilters;

  final bool fetchLazy;
  final TrinaLazyPaginationFetch? onFetch;
  final int? totalRows;
  final double headerHeight;
  final double rowHeight;
  final int frozenColumns;

  @override
  State<DesktopDataGrid> createState() => _DesktopDataGridState();
}

class _DesktopDataGridState extends State<DesktopDataGrid> {
  TrinaGridStateManager? _sm;

  @override
  void dispose() {
    _persistPreferences();
    super.dispose();
  }

  void _persistPreferences() {
    final id = widget.gridId;
    final sm = _sm;
    if (id == null || sm == null) return;
    final cols = sm.refColumns;
    final widths = <String, double>{
      for (final c in cols) c.field: c.width,
    };
    final order = cols.map((c) => c.field).toList();
    final hidden = cols.where((c) => c.hide).map((c) => c.field).toList();
    final sorted = cols.where((c) => c.sort != TrinaColumnSort.none).firstOrNull;
    sl<GridColumnPreferencesService>().save(
      id,
      GridPreferencesSnapshot(
        hidden: hidden,
        widths: widths,
        order: order,
        sortField: sorted?.field,
        sortAsc: sorted == null ? null : sorted.sort == TrinaColumnSort.ascending,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    final gridConfig = TrinaGridConfiguration(
      columnSize: const TrinaGridColumnSizeConfig(
        autoSizeMode: TrinaAutoSizeMode.none,
        resizeMode: TrinaResizeMode.normal,
      ),
      style: _buildStyle(isDark),
      scrollbar: const TrinaGridScrollbarConfig(
        isAlwaysShown: true,
        thickness: 8,
      ),
      localeText: const TrinaGridLocaleText.russian(),
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      clipBehavior: Clip.antiAlias,
      child: TrinaGrid(
        columns: widget.columns,
        rows: widget.rows,
        onLoaded: (event) {
          _sm = event.stateManager;
          if (widget.alwaysShowFilters) {
            event.stateManager.setShowColumnFilter(true);
          }
          if (widget.frozenColumns > 0) {
            for (int i = 0; i < widget.frozenColumns && i < widget.columns.length; i++) {
              event.stateManager
                  .toggleFrozenColumn(widget.columns[i], TrinaColumnFrozen.start);
            }
          }
          if (widget.gridId != null) {
            sl<GridColumnPreferencesService>().load(widget.gridId!).then((snap) {
              if (!mounted) return;
              _applyPreferences(event.stateManager, snap);
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              for (final col in widget.columns) {
                if (!col.hide) {
                  event.stateManager.autoFitColumn(context, col);
                }
              }
            });
          }
          widget.onLoaded?.call(event);
        },
        onSelected: widget.onSelected,
        onRowDoubleTap: widget.onRowDoubleTap,
        configuration: gridConfig,
        mode: TrinaGridMode.selectWithOneTap,
        createHeader: widget.showHeader
            ? (sm) => _buildGridHeader(context, sm, widget.columns, widget.gridId)
            : null,
        createFooter: widget.showPagination
            ? widget.fetchLazy
                ? (stateManager) => TrinaLazyPagination(
                      fetch: widget.onFetch!,
                      initialPage: 1,
                      initialFetch: true,
                      fetchWithFiltering: true,
                      fetchWithSorting: true,
                      stateManager: stateManager,
                      pageSizeToMove: widget.pageSize,
                    )
                : (stateManager) => TrinaPagination(stateManager)
            : null,
      ),
    );
  }

  void _applyPreferences(
    TrinaGridStateManager sm,
    GridPreferencesSnapshot snap,
  ) {
    // hidden
    for (final col in widget.columns) {
      if (snap.hidden.contains(col.field)) {
        sm.hideColumn(col, true);
      }
    }
    // widths
    if (snap.widths.isNotEmpty) {
      for (final col in widget.columns) {
        final w = snap.widths[col.field];
        if (w != null && w > 0) {
          sm.resizeColumn(col, w - col.width);
        }
      }
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final col in widget.columns) {
          if (!col.hide) sm.autoFitColumn(context, col);
        }
      });
    }
    // order
    if (snap.order.isNotEmpty) {
      final byField = {for (final c in widget.columns) c.field: c};
      final reordered = <TrinaColumn>[
        for (final f in snap.order)
          if (byField.containsKey(f)) byField[f]!,
      ];
      // Доклеиваем колонки, которых нет в saved order (на случай новой колонки).
      for (final c in widget.columns) {
        if (!reordered.contains(c)) reordered.add(c);
      }
      if (reordered.length == widget.columns.length) {
        for (var i = 0; i < reordered.length; i++) {
          sm.moveColumn(column: reordered[i], targetColumn: widget.columns[i]);
        }
      }
    }
    // sort
    final f = snap.sortField;
    if (f != null) {
      final col = widget.columns.where((c) => c.field == f).firstOrNull;
      if (col != null) {
        if (snap.sortAsc == true) {
          sm.sortAscending(col);
        } else {
          sm.sortDescending(col);
        }
      }
    }
  }

  TrinaGridStyleConfig _buildStyle(bool isDark) {
    if (isDark) {
      return TrinaGridStyleConfig.dark(
        gridBorderColor: AppColors.darkBorder,
        borderColor: AppColors.darkBorder,
        activatedColor: AppColors.primary.withValues(alpha: 0.12),
        activatedBorderColor: AppColors.primary.withValues(alpha: 0.3),
        gridBackgroundColor: AppColors.darkBg,
        rowColor: AppColors.darkSurface,
        cellColorInEditState: AppColors.darkCard,
        cellColorInReadOnlyState: AppColors.darkSurface,
        columnTextStyle: TextStyle(
          color: AppColors.darkTextSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        cellTextStyle: TextStyle(
          color: AppColors.darkTextPrimary,
          fontSize: 13,
          height: 1.35,
        ),
        iconColor: AppColors.darkTextSecondary,
        menuBackgroundColor: AppColors.darkCard,
        rowHeight: widget.rowHeight,
        columnHeight: widget.headerHeight,
        columnFilterHeight: widget.showColumnFilter ? 40 : 0,
        evenRowColor: AppColors.darkBg,
        oddRowColor: AppColors.darkSurface,
      );
    }

    return TrinaGridStyleConfig(
      gridBorderColor: AppColors.lightBorder,
      borderColor: AppColors.lightBorder,
      activatedColor: AppColors.primary.withValues(alpha: 0.08),
      activatedBorderColor: AppColors.primary.withValues(alpha: 0.2),
      gridBackgroundColor: AppColors.lightBg,
      rowColor: Colors.white,
      cellColorInEditState: AppColors.lightCard,
      cellColorInReadOnlyState: Colors.white,
      columnTextStyle: TextStyle(
        color: AppColors.lightTextSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
      cellTextStyle: TextStyle(
        color: AppColors.lightTextPrimary,
        fontSize: 13,
        height: 1.35,
      ),
      iconColor: AppColors.lightTextSecondary,
      menuBackgroundColor: AppColors.lightCard,
      rowHeight: widget.rowHeight,
      columnHeight: widget.headerHeight,
      columnFilterHeight: widget.showColumnFilter ? 40 : 0,
      evenRowColor: AppColors.lightBg,
      oddRowColor: Colors.white,
    );
  }

  Widget _buildGridHeader(
    BuildContext context,
    TrinaGridStateManager stateManager,
    List<TrinaColumn> allColumns,
    String? gridId,
  ) {
    return _GridToolbar(
      stateManager: stateManager,
      allColumns: allColumns,
      gridId: gridId,
    );
  }
}

class _GridToolbar extends StatelessWidget {
  const _GridToolbar({
    required this.stateManager,
    required this.allColumns,
    this.gridId,
  });
  final TrinaGridStateManager stateManager;
  final List<TrinaColumn> allColumns;
  final String? gridId;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
          Text(
            '${stateManager.refRows.length} записей',
            style: TextStyle(
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          _ToolbarButton(
            icon: AppIcons.filter_list,
            tooltip: 'Показать фильтры (Ctrl+F)',
            onPressed: () => stateManager.setShowColumnFilter(
              !stateManager.showColumnFilter,
            ),
          ),
          const SizedBox(width: 4),
          _ToolbarButton(
            icon: AppIcons.view_column,
            tooltip: 'Управление колонками',
            onPressed: () => _showColumnManager(context, stateManager, allColumns, gridId),
          ),
        ],
      ),
    );
  }

  void _showColumnManager(
    BuildContext context,
    TrinaGridStateManager stateManager,
    List<TrinaColumn> allColumns,
    String? gridId,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => _ColumnManagerDialog(
        stateManager: stateManager,
        allColumns: allColumns,
        gridId: gridId,
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18),
          ),
        ),
      ),
    );
  }
}

class _ColumnManagerDialog extends StatefulWidget {
  const _ColumnManagerDialog({
    required this.stateManager,
    required this.allColumns,
    this.gridId,
  });
  final TrinaGridStateManager stateManager;
  final List<TrinaColumn> allColumns;
  final String? gridId;

  @override
  State<_ColumnManagerDialog> createState() => _ColumnManagerDialogState();
}

class _ColumnManagerDialogState extends State<_ColumnManagerDialog> {
  @override
  Widget build(BuildContext context) {
    final columns = widget.allColumns;

    return AlertDialog(
      title: const Text('Управление колонками'),
      content: SizedBox(
        width: 300,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: columns.length,
          itemBuilder: (context, index) {
            final col = columns[index];
            return CheckboxListTile(
              title: Text(col.title, style: const TextStyle(fontSize: 14)),
              value: !col.hide,
              dense: true,
              onChanged: (value) {
                setState(() {
                  widget.stateManager.hideColumn(col, !value!);
                });
                if (widget.gridId != null) {
                  final hidden = widget.allColumns
                      .where((c) => c.hide)
                      .map((c) => c.field)
                      .toList();
                  sl<GridColumnPreferencesService>()
                      .saveHiddenFields(widget.gridId!, hidden);
                }
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

/// Helper to build TrinaColumn for financial data.
class FinancialColumns {
  static TrinaColumn text({
    required String title,
    required String field,
    double width = 120,
    bool frozen = false,
    TrinaColumnTextAlign textAlign = TrinaColumnTextAlign.left,
  }) {
    return TrinaColumn(
      title: title,
      field: field,
      type: TrinaColumnType.text(),
      width: width,
      minWidth: 80,
      textAlign: textAlign,
      enableSorting: true,
      enableFilterMenuItem: true,
      enableContextMenu: true,
      frozen: frozen ? TrinaColumnFrozen.start : TrinaColumnFrozen.none,
    );
  }

  static TrinaColumn number({
    required String title,
    required String field,
    double width = 120,
    bool isCurrency = false,
    TrinaColumnTextAlign textAlign = TrinaColumnTextAlign.right,
  }) {
    return TrinaColumn(
      title: title,
      field: field,
      type: isCurrency
          ? TrinaColumnType.currency(format: '#,###.##')
          : TrinaColumnType.number(format: '#,###.####'),
      width: width,
      minWidth: 60,
      textAlign: textAlign,
      enableSorting: true,
      enableFilterMenuItem: true,
    );
  }

  static TrinaColumn date({
    required String title,
    required String field,
    double width = 150,
  }) {
    return TrinaColumn(
      title: title,
      field: field,
      type: TrinaColumnType.date(),
      width: width,
      minWidth: 90,
      enableSorting: true,
      enableFilterMenuItem: true,
    );
  }

  static TrinaColumn status({
    required String title,
    required String field,
    double width = 110,
  }) {
    return TrinaColumn(
      title: title,
      field: field,
      type: TrinaColumnType.text(),
      width: width,
      minWidth: 50,
      enableSorting: true,
      enableFilterMenuItem: true,
      renderer: (rendererContext) {
        final value = rendererContext.cell.value.toString();
        return _StatusBadge(status: value);
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'created' || 'pending' => (AppColors.warning, 'Создан'),
      'toDelivery' || 'confirmed' => (AppColors.secondary, 'К выдаче'),
      'withCourier' => (AppColors.info, 'У курьера'),
      'delivered' || 'issued' => (AppColors.primary, 'Выдан'),
      _ => (Colors.grey, status),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Keyboard shortcut wrapper for data grids.
/// Ctrl+F — toggle filter, Ctrl+C — copy selected, Ctrl+E — export
class DataGridShortcuts extends StatelessWidget {
  const DataGridShortcuts({
    super.key,
    required this.child,
    this.onExport,
    this.stateManager,
  });

  final Widget child;
  final VoidCallback? onExport;
  final TrinaGridStateManager? stateManager;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
            const _ToggleFilterIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyE):
            const _ExportIntent(),
      },
      child: Actions(
        actions: {
          _ToggleFilterIntent: CallbackAction<_ToggleFilterIntent>(
            onInvoke: (_) {
              stateManager?.setShowColumnFilter(
                !(stateManager?.showColumnFilter ?? false),
              );
              return null;
            },
          ),
          _ExportIntent: CallbackAction<_ExportIntent>(
            onInvoke: (_) {
              onExport?.call();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _ToggleFilterIntent extends Intent {
  const _ToggleFilterIntent();
}

class _ExportIntent extends Intent {
  const _ExportIntent();
}
