import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/icons/app_icons.dart';

/// Экран «Сверка» (reconciliation) — только для creator/director.
///
/// Read-only: показывает расхождения (drift) по филиалам и контрагентам,
/// которые backend-агент пишет в таблицу `reconciliation_alerts` через
/// RPC `run_reconciliation()`. По кнопке «Запустить сверку» вызываем RPC,
/// парсим возвращённый jsonb-summary и подтягиваем строки из таблицы.
///
/// Код намеренно оборонительный: backend-миграция (080) выкатывается
/// параллельно, поэтому отсутствие RPC/таблицы трактуем как «пока нечего
/// показать», а не как фатальную ошибку приложения.
class ReconciliationPage extends StatefulWidget {
  const ReconciliationPage({super.key});

  @override
  State<ReconciliationPage> createState() => _ReconciliationPageState();
}

class _ReconciliationPageState extends State<ReconciliationPage> {
  SupabaseClient get _db => Supabase.instance.client;

  bool _running = false;
  bool _initialLoad = true;
  String? _error;
  DateTime? _lastRunAt;

  /// Сводка из jsonb, который вернул RPC. Храним как «плоский» список
  /// пар ключ→значение для устойчивого отображения любых полей.
  Map<String, dynamic> _summary = const {};

  /// Строки расхождений из таблицы reconciliation_alerts.
  List<_Drift> _alerts = const [];

  @override
  void initState() {
    super.initState();
    // При входе не запускаем тяжёлую сверку автоматически — только
    // подтягиваем уже накопленные расхождения (если таблица есть).
    _loadAlerts(initial: true);
  }

