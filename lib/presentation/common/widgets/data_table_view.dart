import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/constants/app_typography.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';

class AdvancedDataTable<T> extends StatelessWidget {
  const AdvancedDataTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.isLoading,
    this.onRowTap,
    this.emptyMessage = 'No data available',
    this.onNextPage,
    this.onPreviousPage,
    this.hasNext = false,
    this.hasPrevious = false,
  });

  final List<DataColumn> columns;
  final List<T> rows;
  final bool isLoading;
  final void Function(T item)? onRowTap;
  final String emptyMessage;
  final VoidCallback? onNextPage;
  final VoidCallback? onPreviousPage;
  final bool hasNext;
  final bool hasPrevious;

  @override
  Widget build(BuildContext context) {
    if (isLoading && rows.isEmpty) {
      return _buildLoadingState(context);
    }

    if (rows.isEmpty) {
      return _buildEmptyState(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: DataTable(
                headingRowColor: WidgetStateProperty.resolveWith(
                  (states) => Theme.of(context).colorScheme.surface,
                ),
                headingTextStyle: AppTypography.labelMedium.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                dataRowColor: WidgetStateProperty.resolveWith(
                  (states) {
                    if (states.contains(WidgetState.hovered)) {
                      return Theme.of(context).brightness == Brightness.dark
                          ? AppColors.darkCardHover
                          : AppColors.lightCardHover;
                    }
                    return null;
                  },
                ),
                dividerThickness: 1,
                showBottomBorder: true,
                columns: columns,
                rows: rows.map((item) => _buildRow(context, item)).toList(),
              ),
            ),
          ),
        ),
        _buildPaginationControls(context),
      ],
    );
  }

  DataRow _buildRow(BuildContext context, T item) {
    // This is a generic abstraction. 
    // In a real implementation, the parent must pass `DataRow` objects 
    // or a builder function `DataRow Function(T item) rowBuilder`.
    // For this generic widget, we assume `T` extends a UI-model interface or
    // we refactor the constructor to take `List<DataRow>`.
    // We will refactor it to accept a builder:
    throw UnimplementedError('Use AdvancedDataTable.builder instead');
  }

  Widget _buildLoadingState(BuildContext context) {
    return ListView.builder(
      itemCount: 8,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.only(bottom: AppSpacing.sm),
        child: ShimmerLoading.listTile(),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            emptyMessage,
            style: AppTypography.bodyLarge.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: hasPrevious ? onPreviousPage : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('Previous'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: hasNext ? onNextPage : null,
            icon: const Text('Next'),
            label: const Icon(Icons.chevron_right, size: 18),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
          ),
        ],
      ),
    );
  }
}

class BuiltAdvancedDataTable extends StatelessWidget {
    const BuiltAdvancedDataTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.isLoading,
    this.emptyMessage = 'No data available',
    this.onNextPage,
    this.onPreviousPage,
    this.hasNext = false,
    this.hasPrevious = false,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;
  final bool isLoading;
  final String emptyMessage;
  final VoidCallback? onNextPage;
  final VoidCallback? onPreviousPage;
  final bool hasNext;
  final bool hasPrevious;

  @override
  Widget build(BuildContext context) {
    if (isLoading && rows.isEmpty) {
      return _buildLoadingState(context);
    }

    if (rows.isEmpty) {
      return _buildEmptyState(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: DataTable(
                headingRowColor: WidgetStateProperty.resolveWith(
                  (states) => Theme.of(context).colorScheme.surface,
                ),
                headingTextStyle: AppTypography.labelMedium.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                dataRowColor: WidgetStateProperty.resolveWith(
                  (states) {
                    if (states.contains(WidgetState.hovered)) {
                      return Theme.of(context).brightness == Brightness.dark
                          ? AppColors.darkCardHover
                          : AppColors.lightCardHover;
                    }
                    return null;
                  },
                ),
                dividerThickness: 1,
                showBottomBorder: true,
                columns: columns,
                rows: rows,
              ),
            ),
          ),
        ),
        _buildPaginationControls(context),
      ],
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return ListView.builder(
      itemCount: 8,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.only(bottom: AppSpacing.sm),
        child: ShimmerLoading.listTile(),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            emptyMessage,
            style: AppTypography.bodyLarge.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: hasPrevious ? onPreviousPage : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('Previous'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: hasNext ? onNextPage : null,
            icon: const Text('Next'),
            label: const Icon(Icons.chevron_right, size: 18),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
          ),
        ],
      ),
    );
  }
}
