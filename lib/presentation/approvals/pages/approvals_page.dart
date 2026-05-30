import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/presentation/approvals/bloc/approval_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';

import 'package:ethnocount/core/icons/app_icons.dart';

/// Цвет акцента по типу действия — используется и в borderLeft карточки,
/// и в чипе с label-ом. Опасные операции (архивация клиента, изменение
/// суммы перевода) подсвечены красным, рутинные обновления — secondary.
Color _approvalAccent(ApprovalAction action) {
  switch (action) {
    case ApprovalAction.transferAmendAmount:
      return AppColors.warning;
    case ApprovalAction.clientUpdate:
      return AppColors.secondary;
    case ApprovalAction.clientArchive:
      return AppColors.error;
    case ApprovalAction.branchAccountUpdate:
      return AppColors.secondary;
    case ApprovalAction.branchAccountArchive:
      return AppColors.error;
  }
}

IconData _approvalIcon(ApprovalAction action) {
  switch (action) {
    case ApprovalAction.transferAmendAmount:
      return AppIcons.edit_note;
    case ApprovalAction.clientUpdate:
      return AppIcons.person_outline;
    case ApprovalAction.clientArchive:
      return AppIcons.delete_outline;
    case ApprovalAction.branchAccountUpdate:
      return AppIcons.account_balance;
    case ApprovalAction.branchAccountArchive:
      return AppIcons.archive;
  }
}

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

/// Категория фильтра — определяет какие [ApprovalAction] показывать.
enum _ApprovalCategory { all, finance, clients, accounts }

class _ApprovalsView extends StatefulWidget {
  const _ApprovalsView();
  @override
  State<_ApprovalsView> createState() => _ApprovalsViewState();
}