  /// Чисто чтение существующих строк (без запуска RPC).
  Future<void> _loadAlerts({bool initial = false}) async {
    if (mounted) {
      setState(() {
        _error = null;
        if (initial) _initialLoad = true;
      });
    }
    try {
      final rows = await _db
          .from('reconciliation_alerts')
          .select(
              'id,scope,scope_id,kind,expected,actual,delta,detected_at')
          .order('detected_at', ascending: false)
          .limit(500)
          .timeout(const Duration(seconds: 20)) as List;
      final parsed = rows
          .map((e) => _Drift.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _alerts = parsed;
        _initialLoad = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Таблицы ещё нет (миграция 080 не применена) — это не ошибка для
      // пользователя, просто пустое состояние.
      if (_isMissingObject(e)) {
        setState(() {
          _alerts = const [];
          _initialLoad = false;
        });
        return;
      }
      setState(() {
        _error = _humanize(e);
        _initialLoad = false;
      });
    }
  }

  /// Запускает RPC `run_reconciliation()`, парсит summary, перечитывает
  /// строки.
  Future<void> _runReconciliation() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result = await _db
          .rpc('run_reconciliation')
          .timeout(const Duration(seconds: 60));
      // RPC может вернуть jsonb-объект (summary) или ничего полезного —
      // парсим максимально терпимо.
      Map<String, dynamic> summary = const {};
      if (result is Map) {
        summary = Map<String, dynamic>.from(result);
      } else if (result is List && result.isNotEmpty && result.first is Map) {
        summary = Map<String, dynamic>.from(result.first as Map);
      }
      if (mounted) {
        setState(() {
          _summary = summary;
          _lastRunAt = DateTime.now();
        });
      }
      // После запуска — перечитываем накопленные расхождения.
      await _loadAlerts();
    } catch (e) {
      if (!mounted) return;
      if (_isMissingObject(e)) {
        setState(() {
          _error =
              'Серверная сверка ещё не развёрнута. Попробуйте позже.';
        });
      } else {
        setState(() => _error = _humanize(e));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  bool _isMissingObject(Object e) {
    final s = e.toString();
    return s.contains('PGRST202') ||
        s.contains('42883') || // undefined_function
        s.contains('42P01') || // undefined_table
        s.contains('does not exist') ||
        s.contains('Could not find');
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException')) {
      return 'Превышено время ожидания. Проверьте соединение и повторите.';
    }
    return 'Не удалось выполнить сверку: $s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сверка'),
        actions: [
          IconButton(
            icon: const Icon(AppIcons.refresh),
            tooltip: 'Обновить',
            onPressed: _running ? null : () => _loadAlerts(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadAlerts(),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            _header(theme),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[
              _errorCard(theme, _error!),
              const SizedBox(height: AppSpacing.lg),
            ],
            if (_summary.isNotEmpty) ...[
              _summaryCard(theme),
              const SizedBox(height: AppSpacing.lg),
            ],
            _resultsSection(theme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Расхождения по филиалам и контрагентам',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Запустите сверку, чтобы сопоставить ожидаемые и фактические '
          'остатки. Дрейф (delta ≠ 0) означает расхождение, требующее '
          'внимания.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _runReconciliation,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.fact_check),
              label: Text(_running ? 'Сверяем…' : 'Запустить сверку'),
            ),
            if (_lastRunAt != null) ...[
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: Text(
                  'Последний запуск: ${_fmtTime(_lastRunAt!)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final entries = _summary.entries.toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Сводка',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.md,
              children: [
                for (final e in entries)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _prettyKey(e.key),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${e.value}',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultsSection(ThemeData theme) {
    if (_initialLoad) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_alerts.isEmpty) {
      return _emptyState(theme);
    }

    // Группируем расхождения по scope (branch / counterparty).
    final byBranch =
        _alerts.where((a) => a.scope.toLowerCase() == 'branch').toList();
    final byCounterparty = _alerts
        .where((a) => a.scope.toLowerCase() == 'counterparty')
        .toList();
    final other = _alerts
        .where((a) =>
            a.scope.toLowerCase() != 'branch' &&
            a.scope.toLowerCase() != 'counterparty')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (byBranch.isNotEmpty) ...[
          _groupHeader(theme, AppIcons.business,
              'По филиалам', byBranch.length),
          ...byBranch.map((a) => _DriftTile(drift: a)),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (byCounterparty.isNotEmpty) ...[
          _groupHeader(theme, AppIcons.account_tree,
              'По контрагентам', byCounterparty.length),
          ...byCounterparty.map((a) => _DriftTile(drift: a)),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (other.isNotEmpty) ...[
          _groupHeader(
              theme, AppIcons.fact_check, 'Прочее', other.length),
          ...other.map((a) => _DriftTile(drift: a)),
        ],
      ],
    );
  }

  Widget _groupHeader(
      ThemeData theme, IconData icon, String title, int count) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(AppIcons.check_circle,
                  size: 40, color: scheme.primary),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Расхождений нет',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Ожидаемые и фактические остатки совпадают.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(ThemeData theme, String message) {
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(AppIcons.warning_amber, color: scheme.onErrorContainer),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _prettyKey(String key) {
    // run_reconciliation -> понятный лейбл; иначе чуть причёсываем snake_case.
    const map = {
      // Ключи возвращает public.run_reconciliation() (миграция 080) — camelCase.
      'runAt': 'Запуск',
      'balanced': 'Сбалансировано',
      'branchesChecked': 'Проверено филиалов',
      'branchAlerts': 'Расхождений по филиалам',
      'counterpartiesChecked': 'Проверено партнёров',
      'counterpartyAlerts': 'Расхождений по партнёрам',
      'totalAlerts': 'Всего расхождений',
    };
    final m = map[key];
    if (m != null) return m;
    return key
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp('^.'), (m) => m.group(0)!.toUpperCase());
  }

  String _fmtTime(DateTime d) =>
      DateFormat('dd.MM.yyyy HH:mm').format(d.toLocal());
}

/// Одна строка расхождения из таблицы reconciliation_alerts.
class _Drift {
  const _Drift({
    required this.id,
    required this.scope,
    required this.scopeId,
    required this.kind,
    required this.expected,
    required this.actual,
    required this.delta,
    required this.detectedAt,
  });

  final String id;
  final String scope;
  final String? scopeId;
  final String? kind;
  final num? expected;
  final num? actual;
  final num? delta;
  final DateTime? detectedAt;

  factory _Drift.fromMap(Map<String, dynamic> m) {
    num? toNum(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      return num.tryParse(v.toString());
    }

    DateTime? toDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString());
    }

    return _Drift(
      id: (m['id'] ?? '').toString(),
      scope: (m['scope'] ?? '').toString(),
      scopeId: m['scope_id']?.toString(),
      kind: m['kind']?.toString(),
      expected: toNum(m['expected']),
      actual: toNum(m['actual']),
      delta: toNum(m['delta']),
      detectedAt: toDate(m['detected_at']),
    );
  }
}

class _DriftTile extends StatelessWidget {
  const _DriftTile({required this.drift});
  final _Drift drift;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final delta = drift.delta ?? 0;
    final isZero = delta == 0;
    final deltaColor = isZero
        ? scheme.onSurfaceVariant
        : (delta > 0 ? Colors.green.shade600 : scheme.error);

    final fmt = NumberFormat('#,##0.##', 'ru');

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    drift.kind?.isNotEmpty == true
                        ? drift.kind!
                        : (drift.scopeId ?? drift.scope),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: deltaColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Δ ${delta > 0 ? '+' : ''}${fmt.format(delta)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: deltaColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                _miniStat(theme, 'Ожидается',
                    drift.expected == null ? '—' : fmt.format(drift.expected)),
                const SizedBox(width: AppSpacing.xl),
                _miniStat(theme, 'Фактически',
                    drift.actual == null ? '—' : fmt.format(drift.actual)),
              ],
            ),
            if (drift.scopeId != null && drift.scopeId!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'ID: ${drift.scopeId}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (drift.detectedAt != null) ...[
              const SizedBox(height: 2),
              Text(
                'Обнаружено: '
                '${DateFormat('dd.MM.yyyy HH:mm').format(drift.detectedAt!.toLocal())}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _miniStat(ThemeData theme, String label, String value) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
        Text(value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
