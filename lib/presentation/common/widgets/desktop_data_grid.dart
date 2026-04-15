import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/services/grid_column_preferences_service.dart';

/// Professional desktop data grid for financial tables.
/// Supports sorting, filtering, pagination, column resizing,
/// keyboard navigation, row selection, and export.
class DesktopDataGrid extends StatelessWidget {
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
  final bool fetchLazy;
  final TrinaLazyPaginationFetch? onFetch;
  final int? totalRows;
  final double headerHeight;
  final double rowHeight;
  final int frozenColumns;

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
        columns: columns,
        rows: rows,
        onLoaded: (event) {
          if (frozenColumns > 0) {
            for (int i = 0; i < frozenColumns && i < columns.length; i++) {
              event.stateManager.toggleFrozenColumn(columns[i], TrinaColumnFrozen.start);
            }
          }
          if (gridId != null) {
            sl<GridColumnPreferencesService>()
                .loadHiddenFields(gridId!)
                .then((hidden) {
              for (final col in columns) {
                if (hidden.contains(col.field)) {
                  event.stateManager.hideColumn(col, true);
                }
              }
            });
          }
          // Автоподгонка ширины колонок под контент — не нужно вручную растягивать
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            for (final col in columns) {
              if (!col.hide) {
                event.stateManager.autoFitColumn(context, col);
              }
            }
          });
          onLoaded?.call(event);
        },
        onSelected: onSelected,
        onRowDoubleTap: onRowDoubleTap,
        configuration: gridConfig,
        mode: TrinaGridMode.selectWithOneTap,
        createHeader: showHeader ? (sm) => _buildGridHeader(context, sm, columns, gridId) : null,
        createFooter: showPagination
            ? fetchLazy
                ? (stateManager) => TrinaLazyPagination(
                      fetch: onFetch!,
                      initialPage: 1,
                      initialFetch: true,
                      fetchWithFiltering: true,
                      fetchWithSorting: true,
                      stateManager: stateManager,
                      pageSizeToMove: pageSize,
                    )
                : (stateManager) => TrinaPagination(stateManager)
            : null,
      ),
    );
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
        rowHeight: rowHeight,
        columnHeight: headerHeight,
        columnFilterHeight: showColumnFilter ? 40 : 0,
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
      rowHeight: rowHeight,
      columnHeight: headerHeight,
      columnFilterHeight: showColumnFilter ? 40 : 0,
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
            icon: Icons.filter_list,
            tooltip: 'Показать фильтры (Ctrl+F)',
            onPressed: () => stateManager.setShowColumnFilter(
              !stateManager.showColumnFilter,
            ),
          ),
          const SizedBox(width: 4),
          _ToolbarButton(
            icon: Icons.view_column_outlined,
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
    final (color, label) = switch (status.toLowerCase()) {
      'pending' => (AppColors.warning, 'Ожидание'),
      'confirmed' => (AppColors.success, 'Принят'),
      'issued' => (Colors.teal, 'Выдан'),
      'rejected' => (AppColors.error, 'Отклонён'),
      'cancelled' => (Colors.grey, 'Отменён'),
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