class _ApprovalsViewState extends State<_ApprovalsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  _ApprovalCategory _category = _ApprovalCategory.all;

  bool _matchesCategory(ApprovalAction action) {
    switch (_category) {
      case _ApprovalCategory.all:
        return true;
      case _ApprovalCategory.finance:
        return action == ApprovalAction.transferAmendAmount;
      case _ApprovalCategory.clients:
        return action == ApprovalAction.clientUpdate ||
            action == ApprovalAction.clientArchive;
      case _ApprovalCategory.accounts:
        return action == ApprovalAction.branchAccountUpdate ||
            action == ApprovalAction.branchAccountArchive;
    }
  }

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
            final byStatus = showHistory
                ? state.items
                : state.items
                    .where((e) => e.status == ApprovalStatus.pending)
                    .toList();
            final list = byStatus
                .where((e) => _matchesCategory(e.action))
                .toList(growable: false);

            // Считаем summary по всем загруженным items (не по фильтру
            // вкладки — оператор хочет видеть «N pending» даже когда
            // открыта History).
            final pendingCount = state.items
                .where((e) => e.status == ApprovalStatus.pending)
                .length;
            final today = DateTime.now();
            final todayStart =
                DateTime(today.year, today.month, today.day);
            final approvedToday = state.items
                .where((e) =>
                    e.status == ApprovalStatus.approved &&
                    e.reviewedAt != null &&
                    e.reviewedAt!.toLocal().isAfter(todayStart))
                .length;
            final rejectedToday = state.items
                .where((e) =>
                    e.status == ApprovalStatus.rejected &&
                    e.reviewedAt != null &&
                    e.reviewedAt!.toLocal().isAfter(todayStart))
                .length;

            // Счётчики чипов считаем по byStatus (после tab-filter), чтобы
            // в Pending показывало «сколько pending по этой категории», в
            // History — сколько в истории.
            int byCat(bool Function(ApprovalAction) match) =>
                byStatus.where((e) => match(e.action)).length;
            return Column(
              children: [
                _SummaryStrip(
                  pending: pendingCount,
                  approvedToday: approvedToday,
                  rejectedToday: rejectedToday,
                ),
                _CategoryChips(
                  category: _category,
                  onChanged: (c) => setState(() => _category = c),
                  allCount: byStatus.length,
                  financeCount: byCat((a) =>
                      a == ApprovalAction.transferAmendAmount),
                  clientsCount: byCat((a) =>
                      a == ApprovalAction.clientUpdate ||
                      a == ApprovalAction.clientArchive),
                  accountsCount: byCat((a) =>
                      a == ApprovalAction.branchAccountUpdate ||
                      a == ApprovalAction.branchAccountArchive),
                ),
                Expanded(
                  child: list.isEmpty
                      ? EmptyState(
                          icon: AppIcons.fact_check,
                          title: showHistory
                              ? 'Истории пока нет'
                              : 'Заявок нет',
                          subtitle: showHistory
                              ? 'Здесь будут одобренные и отклонённые заявки.'
                              : 'Когда бухгалтер запросит изменение — оно появится тут.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          itemCount: list.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (_, i) =>
                              _ApprovalCard(item: list[i]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Горизонтальные pill-чипы под summary-strip: Все / Финансы / Клиенты /
/// Счета. Каждый чип со счётчиком в моно-шрифте; активный — с акцентным
/// цветом-обводкой по категории.
class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.category,
    required this.onChanged,
    required this.allCount,
    required this.financeCount,
    required this.clientsCount,
    required this.accountsCount,
  });
  final _ApprovalCategory category;
  final ValueChanged<_ApprovalCategory> onChanged;
  final int allCount;
  final int financeCount;
  final int clientsCount;
  final int accountsCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chips = <(String, _ApprovalCategory, int, Color)>[
      ('Все', _ApprovalCategory.all, allCount, AppColors.darkTextSecondary),
      ('Финансы', _ApprovalCategory.finance, financeCount, AppColors.warning),
      ('Клиенты', _ApprovalCategory.clients, clientsCount, AppColors.secondary),
      ('Счета', _ApprovalCategory.accounts, accountsCount, AppColors.primary),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 8, AppSpacing.md, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.10)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final c in chips) ...[
              _CategoryChip(
                label: c.$1,
                count: c.$3,
                accent: c.$4,
                active: category == c.$2,
                onTap: () => onChanged(c.$2),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.count,
    required this.accent,
    required this.active,
    required this.onTap,
  });
  final String label;
  final int count;
  final Color accent;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? accent : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color:
                active ? accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(
              color: active
                  ? accent
                  : scheme.outline.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Полоска с тремя плитками: pending (warning) / approved-today (success) /
/// rejected-today (error). Видна всегда поверх TabBar-контента, чтобы
/// директор сразу понимал нагрузку.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.pending,
    required this.approvedToday,
    required this.rejectedToday,
  });
  final int pending;
  final int approvedToday;
  final int rejectedToday;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryTile(
              icon: AppIcons.schedule,
              label: 'ОЖИДАЮТ',
              value: '$pending',
              accent: AppColors.warning,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SummaryTile(
              icon: AppIcons.check_circle_outline,
              label: 'ОДОБРЕНЫ СЕГОДНЯ',
              value: '$approvedToday',
              accent: AppColors.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SummaryTile(
              icon: AppIcons.close,
              label: 'ОТКЛОНЕНЫ СЕГОДНЯ',
              value: '$rejectedToday',
              accent: AppColors.error,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ],
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
    final accent = _approvalAccent(item.action);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border(
          left: BorderSide(color: accent, width: 3),
          top: BorderSide(color: scheme.outline.withValues(alpha: 0.18)),
          right: BorderSide(color: scheme.outline.withValues(alpha: 0.18)),
          bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.18)),
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Иконка-аватар категории действия (warning/error/secondary).
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(_approvalIcon(item.action), size: 17, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.action.label,
                  style: const TextStyle(
                    fontSize: 14.5,
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
                    icon: const Icon(AppIcons.close, size: 16),
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
                    icon: const Icon(AppIcons.check, size: 16),
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
    // Если в payload есть `_before` (миграция 052), рендерим diff
    // before → after по пересечению ключей. Иначе — просто payload.
    final before = payload['_before'] is Map
        ? Map<String, dynamic>.from(payload['_before'] as Map)
        : null;
    final after = Map<String, dynamic>.from(payload)..remove('_before');

    if (before != null && before.isNotEmpty) {
      return _DiffBlock(before: before, after: after, scheme: scheme);
    }

    final entries = after.entries
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

/// Before → after diff:
///   • поля только в before и not in after → не показываем
///   • поля только в after → подсвечены primary (нет старого значения)
///   • совпадающие ключи: показываем «old → new» в моно-шрифте, разные
///     значения подсвечены, одинаковые — приглушённо.
class _DiffBlock extends StatelessWidget {
  const _DiffBlock({
    required this.before,
    required this.after,
    required this.scheme,
  });
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;
  final ColorScheme scheme;

  String _fmt(dynamic v) {
    if (v == null) return '—';
    if (v is List) return v.join(', ');
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    // Список ключей: union(before, after), но показываем только те где
    // есть изменения (after содержит новое значение). Если значение
    // одинаковое — пропускаем (не лезем в глаз).
    final keys = <String>{...after.keys, ...before.keys}
        .where((k) => after.containsKey(k))
        .toList()
      ..sort();

    final rows = <Widget>[];
    for (final k in keys) {
      final bv = before[k];
      final av = after[k];
      final unchanged =
          (bv == null && av == null) || (bv != null && av != null && bv.toString() == av.toString());
      if (unchanged) continue;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                k,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'JetBrains Mono',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  _DiffPill(
                    text: _fmt(bv),
                    bg: AppColors.error.withValues(alpha: 0.10),
                    fg: AppColors.error,
                    strike: true,
                  ),
                  Icon(
                    Icons.arrow_forward,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  _DiffPill(
                    text: _fmt(av),
                    bg: AppColors.primary.withValues(alpha: 0.12),
                    fg: AppColors.primary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ));
    }

    if (rows.isEmpty) {
      // Все ключи совпадают (странная заявка), показываем info.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Нет изменений в значениях полей.',
          style: TextStyle(
            fontSize: 11.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

class _DiffPill extends StatelessWidget {
  const _DiffPill({
    required this.text,
    required this.bg,
    required this.fg,
    this.strike = false,
  });
  final String text;
  final Color bg;
  final Color fg;
  final bool strike;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: 'JetBrains Mono',
          color: fg,
          decoration: strike ? TextDecoration.lineThrough : null,
          decorationColor: fg.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
