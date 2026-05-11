import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/presentation/approvals/bloc/approval_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';

class ApprovalsPage extends StatelessWidget {
  const ApprovalsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ApprovalBloc(repository: sl())
        ..add(const ApprovalsWatchRequested()),
      child: const _ApprovalsView(),
    );
  }
}

class _ApprovalsView extends StatefulWidget {
  const _ApprovalsView();
  @override
  State<_ApprovalsView> createState() => _ApprovalsViewState();
}

class _ApprovalsViewState extends State<_ApprovalsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    final statusFilter = _tab.index == 0 ? ApprovalStatus.pending : null;
    context.read<ApprovalBloc>().add(
          ApprovalsWatchRequested(statusFilter: statusFilter),
        );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ApprovalBloc, ApprovalState>(
      listenWhen: (a, b) =>
          a.successMessage != b.successMessage ||
          a.errorMessage != b.errorMessage,
      listener: (_, state) {
        if (state.successMessage != null) {
          context.showSuccessSnackBar(state.successMessage!);
        }
        if (state.errorMessage != null) {
          context.showSnackBar(state.errorMessage!, isError: true);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Согласования'),
          bottom: TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: 'Ожидают'),
              Tab(text: 'История'),
            ],
          ),
        ),
        body: BlocBuilder<ApprovalBloc, ApprovalState>(
          builder: (context, state) {
            if (state.status == ApprovalBlocStatus.loading &&
                state.items.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            final showHistory = _tab.index == 1;
            final list = showHistory
                ? state.items
                : state.items
                    .where((e) => e.status == ApprovalStatus.pending)
                    .toList();

            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.fact_check_outlined,
                title: showHistory ? 'Истории пока нет' : 'Заявок нет',
                subtitle: showHistory
                    ? 'Здесь будут одобренные и отклонённые заявки.'
                    : 'Когда бухгалтер запросит изменение — оно появится тут.',
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: list.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) => _ApprovalCard(item: list[i]),
            );
          },
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.item});
  final ApprovalRequest item;

  Color _statusColor() {
    switch (item.status) {
      case ApprovalStatus.pending:
        return AppColors.warning;
      case ApprovalStatus.approved:
        return AppColors.success;
      case ApprovalStatus.rejected:
        return AppColors.error;
    }
  }

  String _statusLabel() {
    switch (item.status) {
      case ApprovalStatus.pending:
        return 'Ожидает';
      case ApprovalStatus.approved:
        return 'Одобрено';
      case ApprovalStatus.rejected:
        return 'Отклонено';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateFmt = DateFormat('d MMM, HH:mm', 'ru');
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.action.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor().withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  _statusLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _statusColor(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Цель: ${item.targetId}',
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant,
              fontFamily: 'JetBrains Mono',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if ((item.reason ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Причина: ${item.reason}',
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ],
          if (item.payload.isNotEmpty) ...[
            const SizedBox(height: 6),
            _PayloadBlock(payload: item.payload),
          ],
          const SizedBox(height: 8),
          Text(
            'Запросил: ${item.requestedBy} · ${dateFmt.format(item.requestedAt.toLocal())}',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (item.reviewedAt != null) ...[
            const SizedBox(height: 2),
            Text(
              'Решение: ${dateFmt.format(item.reviewedAt!.toLocal())}'
              '${(item.reviewNote ?? '').isEmpty ? '' : ' · ${item.reviewNote}'}',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (item.isPending) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmReject(context),
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Отклонить'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: BorderSide(
                        color: AppColors.error.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _confirmApprove(context),
                    icon: const Icon(Icons.check_rounded, size: 16),
                    label: const Text('Одобрить'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmApprove(BuildContext context) async {
    final note = await _askNote(
      context,
      title: 'Одобрить заявку?',
      action: 'Одобрить',
      isDestructive: false,
    );
    if (note == null || !context.mounted) return;
    context.read<ApprovalBloc>().add(
          ApprovalApproveRequested(item.id, note: note),
        );
  }

  Future<void> _confirmReject(BuildContext context) async {
    final note = await _askNote(
      context,
      title: 'Отклонить заявку?',
      action: 'Отклонить',
      isDestructive: true,
    );
    if (note == null || !context.mounted) return;
    context.read<ApprovalBloc>().add(
          ApprovalRejectRequested(item.id, note: note),
        );
  }

  Future<String?> _askNote(
    BuildContext context, {
    required String title,
    required String action,
    required bool isDestructive,
  }) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Комментарий (опционально)',
            hintText: 'Что увидит инициатор',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: isDestructive
                ? FilledButton.styleFrom(backgroundColor: AppColors.error)
                : null,
            onPressed: () => Navigator.of(dialogCtx).pop(ctrl.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

class _PayloadBlock extends StatelessWidget {
  const _PayloadBlock({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = payload.entries
        .where((e) => e.value != null && e.value.toString().isNotEmpty)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'JetBrains Mono',
                    height: 1.35,
                  ),
                  children: [
                    TextSpan(
                      text: '${e.key}: ',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    TextSpan(
                      text: e.value.toString(),
                      style: TextStyle(color: scheme.onSurface),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
