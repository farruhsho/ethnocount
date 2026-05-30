import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/core/utils/phone_input_formatter.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/counterparties/widgets/account_option.dart';
import 'package:ethnocount/presentation/counterparties/widgets/partner_transfer_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/attach_transfer_to_partner_dialog.dart';

/// Страница «Контрагенты» — внешние посредники в других городах с
/// взаимным сальдо. Видно creator/director. Бухгалтер видит как
/// справочник, без возможности создавать.
class CounterpartiesPage extends StatefulWidget {
  const CounterpartiesPage({super.key});

  @override
  State<CounterpartiesPage> createState() => _CounterpartiesPageState();
}

enum _SortMode {
  byName('По имени', AppIcons.sort),
  bySaldo('По сальдо', AppIcons.percent),
  byActivity('По активности', AppIcons.history);

  const _SortMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _CounterpartiesPageState extends State<CounterpartiesPage> {
  List<_Counterparty> _list = const [];
  _Counterparty? _selected;
  bool _loading = true;
  String? _error;
  List<_CounterpartyTx> _tx = const [];
  bool _txLoading = false;

  // ── Поиск / сортировка / архив ──────────────────────────────
  String _searchQuery = '';
  _SortMode _sortMode = _SortMode.byName;
  bool _showArchived = false;

  SupabaseClient get _db => Supabase.instance.client;

  /// Применяет search + sort к загруженному списку.
  List<_Counterparty> get _visible {
    final q = _searchQuery.trim().toLowerCase();
    var items = q.isEmpty
        ? List<_Counterparty>.from(_list)
        : _list.where((c) {
            if (c.name.toLowerCase().contains(q)) return true;
            if ((c.city ?? '').toLowerCase().contains(q)) return true;
            if ((c.phone ?? '').contains(q)) return true;
            return false;
          }).toList();
    switch (_sortMode) {
      case _SortMode.byName:
        items.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SortMode.bySaldo:
        items.sort((a, b) => b.saldoMagnitude.compareTo(a.saldoMagnitude));
        break;
      case _SortMode.byActivity:
        items.sort((a, b) {
          final aT = a.lastOpAt ?? DateTime(1970);
          final bT = b.lastOpAt ?? DateTime(1970);
          return bT.compareTo(aT);
        });
        break;
    }
    return items;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Сначала пробуем расширенный RPC (миграция 034) — он отдаёт
      // tx_count + last_op_at + fee_percentage в одном запросе.
      List<dynamic> rows;
      try {
        rows = await _db.rpc(
          'counterparties_list',
          params: {'p_include_archived': _showArchived},
        ).timeout(const Duration(seconds: 20)) as List;
      } catch (rpcErr) {
        // Fallback: миграция 034 ещё не применена — используем прямой
        // select. tx_count / last_op_at будут 0/null, fee_percentage
        // вытащим прямо из таблицы.
        final s = rpcErr.toString();
        if (!s.contains('PGRST') &&
            !s.contains('42883') &&
            !s.contains('does not exist')) {
          rethrow;
        }
        var q = _db.from('counterparties').select(
            'id,name,city,phone,notes,saldo_by_currency,'
            'exposure_limit_by_currency,is_active,'
            'home_branch_id,fee_percentage');
        if (!_showArchived) q = q.eq('is_active', true);
        rows = await q.order('name').timeout(const Duration(seconds: 20))
            as List;
      }
      final items = rows
          .map((e) =>
              _Counterparty.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      setState(() {
        _list = items;
        _loading = false;
        if (_selected != null) {
          _selected = items.firstWhere(
            (c) => c.id == _selected!.id,
            orElse: () => items.isEmpty ? _selected! : items.first,
          );
        }
      });
      if (_selected != null) _loadTx(_selected!);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = _humanizeLoadError(e);
      });
    }
  }

  /// Экспорт операций партнёра. Тянем через RPC counterparty_tx_export
  /// (миграция 035), собираем CSV-строку, копируем в буфер обмена.
  /// Это минимально-инвазивно (без новых зависимостей) и работает на
  /// всех платформах — пользователь вставляет в Excel/Numbers/Sheets.
  Future<void> _exportCounterparty(_Counterparty c) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text('Готовлю экспорт операций «${c.name}»…'),
      duration: const Duration(seconds: 2),
    ));
    try {
      final rows = await _db.rpc('counterparty_tx_export', params: {
        'p_counterparty_id': c.id,
      }).timeout(const Duration(seconds: 30));
      final list = (rows as List).cast<Map<String, dynamic>>();
      final csv = _csvForOps(c, list);
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(
          'CSV «${c.name}» (${list.length} операций) скопирован в буфер обмена. '
          'Откройте Excel/Sheets → Вставить.',
        ),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text('Не удалось экспортировать: $e'),
        backgroundColor: AppColors.error,
      ));
    }
  }

  /// Собирает CSV (RFC 4180-совместимый: `,` разделитель, `"` для
  /// экранирования двойных кавычек и переводов строк внутри ячеек).
  /// BOM на старте — чтобы Excel правильно показывал кириллицу.
  String _csvForOps(_Counterparty c, List<Map<String, dynamic>> rows) {
    String esc(Object? v) {
      if (v == null) return '';
      final s = v.toString();
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"${s.replaceAll('"', '""')}"';
      }
      return s;
    }

    final buf = StringBuffer('﻿'); // UTF-8 BOM
    buf.writeln('Партнёр: ${esc(c.name)}');
    if (c.city != null) buf.writeln('Город: ${esc(c.city)}');
    if (c.phone != null) buf.writeln('Телефон: ${esc(c.phone)}');
    buf.writeln(
        'Экспорт: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buf.writeln();
    buf.writeln([
      'Дата',
      'Тип',
      'Сумма',
      'Валюта',
      'Описание',
      'Способ выплаты',
      'Курс',
      'Номер перевода',
    ].map(esc).join(','));
    for (final r in rows) {
      final dt = DateTime.tryParse(r['created_at']?.toString() ?? '');
      buf.writeln([
        dt == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(dt),
        r['kind_label'] ?? r['kind'] ?? '',
        r['amount'] ?? '',
        r['currency'] ?? '',
        r['description'] ?? '',
        r['payout_method'] ?? '',
        r['exchange_rate'] ?? '',
        r['transaction_code'] ?? '',
      ].map(esc).join(','));
    }
    return buf.toString();
  }

  Future<void> _toggleArchive(_Counterparty c) async {
    final user = context.read<AuthBloc>().state.user;
    if (user == null || !userSeesAllBranches(user)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Только Creator/Director может архивировать партнёров')),
      );
      return;
    }
    final goingToArchive = c.isActive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(goingToArchive
            ? 'Архивировать партнёра?'
            : 'Разархивировать партнёра?'),
        content: Text(
          goingToArchive
              ? '${c.name} больше не появится в списке для новых переводов. '
                  'История останется. Можно вернуть из архива в любой момент.'
              : '${c.name} снова станет доступен для новых переводов.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(goingToArchive ? 'Архивировать' : 'Восстановить')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _db.rpc('set_counterparty_active', params: {
        'p_counterparty_id': c.id,
        'p_active': !c.isActive,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(goingToArchive
            ? '${c.name} архивирован'
            : '${c.name} восстановлен'),
      ));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Не удалось: $e'),
        backgroundColor: AppColors.error,
      ));
    }
  }

  /// Превращает технический Postgrest/network error в человекочитаемое
  /// сообщение. Главные кейсы:
  ///  • `42P01` / `does not exist` → таблица `counterparties` ещё не
  ///    создана: миграция 029_counterparties.sql не применена.
  ///  • `42883` → RPC `record_counterparty_op` старой сигнатуры: 033 не
  ///    применена.
  ///  • timeout / семафор → сеть/Supabase.
  String _humanizeLoadError(Object e) {
    final s = e.toString();
    if (s.contains('does not exist') ||
        s.contains('relation "public.counterparties"') ||
        s.contains('42P01')) {
      return 'Таблица «counterparties» ещё не создана в базе.\n\n'
          'Примените миграции 029_counterparties.sql и 033_partner_transfers.sql '
          'через «supabase db push» или Supabase Dashboard → SQL Editor. '
          'Без них раздел «Партнёры» работать не может.';
    }
    if (s.contains('PGRST202') || s.contains('42883')) {
      return 'RPC «record_counterparty_op» отсутствует или со старой '
          'сигнатурой.\n\nПрименённая миграция 029 без 033 даёт устаревший '
          'вариант. Запустите 033_partner_transfers.sql.';
    }
    if (s.contains('Превышен таймаут') ||
        s.contains('TimeoutException') ||
        s.contains('semaphore')) {
      return 'Превышен сетевой таймаут. Проверьте интернет/VPN — Supabase '
          'недоступен. Нажмите «Обновить» через несколько секунд.';
    }
    return 'Не удалось загрузить партнёров: $s';
  }

  Future<void> _loadTx(_Counterparty c) async {
    setState(() {
      _txLoading = true;
      _tx = const [];
    });
    try {
      // Сначала пробуем расширенный RPC (миграция 038) — он отдаёт
      // buy_rate, sell_rate, spread_profit и via_counterparty в одном
      // вызове через join с transfers.
      List<dynamic> rows;
      try {
        rows = await _db.rpc(
          'counterparty_tx_detail',
          params: {'p_counterparty_id': c.id, 'p_limit': 100},
        ).timeout(const Duration(seconds: 12)) as List;
      } catch (rpcErr) {
        final s = rpcErr.toString();
        if (!s.contains('PGRST') &&
            !s.contains('42883') &&
            !s.contains('does not exist')) {
          rethrow;
        }
        // Fallback на старый select без курсов.
        rows = await _db
            .from('counterparty_transactions')
            .select('id,kind,amount,currency,description,created_at')
            .eq('counterparty_id', c.id)
            .order('created_at', ascending: false)
            .limit(100) as List;
      }
      setState(() {
        _tx = rows
            .map((e) =>
                _CounterpartyTx.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        _txLoading = false;
      });
    } catch (_) {
      setState(() => _txLoading = false);
    }
  }

  void _onSelect(_Counterparty c) {
    setState(() => _selected = c);
    _loadTx(c);
  }

  Future<void> _openCreateDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _CreateCounterpartyDialog(),
    );
    if (ok == true) {
      messenger.showSnackBar(SnackBar(
        content: const Row(
          children: [
            Icon(AppIcons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Партнёр создан'),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
      _load();
    }
  }

  Future<void> _openRecordOpDialog() async {
    if (_selected == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _RecordOpDialog(counterparty: _selected!),
    );
    if (ok == true) _load();
  }

  Future<void> _openEditDialog(_Counterparty c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _EditCounterpartyDialog(counterparty: c),
    );
    if (ok == true) _load();
  }

  /// Открывает диалог выбора существующего перевода для прикрепления к
  /// этому партнёру. RPC `attach_transfer_to_partner` сам:
  ///   • обновляет via_counterparty_id
  ///   • пересчитывает spread_profit если переданы buy/sell
  ///   • двигает saldo партнёра
  ///   • создаёт counterparty_transactions(paid_for_us)
  /// Быстрый settle через карточку сальдо. Открывает RecordOpDialog
  /// с предзаполненной категорией Settlement и направлением:
  ///   saldo > 0 → он должен → settle_to_us (он привёз)
  ///   saldo < 0 → мы должны → settle_from_us (мы отдали)
  Future<void> _openSettleDialog(
      _Counterparty c, String currency, double saldoValue) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _RecordOpDialog(
        counterparty: c,
        presetCategory: _OpCategory.settlement,
        presetDirection: saldoValue > 0,
        presetCurrency: currency,
        presetAmount: saldoValue.abs(),
      ),
    );
    if (ok == true) {
      messenger.showSnackBar(SnackBar(
        content: Text('Расчёт с ${c.name} записан'),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ));
      if (_selected != null) _loadTx(_selected!);
      _load();
    }
  }

  Future<void> _openAttachDialog(_Counterparty c) async {
    final messenger = ScaffoldMessenger.of(context);
    // Передаём partner как Map, чтобы переиспользовать единый shared
    // диалог из transfers/widgets. saldo_by_currency нужен для preview
    // (показывает «было / станет должен» в валюте перевода).
    final partnerMap = <String, dynamic>{
      'id': c.id,
      'name': c.name,
      'city': c.city,
      'saldo_by_currency': c.saldo,
      'home_branch_id': null, // не используется в UI диалога
      'is_active': c.isActive,
    };
    final ok = await showAttachTransferToPartnerDialog(
      context,
      mode: AttachTransferDialogMode.knownPartner,
      partner: partnerMap,
    );
    if (ok == true) {
      messenger.showSnackBar(SnackBar(
        content: Text('Перевод прикреплён к ${c.name}'),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ));
      if (_selected != null) _loadTx(_selected!);
      _load();
    }
  }

  Future<void> _openPartnerTransferDialog() async {
    final c = _selected;
    if (c == null) return;
    if (!c.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${c.name} в архиве — сначала восстановите его, чтобы создать перевод.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    final ok = await showPartnerTransferDialog(
      context,
      counterpartyId: c.id,
      counterpartyName: c.name,
      feePercentage: c.feePercentage,
    );
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final canManage = user != null;
    final canArchive = userSeesAllBranches(user);
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Партнёры'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _SearchSortBar(
            query: _searchQuery,
            onQueryChanged: (v) => setState(() => _searchQuery = v),
            sortMode: _sortMode,
            onSortChanged: (m) => setState(() => _sortMode = m),
            showArchived: _showArchived,
            onShowArchivedChanged: canArchive
                ? (v) {
                    setState(() => _showArchived = v);
                    _load();
                  }
                : null,
          ),
        ),
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(AppIcons.person_add),
              tooltip: 'Новый партнёр',
              onPressed: _openCreateDialog,
            ),
          IconButton(
            icon: const Icon(AppIcons.refresh),
            tooltip: 'Обновить',
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _load();
          if (_selected != null) await _loadTx(_selected!);
        },
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _LoadErrorView(message: _error!, onRetry: _load)
              : _list.isEmpty
                  ? _EmptyView(canManage: canManage, onCreate: _openCreateDialog)
                  : visible.isEmpty
                      ? _NoMatchesView(query: _searchQuery)
                      : context.isDesktop
                          ? _DesktopBody(
                              list: visible,
                              selected: _selected,
                              tx: _tx,
                              txLoading: _txLoading,
                              onSelect: _onSelect,
                              onRecord:
                                  canManage ? _openRecordOpDialog : null,
                              onPartnerTransfer: canManage
                                  ? _openPartnerTransferDialog
                                  : null,
                              onToggleArchive:
                                  canArchive ? _toggleArchive : null,
                              onEdit: canManage ? _openEditDialog : null,
                              onExport: canManage ? _exportCounterparty : null,
                              onAttach: canManage ? _openAttachDialog : null,
                              onSettle: canManage ? _openSettleDialog : null,
                              onBackfilled: () {
                                if (_selected != null) _loadTx(_selected!);
                                _load();
                              },
                            )
                          : _MobileBody(
                              list: visible,
                              onToggleArchive:
                                  canArchive ? _toggleArchive : null,
                              onSelect: (c) async {
                                _onSelect(c);
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                      appBar: AppBar(title: Text(c.name)),
                                      body: _buildDetailPanel(c,
                                          canManage: canManage,
                                          canArchive: canArchive),
                                    ),
                                  ),
                                );
                              },
                            ),
      ),
    );
  }

  /// Единая фабрика _DetailPanel — пробрасывает все callback'и. Используется
  /// в обоих local UI (desktop Expanded и mobile MaterialPageRoute), чтобы
  /// добавление новой кнопки правилось ровно в одном месте.
  Widget _buildDetailPanel(_Counterparty c, {
    required bool canManage,
    required bool canArchive,
  }) {
    return _DetailPanel(
      counterparty: c,
      tx: _tx,
      txLoading: _txLoading,
      onRecord: canManage ? _openRecordOpDialog : null,
      onPartnerTransfer: canManage ? _openPartnerTransferDialog : null,
      onToggleArchive:
          canArchive ? () => _toggleArchive(c) : null,
      onEdit: canManage ? () => _openEditDialog(c) : null,
      onExport: canManage ? () => _exportCounterparty(c) : null,
      onAttach: canManage ? () => _openAttachDialog(c) : null,
      onSettle: canManage
          ? (cur, val) => _openSettleDialog(c, cur, val)
          : null,
      onBackfilled: () {
        _loadTx(c);
        _load();
      },
    );
  }
}

/// Полоска под AppBar: поиск + chip-row сортировки + checkbox архива.
class _SearchSortBar extends StatelessWidget {
  const _SearchSortBar({
    required this.query,
    required this.onQueryChanged,
    required this.sortMode,
    required this.onSortChanged,
    required this.showArchived,
    required this.onShowArchivedChanged,
  });

  final String query;
  final ValueChanged<String> onQueryChanged;
  final _SortMode sortMode;
  final ValueChanged<_SortMode> onSortChanged;
  final bool showArchived;
  final ValueChanged<bool>? onShowArchivedChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                onChanged: onQueryChanged,
                decoration: InputDecoration(
                  hintText: 'Поиск по имени, городу, телефону…',
                  prefixIcon: const Icon(AppIcons.search, size: 18),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  fillColor:
                      scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  filled: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PopupMenuButton<_SortMode>(
            tooltip: 'Сортировка',
            initialValue: sortMode,
            onSelected: onSortChanged,
            position: PopupMenuPosition.under,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(sortMode.icon, size: 16),
                  const SizedBox(width: 6),
                  Text(sortMode.label,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            itemBuilder: (_) => _SortMode.values
                .map((m) => PopupMenuItem(
                      value: m,
                      child: Row(
                        children: [
                          Icon(m.icon, size: 16),
                          const SizedBox(width: 8),
                          Text(m.label),
                        ],
                      ),
                    ))
                .toList(),
          ),
          if (onShowArchivedChanged != null) ...[
            const SizedBox(width: AppSpacing.sm),
            FilterChip(
              selected: showArchived,
              onSelected: onShowArchivedChanged,
              label: const Text('Архив'),
              avatar: Icon(
                showArchived ? AppIcons.unarchive : AppIcons.archive,
                size: 14,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoMatchesView extends StatelessWidget {
  const _NoMatchesView({required this.query});
  final String query;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.search, size: 48, color: Colors.grey),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Никого не нашли по «$query»',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            'Попробуй изменить запрос или включить «Архив»',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _DesktopBody extends StatelessWidget {
  const _DesktopBody({
    required this.list,
    required this.selected,
    required this.tx,
    required this.txLoading,
    required this.onSelect,
    required this.onRecord,
    required this.onPartnerTransfer,
    required this.onToggleArchive,
    required this.onEdit,
    required this.onExport,
    required this.onAttach,
    required this.onSettle,
    required this.onBackfilled,
  });

  final List<_Counterparty> list;
  final _Counterparty? selected;
  final List<_CounterpartyTx> tx;
  final bool txLoading;
  final ValueChanged<_Counterparty> onSelect;
  final VoidCallback? onRecord;
  final VoidCallback? onPartnerTransfer;
  final ValueChanged<_Counterparty>? onToggleArchive;
  final ValueChanged<_Counterparty>? onEdit;
  final ValueChanged<_Counterparty>? onExport;
  final ValueChanged<_Counterparty>? onAttach;
  final void Function(_Counterparty c, String currency, double saldoValue)?
      onSettle;
  final VoidCallback? onBackfilled;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ВАЖНО: width=null в Row даёт ListView intrinsic-size = бесконечность
        // (он схлопывается в 0 на desktop) — нужно Expanded когда нет
        // selected, и фиксированная 360px когда selected ≠ null.
        if (selected == null)
          Expanded(
            child: _ListPanel(
              list: list,
              selected: selected,
              onSelect: onSelect,
              onToggleArchive: onToggleArchive,
              compact: false,
            ),
          )
        else
          SizedBox(
            width: 360,
            child: _ListPanel(
              list: list,
              selected: selected,
              onSelect: onSelect,
              onToggleArchive: onToggleArchive,
              compact: true,
            ),
          ),
        if (selected != null) ...[
          const VerticalDivider(width: 1),
          Expanded(
            child: _DetailPanel(
              counterparty: selected!,
              tx: tx,
              txLoading: txLoading,
              onRecord: onRecord,
              onPartnerTransfer: onPartnerTransfer,
              onToggleArchive: onToggleArchive != null
                  ? () => onToggleArchive!(selected!)
                  : null,
              onEdit:
                  onEdit != null ? () => onEdit!(selected!) : null,
              onExport:
                  onExport != null ? () => onExport!(selected!) : null,
              onAttach:
                  onAttach != null ? () => onAttach!(selected!) : null,
              onSettle: onSettle == null
                  ? null
                  : (cur, value) => onSettle!(selected!, cur, value),
              onBackfilled: onBackfilled,
            ),
          ),
        ],
      ],
    );
  }
}

class _MobileBody extends StatelessWidget {
  const _MobileBody({
    required this.list,
    required this.onSelect,
    required this.onToggleArchive,
  });
  final List<_Counterparty> list;
  final ValueChanged<_Counterparty> onSelect;
  final ValueChanged<_Counterparty>? onToggleArchive;

  @override
  Widget build(BuildContext context) {
    return _ListPanel(
      list: list,
      selected: null,
      onSelect: onSelect,
      onToggleArchive: onToggleArchive,
      compact: true,
    );
  }
}

class _ListPanel extends StatelessWidget {
  const _ListPanel({
    required this.list,
    required this.selected,
    required this.onSelect,
    required this.onToggleArchive,
    required this.compact,
  });

  final List<_Counterparty> list;
  final _Counterparty? selected;
  final ValueChanged<_Counterparty> onSelect;
  final ValueChanged<_Counterparty>? onToggleArchive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final c = list[i];
        final isSel = selected?.id == c.id;
        return _CounterpartyTile(
          counterparty: c,
          isSelected: isSel,
          onTap: () => onSelect(c),
          onToggleArchive:
              onToggleArchive == null ? null : () => onToggleArchive!(c),
        );
      },
    );
  }
}

/// Карточка партнёра в списке. Главное визуальное улучшение vs
/// старой версии: saldo с цветовой кодировкой (зелёный = он должен,
/// красный = мы должны), бейдж «Архив», контекстное меню с
/// архивацией.
class _CounterpartyTile extends StatelessWidget {
  const _CounterpartyTile({
    required this.counterparty,
    required this.isSelected,
    required this.onTap,
    required this.onToggleArchive,
  });

  final _Counterparty counterparty;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onToggleArchive;

  @override
  Widget build(BuildContext context) {
    final c = counterparty;
    final scheme = Theme.of(context).colorScheme;
    final saldoEntries =
        c.saldo.entries.where((e) => e.value.abs() > 0.0049).toList()
          ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final mainSaldo = saldoEntries.isEmpty ? null : saldoEntries.first;
    return ListTile(
      selected: isSelected,
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: c.isActive
            ? AppColors.primary.withValues(alpha: 0.15)
            : Colors.grey.withValues(alpha: 0.18),
        child: Text(
          c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
          style: TextStyle(
            color: c.isActive ? AppColors.primary : Colors.grey,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: c.isActive ? null : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (c.feePercentage != null && c.feePercentage! > 0)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${c.feePercentage!.toStringAsFixed(c.feePercentage! == c.feePercentage!.roundToDouble() ? 0 : 2)}%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: scheme.primary,
                ),
              ),
            ),
          if (!c.isActive)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'АРХИВ',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.city != null && c.city!.isNotEmpty)
              Text(
                c.city!,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (mainSaldo != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  _SaldoMini(
                      currency: mainSaldo.key, value: mainSaldo.value),
                  if (saldoEntries.length > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '+${saldoEntries.length - 1}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ] else
              Text(
                'сальдо закрыто',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
      trailing: onToggleArchive == null
          ? const Icon(AppIcons.chevron_right, size: 16)
          : PopupMenuButton<String>(
              tooltip: 'Действия',
              icon: const Icon(AppIcons.more_horiz, size: 18),
              position: PopupMenuPosition.under,
              onSelected: (v) {
                if (v == 'archive') onToggleArchive!();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'archive',
                  child: Row(
                    children: [
                      Icon(
                        c.isActive ? AppIcons.archive : AppIcons.unarchive,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(c.isActive ? 'Архивировать' : 'Восстановить'),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _SaldoMini extends StatelessWidget {
  const _SaldoMini({required this.currency, required this.value});
  final String currency;
  final double value;

  @override
  Widget build(BuildContext context) {
    final positive = value > 0;
    final color = positive ? Colors.green.shade600 : Colors.red.shade600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${positive ? '+' : ''}${value.formatCurrency()} $currency',
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({
    required this.counterparty,
    required this.tx,
    required this.txLoading,
    required this.onRecord,
    required this.onPartnerTransfer,
    required this.onToggleArchive,
    required this.onEdit,
    required this.onExport,
    required this.onAttach,
    this.onSettle,
    this.onBackfilled,
  });

  final _Counterparty counterparty;
  final List<_CounterpartyTx> tx;
  final bool txLoading;
  final VoidCallback? onRecord;
  final VoidCallback? onPartnerTransfer;
  final VoidCallback? onToggleArchive;
  final VoidCallback? onEdit;
  final VoidCallback? onExport;
  final VoidCallback? onAttach;
  /// Быстрый расчёт с партнёром по конкретной валюте сальдо.
  /// Открывает RecordOpDialog с предзаполненной категорией settle и
  /// направлением (зависит от знака saldo).
  final void Function(String currency, double saldoValue)? onSettle;
  /// Вызывается после успешного backfill-а курсов в любом из TX-tile.
  /// Родитель перезагружает tx + список партнёров.
  final VoidCallback? onBackfilled;

  @override
  Widget build(BuildContext context) {
    final c = counterparty;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.name,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        if (!c.isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.grey.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'В АРХИВЕ',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (c.city != null || c.phone != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [c.city, c.phone].whereType<String>().join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (c.feePercentage != null && c.feePercentage! > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            'Комиссия партнёра: ${c.feePercentage!.toStringAsFixed(c.feePercentage! == c.feePercentage!.roundToDouble() ? 0 : 2)}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onPartnerTransfer != null && c.isActive)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: FilledButton.icon(
                    onPressed: onPartnerTransfer,
                    icon: const Icon(AppIcons.send, size: 18),
                    label: const Text('Перевод через партнёра'),
                  ),
                ),
              if (onRecord != null && c.isActive)
                OutlinedButton.icon(
                  onPressed: onRecord,
                  icon: const Icon(AppIcons.add, size: 18),
                  label: const Text('Записать операцию'),
                ),
              if (onEdit != null ||
                  onExport != null ||
                  onToggleArchive != null ||
                  onAttach != null)
                PopupMenuButton<String>(
                  tooltip: 'Ещё',
                  icon: const Icon(AppIcons.more_horiz),
                  position: PopupMenuPosition.under,
                  onSelected: (v) {
                    if (v == 'edit') onEdit?.call();
                    if (v == 'archive') onToggleArchive?.call();
                    if (v == 'export') onExport?.call();
                    if (v == 'attach') onAttach?.call();
                  },
                  itemBuilder: (_) => [
                    if (onAttach != null && c.isActive)
                      const PopupMenuItem(
                        value: 'attach',
                        child: Row(
                          children: [
                            Icon(AppIcons.account_tree, size: 16),
                            SizedBox(width: 8),
                            Text('Прикрепить существующий перевод'),
                          ],
                        ),
                      ),
                    if (onEdit != null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(AppIcons.tune, size: 16),
                            SizedBox(width: 8),
                            Text('Изменить данные партнёра'),
                          ],
                        ),
                      ),
                    if (onExport != null)
                      const PopupMenuItem(
                        value: 'export',
                        child: Row(
                          children: [
                            Icon(AppIcons.file_download, size: 16),
                            SizedBox(width: 8),
                            Text('Экспорт операций (CSV)'),
                          ],
                        ),
                      ),
                    if (onToggleArchive != null)
                      PopupMenuItem(
                        value: 'archive',
                        child: Row(
                          children: [
                            Icon(
                              c.isActive
                                  ? AppIcons.archive
                                  : AppIcons.unarchive,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(c.isActive
                                ? 'Архивировать'
                                : 'Восстановить из архива'),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _SaldoCard(
            saldo: c.saldo,
            limits: c.exposureLimit,
            onSettle: onSettle,
          ),
          const SizedBox(height: AppSpacing.md),
          _PartnerProfitPanel(counterpartyId: c.id),
          const SizedBox(height: AppSpacing.md),
          if (c.notes != null && c.notes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text('Заметка: ${c.notes!}',
                  style: const TextStyle(fontSize: 12)),
            ),
          Text(
            'История операций',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: txLoading
                ? const Center(child: CircularProgressIndicator())
                : tx.isEmpty
                    ? const Center(
                        child: Text(
                          'Операций пока нет',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        itemCount: tx.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, i) => _TxTile(
                          tx: tx[i],
                          onBackfilled: onBackfilled ?? () {},
                          onDeleted: onBackfilled ?? () {},
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Период для аналитики прибыли с партнёром.
enum _ProfitPeriod {
  week('Неделя'),
  month('Месяц'),
  quarter('Квартал'),
  year('Год'),
  all('Всё время');

  const _ProfitPeriod(this.label);
  final String label;

  DateTime? get startDate {
    final now = DateTime.now();
    switch (this) {
      case _ProfitPeriod.week:
        return now.subtract(const Duration(days: 7));
      case _ProfitPeriod.month:
        return DateTime(now.year, now.month - 1, now.day);
      case _ProfitPeriod.quarter:
        return DateTime(now.year, now.month - 3, now.day);
      case _ProfitPeriod.year:
        return DateTime(now.year - 1, now.month, now.day);
      case _ProfitPeriod.all:
        return null;
    }
  }
}

class _ProfitRow {
  _ProfitRow({
    required this.currency,
    required this.transferCount,
    required this.totalVolume,
    required this.spreadProfit,
    required this.commissionProfit,
    required this.settlementProfit,
    this.partnerFeePct = 0,
    this.partnerFeeCost = 0,
    double? netProfit,
  }) : netProfit = netProfit ?? (spreadProfit + commissionProfit - partnerFeeCost);
  factory _ProfitRow.fromMap(Map<String, dynamic> m) => _ProfitRow(
        currency: (m['currency'] ?? '').toString(),
        transferCount: (m['transfer_count'] as num?)?.toInt() ?? 0,
        totalVolume: (m['total_volume'] as num?)?.toDouble() ?? 0,
        spreadProfit: (m['spread_profit'] as num?)?.toDouble() ?? 0,
        commissionProfit:
            (m['commission_profit'] as num?)?.toDouble() ?? 0,
        // F3: профит расчётов (FX) приходит отдельной колонкой и НЕ
        // суммируется с прибылью на переводах, чтобы не было двойного счёта.
        settlementProfit:
            (m['settlement_profit'] as num?)?.toDouble() ?? 0,
        // F9: комиссия партнёра как расход (миграция 060). На старых
        // БД колонок нет → 0 (поведение как раньше — валовая прибыль).
        partnerFeePct: (m['partner_fee_pct'] as num?)?.toDouble() ?? 0,
        partnerFeeCost: (m['partner_fee_cost'] as num?)?.toDouble() ?? 0,
        netProfit: (m['net_profit'] as num?)?.toDouble(),
      );
  final String currency;
  final int transferCount;
  final double totalVolume;
  final double spreadProfit;
  final double commissionProfit;
  final double settlementProfit;

  /// F9: ставка партнёра (%) и её денежный эквивалент-расход за период.
  final double partnerFeePct;
  final double partnerFeeCost;

  /// Чистая прибыль на переводах = спред + комиссия − комиссия партнёра.
  final double netProfit;

  /// Валовая прибыль НА ПЕРЕВОДАХ: курсовой спред + комиссия. Профит
  /// расчётов (settlementProfit) сюда НЕ входит — это отдельный
  /// экономический результат на этапе взаиморасчёта с партнёром.
  double get totalProfit => spreadProfit + commissionProfit;
}

/// Карточка «Аналитика прибыли» в детализации партнёра. Тянет данные
/// через RPC `partner_profit_summary` (миграция 036) с фильтром периода.
class _PartnerProfitPanel extends StatefulWidget {
  const _PartnerProfitPanel({required this.counterpartyId});
  final String counterpartyId;

  @override
  State<_PartnerProfitPanel> createState() => _PartnerProfitPanelState();
}

class _PartnerProfitPanelState extends State<_PartnerProfitPanel> {
  _ProfitPeriod _period = _ProfitPeriod.month;
  List<_ProfitRow> _rows = const [];
  bool _loading = true;
  bool _migrationMissing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PartnerProfitPanel old) {
    super.didUpdateWidget(old);
    if (old.counterpartyId != widget.counterpartyId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _migrationMissing = false;
    });
    try {
      final start = _period.startDate?.toUtc().toIso8601String();
      final params = <String, dynamic>{
        'p_counterparty_id': widget.counterpartyId,
      };
      if (start != null) params['p_start'] = start;
      final rows = await Supabase.instance.client
          .rpc('partner_profit_summary', params: params)
          .timeout(const Duration(seconds: 15));
      final list = (rows as List)
          .map((m) =>
              _ProfitRow.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _migrationMissing = s.contains('PGRST') ||
            s.contains('42883') ||
            s.contains('does not exist');
        if (!_migrationMissing) _rows = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.06),
            scheme.primary.withValues(alpha: 0.02),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_up, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Прибыль с партнёра',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              PopupMenuButton<_ProfitPeriod>(
                tooltip: 'Период',
                initialValue: _period,
                onSelected: (p) {
                  setState(() => _period = p);
                  _load();
                },
                position: PopupMenuPosition.under,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.outline.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.history,
                          size: 14, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(_period.label,
                          style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 4),
                      Icon(AppIcons.expand_more,
                          size: 14, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
                itemBuilder: (_) => _ProfitPeriod.values
                    .map((p) => PopupMenuItem(
                          value: p,
                          child: Text(p.label),
                        ))
                    .toList(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else if (_migrationMissing)
            _MigrationMissingHint()
          else if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'За «${_period.label}» переводов нет.',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else ...[
            _ProfitTable(rows: _rows),
            _PartnerFeeNote(rows: _rows),
            _SettlementProfitNote(rows: _rows),
          ],
        ],
      ),
    );
  }
}

/// F3: профит на расчётах (cross-currency settle) показываем ОТДЕЛЬНО
/// от прибыли на переводах — он не должен складываться в transfer-«Итого»,
/// иначе курсовой результат считается дважды.
class _SettlementProfitNote extends StatelessWidget {
  const _SettlementProfitNote({required this.rows});
  final List<_ProfitRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settle = rows.where((r) => r.settlementProfit.abs() > 0.005).toList();
    if (settle.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: scheme.outline.withValues(alpha: 0.15)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(AppIcons.history, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Прибыль на расчётах (FX) — отдельно',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final r in settle)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(CurrencyUtils.flag(r.currency),
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text(r.currency,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    (r.settlementProfit > 0 ? '+' : '') +
                        r.settlementProfit.formatCurrency(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: r.settlementProfit > 0
                          ? Colors.green.shade700
                          : AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// F9: расход на комиссию партнёра + чистая прибыль по каждой валюте.
/// Показываем отдельным блоком (как settlement-note), чтобы валовая
/// таблица оставалась прозрачной, а удержание партнёра было явным.
class _PartnerFeeNote extends StatelessWidget {
  const _PartnerFeeNote({required this.rows});
  final List<_ProfitRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final feeRows =
        rows.where((r) => r.partnerFeeCost.abs() > 0.005).toList();
    if (feeRows.isEmpty) return const SizedBox.shrink();
    final pct = feeRows.first.partnerFeePct;
    final pctLabel =
        pct == pct.roundToDouble() ? pct.toStringAsFixed(0) : pct.toString();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: scheme.outline.withValues(alpha: 0.15)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(AppIcons.percent, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Комиссия партнёра $pctLabel% — расход на маржу',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final r in feeRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(CurrencyUtils.flag(r.currency),
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text(r.currency,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    '−${r.partnerFeeCost.formatCurrency()}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('чистыми',
                      style: TextStyle(
                          fontSize: 9.5, color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 4),
                  Text(
                    (r.netProfit >= 0 ? '+' : '') + r.netProfit.formatCurrency(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: r.netProfit >= 0
                          ? Colors.green.shade700
                          : AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MigrationMissingHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(AppIcons.warning_amber,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Применить миграцию 036 чтобы видеть прибыль с курса и комиссии.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfitTable extends StatelessWidget {
  const _ProfitTable({required this.rows});
  final List<_ProfitRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Header.
    Widget header(String label, {TextAlign align = TextAlign.start}) => Text(
          label.toUpperCase(),
          textAlign: align,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: scheme.onSurfaceVariant,
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 52, child: header('Валюта')),
              Expanded(flex: 2, child: header('Объём', align: TextAlign.end)),
              Expanded(flex: 2, child: header('Курс +', align: TextAlign.end)),
              Expanded(flex: 2, child: header('Комис', align: TextAlign.end)),
              Expanded(flex: 2, child: header('Итого', align: TextAlign.end)),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outline.withValues(alpha: 0.15)),
        for (final r in rows)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(CurrencyUtils.flag(r.currency),
                          style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 4),
                      Text(
                        r.currency,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _MoneyCell(
                    value: r.totalVolume,
                    sub: '${r.transferCount} оп.',
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _MoneyCell(
                    value: r.spreadProfit,
                    accent: r.spreadProfit > 0
                        ? Colors.green.shade600
                        : null,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _MoneyCell(
                    value: r.commissionProfit,
                    accent: r.commissionProfit > 0
                        ? Colors.green.shade600
                        : null,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _MoneyCell(
                    value: r.totalProfit,
                    accent: r.totalProfit > 0
                        ? Colors.green.shade700
                        : null,
                    bold: true,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MoneyCell extends StatelessWidget {
  const _MoneyCell({
    required this.value,
    this.accent,
    this.bold = false,
    this.sub,
  });
  final double value;
  final Color? accent;
  final bool bold;
  final String? sub;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value.formatCurrencyNoDecimals(),
          textAlign: TextAlign.end,
          style: TextStyle(
            fontSize: bold ? 13 : 12,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
            color: accent ?? scheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (sub != null)
          Text(
            sub!,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 9.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _SaldoCard extends StatelessWidget {
  const _SaldoCard({
    required this.saldo,
    this.limits = const {},
    this.onSettle,
  });
  final Map<String, double> saldo;

  /// F5: per-currency лимит экспозиции — для индикатора «занято / потолок».
  final Map<String, double> limits;

  /// Открыть RecordOpDialog в режиме settle с предзаполнением валюты
  /// и направления (мы должны → settle_from_us, он должен → settle_to_us).
  final void Function(String currency, double saldoValue)? onSettle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nonZero = saldo.entries.where((e) => e.value.abs() > 0.0049).toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Текущее сальдо',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (nonZero.isNotEmpty && onSettle != null)
                TextButton.icon(
                  onPressed: () => onSettle!(nonZero.first.key, nonZero.first.value),
                  icon: const Icon(Icons.handshake_outlined, size: 16),
                  label: const Text('Рассчитаться',
                      style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 0),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (nonZero.isEmpty)
            Text(
              'Расчёты закрыты',
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: nonZero
                  .map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: _SaldoRow(
                          currency: e.key,
                          value: e.value,
                          limit: limits[e.key.toUpperCase()],
                          onSettle: onSettle == null
                              ? null
                              : () => onSettle!(e.key, e.value),
                        ),
                      ))
                  .toList(),
            ),
          const SizedBox(height: 8),
          Text(
            '+ он должен нам · − мы должны ему · «Рассчитаться» открывает settle',
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка сальдо: валюта + сумма с цветом + поясняющий текст. Кнопка
/// settle на этой конкретной валюте.
class _SaldoRow extends StatelessWidget {
  const _SaldoRow({
    required this.currency,
    required this.value,
    required this.onSettle,
    this.limit,
  });
  final String currency;
  final double value;
  final VoidCallback? onSettle;

  /// F5: потолок |saldo| по этой валюте (null/<=0 = лимита нет).
  final double? limit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final positive = value > 0;
    final color = positive ? Colors.green.shade600 : Colors.red.shade600;
    final lim = limit;
    final hasLimit = lim != null && lim > 0;
    final ratio =
        hasLimit ? (value.abs() / lim).clamp(0.0, 1.0).toDouble() : 0.0;
    // Цвет полосы: зелёный <70%, янтарь 70-90%, красный >90%.
    final barColor = ratio >= 0.9
        ? Colors.red.shade600
        : (ratio >= 0.7 ? Colors.amber.shade700 : Colors.green.shade600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(currency,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  )),
            ),
            const SizedBox(width: 8),
            Text(
              '${positive ? '+' : ''}${value.formatCurrency()}',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                positive ? 'он должен нам' : 'мы должны ему',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onSettle != null)
              IconButton(
                tooltip: positive ? 'Принять от него' : 'Отдать ему',
                onPressed: onSettle,
                icon: Icon(
                  positive
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  size: 16,
                  color: color,
                ),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
          ],
        ),
        if (hasLimit) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 52, right: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 4,
                    backgroundColor:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                    valueColor: AlwaysStoppedAnimation(barColor),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Лимит: ${value.abs().formatCurrency()} / '
                  '${lim.formatCurrency()} $currency '
                  '(${(ratio * 100).toStringAsFixed(0)}%)',
                  style: TextStyle(
                    fontSize: 10,
                    color: ratio >= 0.9
                        ? Colors.red.shade700
                        : scheme.onSurfaceVariant,
                    fontWeight:
                        ratio >= 0.9 ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// _SaldoChip удалён — заменён на _SaldoRow в _SaldoCard.

class _TxTile extends StatelessWidget {
  const _TxTile({
    required this.tx,
    required this.onBackfilled,
    required this.onDeleted,
  });
  final _CounterpartyTx tx;
  /// Callback вызывается после успешного backfill — родитель
  /// перезагружает список tx и `_load()` партнёра (saldo/profit).
  final VoidCallback onBackfilled;
  /// Callback после удаления перевода через delete_transfer RPC.
  /// Родитель перезагружает tx + список (saldo откатился).
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = _kindLabel(tx.kind);
    final sign = _signFor(tx.kind);
    final hasMissing = tx.isMissingRates;
    final hasSpread =
        tx.hasSpreadInfo && (tx.spreadProfit ?? 0) > 0.005;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Icon(_iconFor(tx.kind),
              color: AppColors.primary, size: 20),
          title: Row(
            children: [
              Expanded(child: Text(kind)),
              if (tx.transactionCode != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    tx.transactionCode!,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${DateFormat('d MMM yyyy, HH:mm', 'ru').format(tx.createdAt)}'
                '${tx.description != null ? ' · ${tx.description}' : ''}',
                style: const TextStyle(fontSize: 11),
              ),
              // Получатель — для paid_for_us операций (привязка к transfer)
              if ((tx.receiverName ?? '').isNotEmpty ||
                  (tx.receiverPhone ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Icon(AppIcons.person_outline,
                          size: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          [
                            if ((tx.receiverName ?? '').isNotEmpty)
                              tx.receiverName!,
                            if ((tx.receiverPhone ?? '').isNotEmpty)
                              tx.receiverPhone!,
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$sign${tx.amount.formatCurrency()} ${tx.currency}',
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: sign == '+'
                      ? Colors.green.shade600
                      : Colors.red.shade600,
                ),
              ),
              // Меню действий доступно если есть transfer_id (т.е.
              // эта операция — paid_for_us, привязанный к конкретному
              // партнёрскому переводу). Settle-операции (settle_to_us /
              // settle_from_us) не имеют transfer_id — для них нет
              // отдельного «Удалить»; их откат — это просто новая
              // обратная settle-операция.
              if (tx.transferId != null)
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  icon: const Icon(AppIcons.more_horiz, size: 16),
                  position: PopupMenuPosition.under,
                  onSelected: (v) async {
                    if (v == 'delete') {
                      final ok = await _confirmAndDelete(
                          context, tx.transferId!, tx.transactionCode);
                      if (ok) onDeleted();
                    } else if (v == 'backfill' && tx.isMissingRates) {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => _BackfillRatesDialog(
                          transferId: tx.transferId!,
                          transactionCode: tx.transactionCode,
                          amount: tx.amount,
                          currency: tx.currency,
                        ),
                      );
                      if (ok == true) onBackfilled();
                    }
                  },
                  itemBuilder: (_) => [
                    if (tx.isMissingRates)
                      const PopupMenuItem(
                        value: 'backfill',
                        child: Row(
                          children: [
                            Icon(AppIcons.tune, size: 14),
                            SizedBox(width: 8),
                            Text('Указать курсы'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(AppIcons.delete_forever,
                              size: 14, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Удалить перевод',
                              style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        // ── Плашка spread (если уже backfill-ed) ───────────
        if (hasSpread)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 6),
            child: Row(
              children: [
                Icon(Icons.trending_up,
                    size: 12, color: Colors.green.shade700),
                const SizedBox(width: 4),
                Text(
                  'Прибыль с курса: +${tx.spreadProfit!.formatCurrency()} ${tx.currency}',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'buy ${tx.buyRate!.formatCurrency()} → sell ${tx.sellRate!.formatCurrency()}',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
              ],
            ),
          ),
        // ── Плашка settlement profit (cross-currency settle) ─
        if (tx.hasSettlementProfit) ...[
          () {
            final p = tx.settlementProfit!;
            final cur = tx.settlementProfitCurrency ?? tx.currency;
            final positive = p > 0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 16, 6),
              child: Row(
                children: [
                  Icon(
                    positive ? Icons.trending_up : Icons.trending_down,
                    size: 12,
                    color: positive
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    positive
                        ? 'Прибыль на расчёте: +${p.formatCurrency()} $cur'
                        : 'Убыток на расчёте: ${p.formatCurrency()} $cur',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: positive
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                  ),
                  if (tx.isCrossCurrencySettle) ...[
                    const SizedBox(width: 8),
                    Text(
                      'закрыл ${tx.closesAmount!.formatCurrency()} ${tx.closesCurrency} '
                      '@ ${(tx.amount / tx.closesAmount!).toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ],
                ],
              ),
            );
          }(),
        ],
        // ── Плашка «без курсов» + кнопка ─────────────────
        if (hasMissing)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 8, 6),
            child: Row(
              children: [
                Icon(AppIcons.warning_amber,
                    size: 12, color: AppColors.warning),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Курсы дилера не указаны — spread не учитывается',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.warning,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => _BackfillRatesDialog(
                        transferId: tx.transferId!,
                        transactionCode: tx.transactionCode,
                        amount: tx.amount,
                        currency: tx.currency,
                      ),
                    );
                    if (ok == true) onBackfilled();
                  },
                  icon: const Icon(AppIcons.tune, size: 14),
                  label: const Text('Указать курсы',
                      style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 0),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Подтверждение и вызов delete_transfer RPC. Возвращает true если
/// перевод реально удалён (saldo откачено, ledger очищен).
Future<bool> _confirmAndDelete(
  BuildContext context,
  String transferId,
  String? transactionCode,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final reasonCtrl = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(AppIcons.warning_amber, color: AppColors.error, size: 22),
          const SizedBox(width: 8),
          const Expanded(child: Text('Удалить партнёрский перевод?')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            transactionCode == null
                ? 'Перевод будет полностью удалён.'
                : 'Перевод $transactionCode будет полностью удалён.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Что произойдёт:\n'
            '• Деньги вернутся на счёт-источник\n'
            '• Комиссия (если была списана на отдельный счёт) откатится\n'
            '• Saldo партнёра откатится назад\n'
            '• Запись из истории операций исчезнет\n'
            '• Снимок останется в deleted_transfers для аудита',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(
              labelText: 'Причина (опционально)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.pop(ctx, true),
          icon: const Icon(AppIcons.delete_forever, size: 18),
          label: const Text('Удалить'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    final params = <String, dynamic>{'p_transfer_id': transferId};
    if (reasonCtrl.text.trim().isNotEmpty) {
      params['p_reason'] = reasonCtrl.text.trim();
    }
    await Supabase.instance.client.rpc('delete_transfer', params: params);
    messenger.showSnackBar(SnackBar(
      content: Text(transactionCode == null
          ? 'Перевод удалён'
          : 'Перевод $transactionCode удалён'),
      backgroundColor: Colors.green.shade700,
    ));
    return true;
  } catch (e) {
    final s = e.toString();
    final msg = s.contains('PGRST') || s.contains('42883')
        ? 'RPC delete_transfer не найден. Примените миграцию 039.'
        : s.contains('Бухгалтер может')
            ? 'Бухгалтер не может удалить этот перевод. Только Director/Creator.'
            : s.contains('требует ручного rollback')
                ? 'Confirmed/withCourier/delivered (обычные) уже задействуют счёт получателя.'
                : 'Не удалось удалить: $s';
    messenger.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
      duration: const Duration(seconds: 6),
    ));
    return false;
  }
}

/// Диалог проставления buy_rate/sell_rate/base_currency для уже
/// созданного перевода. Только creator/director (RPC проверит).
///
/// Saldo и журнал НЕ затрагиваются — мы дописываем cached spread
/// для аналитики. Если хочется поменять реальные деньги — это
/// отдельный процесс через `replace_pending_transfer`, который
/// работает только на pending-переводах.
class _BackfillRatesDialog extends StatefulWidget {
  const _BackfillRatesDialog({
    required this.transferId,
    required this.transactionCode,
    required this.amount,
    required this.currency,
  });
  final String transferId;
  final String? transactionCode;
  final double amount;
  final String currency;

  @override
  State<_BackfillRatesDialog> createState() => _BackfillRatesDialogState();
}

class _BackfillRatesDialogState extends State<_BackfillRatesDialog> {
  final _buy = TextEditingController();
  final _sell = TextEditingController();
  final _note = TextEditingController();
  String _baseCurrency = 'USD';
  bool _saving = false;
  String? _error;

  static const _bases = ['USD', 'EUR', 'RUB', 'UZS', 'KZT'];

  @override
  void dispose() {
    _buy.dispose();
    _sell.dispose();
    _note.dispose();
    super.dispose();
  }

  double get _buyRate =>
      double.tryParse(_buy.text.replaceAll(',', '.')) ?? 0;
  double get _sellRate =>
      double.tryParse(_sell.text.replaceAll(',', '.')) ?? 0;

  /// spread в валюте перевода. Тот же расчёт что в БД-функции
  /// `private.calc_spread_profit` — клиент-side preview.
  double get _spread {
    if (_baseCurrency == widget.currency) return 0;
    if (_buyRate <= 0 || _sellRate <= 0) return 0;
    return widget.amount - (widget.amount / _buyRate) * _sellRate;
  }

  Future<void> _submit() async {
    if (_buyRate <= 0) {
      setState(() => _error = 'buy rate должен быть > 0');
      return;
    }
    if (_sellRate <= 0) {
      setState(() => _error = 'sell rate должен быть > 0');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('backfill_transfer_rates', params: {
        'p_transfer_id': widget.transferId,
        'p_buy_rate': _buyRate,
        'p_sell_rate': _sellRate,
        'p_base_currency': _baseCurrency,
        if (_note.text.trim().isNotEmpty) 'p_note': _note.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _saving = false;
        _error = s.contains('PGRST') || s.contains('42883')
            ? 'RPC backfill_transfer_rates не найден. Примените миграцию 038.'
            : s.contains('Только Creator')
                ? 'Курсы может проставлять только Creator/Director.'
                : s;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(AppIcons.tune, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              widget.transactionCode == null
                  ? 'Проставить курсы'
                  : 'Курсы по ${widget.transactionCode}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius:
                      BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Text(
                  'Сумма перевода: ${widget.amount.formatCurrency()} ${widget.currency}\n'
                  'Backfill дописывает курсы для аналитики. '
                  'Saldo и журнал не изменятся.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue:
                    _bases.contains(_baseCurrency) ? _baseCurrency : 'USD',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Базовая валюта учёта',
                  helperText: 'В чём мы вели мысленный учёт долга партнёра',
                  border: OutlineInputBorder(),
                ),
                items: _bases
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(CurrencyUtils.flag(c)),
                              const SizedBox(width: 6),
                              Text(c),
                            ],
                          ),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _baseCurrency = v);
                },
              ),
              if (_baseCurrency == widget.currency)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Базовая валюта = валюта перевода → spread всегда 0.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.warning,
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _buy,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        DecimalInputFormatter(),
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Наш курс приёма (buy)',
                        helperText:
                            '1 $_baseCurrency = X ${widget.currency}',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(
                            AppIcons.arrow_downward,
                            size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _sell,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        DecimalInputFormatter(),
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Курс расчёта (sell)',
                        helperText:
                            '1 $_baseCurrency = Y ${widget.currency}',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(
                            AppIcons.arrow_upward,
                            size: 18),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Заметка (опционально)',
                  helperText: 'Запишется в amendment_history',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Preview spread.
              if (_buyRate > 0 && _sellRate > 0)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: _spread > 0
                        ? Colors.green.withValues(alpha: 0.1)
                        : (_spread < 0
                            ? Colors.red.withValues(alpha: 0.08)
                            : scheme.surfaceContainerHighest
                                .withValues(alpha: 0.5)),
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _spread > 0
                            ? Icons.trending_up
                            : (_spread < 0
                                ? Icons.trending_down
                                : Icons.trending_flat),
                        size: 18,
                        color: _spread > 0
                            ? Colors.green.shade700
                            : (_spread < 0
                                ? Colors.red.shade700
                                : scheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _spread > 0
                              ? 'Прибыль с курса: +${_spread.formatCurrency()} ${widget.currency}'
                              : _spread < 0
                                  ? 'Убыток с курса: ${_spread.formatCurrency()} ${widget.currency}'
                                  : 'Spread = 0 (одинаковая валюта или одинаковые курсы)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _spread > 0
                                ? Colors.green.shade800
                                : (_spread < 0
                                    ? Colors.red.shade800
                                    : null),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Text(_error!,
                      style: TextStyle(
                          color: AppColors.error, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.check, size: 18),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Карточка ошибки загрузки списка. Главный случай — отсутствующая
/// миграция, поэтому показываем не «голый» exception, а понятный текст
/// с инструкцией и кнопкой «Повторить».
class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.warning_amber,
                    color: AppColors.error, size: 32),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Раздел недоступен',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(AppIcons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.canManage, required this.onCreate});
  final bool canManage;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.people_outline, size: 64, color: Colors.grey),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Партнёров пока нет',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          const SizedBox(
            width: 320,
            child: Text(
              'Партнёр — внешний посредник в другом городе. Через него '
              'вы выплачиваете клиентов или он выплачивает за вас. '
              'Программа ведёт сальдо по валютам.',
              textAlign: TextAlign.center,
            ),
          ),
          if (canManage) ...[
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(AppIcons.add),
              label: const Text('Добавить партнёра'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Популярные города из СНГ-региона. Используются как подсказки в
/// автокомплите при создании партнёра — сверху встают «местные», ниже
/// идут уже введённые ранее, потом всё что введёт пользователь руками.
const _kPopularCities = <String>[
  'Москва', 'Санкт-Петербург', 'Екатеринбург', 'Новосибирск', 'Казань',
  'Краснодар', 'Сочи', 'Владивосток',
  'Ташкент', 'Самарканд', 'Бухара', 'Андижан', 'Фергана', 'Наманган',
  'Бишкек', 'Ош',
  'Алматы', 'Астана', 'Шымкент',
  'Душанбе', 'Худжанд',
  'Ереван', 'Тбилиси', 'Баку',
  'Дубай', 'Стамбул', 'Анкара',
  'Минск', 'Киев',
];

class _CreateCounterpartyDialog extends StatefulWidget {
  const _CreateCounterpartyDialog();

  @override
  State<_CreateCounterpartyDialog> createState() =>
      _CreateCounterpartyDialogState();
}

class _CreateCounterpartyDialogState extends State<_CreateCounterpartyDialog> {
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  final _feePercent = TextEditingController();
  // null = «глобальный партнёр без привязки». Чекбокс ниже управляет
  // тем, нужна ли вообще привязка к филиалу.
  String? _homeBranchId;
  bool _attachToBranch = false;
  bool _saving = false;
  String? _error;

  List<_BranchOption> _branches = const [];
  bool _loadingBranches = true;
  bool _canPickBranch = false;

  /// Уже использованные города — для автокомплита. Сверху популярные,
  /// потом загруженные из БД (`counterparty_cities` RPC).
  List<String> _historyCities = const [];

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthBloc>().state.user;
    _canPickBranch = userSeesAllBranches(user);
    if (_canPickBranch) {
      _loadBranches();
    } else {
      _loadingBranches = false;
    }
    _loadCities();
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _phone.dispose();
    _notes.dispose();
    _feePercent.dispose();
    super.dispose();
  }

  Future<void> _loadBranches() async {
    try {
      final rows = await Supabase.instance.client
          .from('branches')
          .select('id, name')
          .eq('is_active', true)
          .order('name');
      final list = (rows as List)
          .map((m) =>
              _BranchOption.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
      _deferSetState(() {
        _branches = list;
        _loadingBranches = false;
      });
    } catch (_) {
      _deferSetState(() => _loadingBranches = false);
    }
  }

  /// Тянет уже использованные города из БД. Если RPC ещё не применён —
  /// тихо игнорируем (показываем только popularCities).
  Future<void> _loadCities() async {
    try {
      final rows = await Supabase.instance.client.rpc('counterparty_cities');
      final list = (rows as List)
          .map((m) => (m as Map)['city']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      _deferSetState(() => _historyCities = list);
    } catch (_) {
      // RPC не применён — не проблема, fallback на popular.
    }
  }

  /// Откладывает setState до завершения текущего frame'а. Иначе async
  /// результат, прилетевший во время mouse hit-test, ловит assertion
  /// `!_debugDuringDeviceUpdate` в Flutter MouseTracker (debug-only).
  void _deferSetState(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(fn);
    });
  }

  /// Объединённый список для подсказок: сначала «история» (по убыванию
  /// частоты), потом «популярные», без дублей.
  List<String> get _allCitySuggestions {
    final seen = <String>{};
    final out = <String>[];
    for (final c in [..._historyCities, ..._kPopularCities]) {
      final t = c.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Введите имя партнёра');
      return;
    }
    if (name.length < 2) {
      setState(() => _error = 'Имя должно быть длиннее 1 символа');
      return;
    }
    double? fee;
    final feeText = _feePercent.text.replaceAll(',', '.').trim();
    if (feeText.isNotEmpty) {
      fee = double.tryParse(feeText);
      if (fee == null || fee < 0) {
        setState(() => _error = 'Комиссия должна быть числом ≥ 0');
        return;
      }
      if (fee > 50) {
        setState(() => _error = 'Слишком большая комиссия: $fee%. '
            'Если это намеренно — сначала свяжитесь с директором.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final params = <String, dynamic>{'p_name': name};
    final city = _city.text.trim();
    final phone = _phone.text.replaceAll(' ', '').trim(); // E.164 без пробелов
    final notes = _notes.text.trim();
    if (city.isNotEmpty) params['p_city'] = city;
    if (phone.isNotEmpty) params['p_phone'] = phone;
    if (notes.isNotEmpty) params['p_notes'] = notes;
    if (_canPickBranch && _attachToBranch && _homeBranchId != null) {
      params['p_home_branch_id'] = _homeBranchId;
    }
    if (fee != null) params['p_fee_percentage'] = fee;
    try {
      await Supabase.instance.client
          .rpc('create_counterparty', params: params);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _humanizeCreateError(e);
      });
    }
  }

  String _humanizeCreateError(Object e) {
    final s = e.toString();
    if (s.contains('duplicate key') || s.contains('unique constraint')) {
      return 'Партнёр с таким именем уже существует.';
    }
    if (s.contains('PGRST') || s.contains('42883')) {
      return 'RPC create_counterparty не найдена. Примените миграции 029/033.';
    }
    return 'Ошибка создания: $s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(AppIcons.person_add, size: 22),
          const SizedBox(width: AppSpacing.sm),
          const Text('Новый партнёр'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Имя партнёра *',
                  hintText: 'Например: Тима из Москвы',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.person_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // ── Город с автокомплитом ─────────────────────────
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue value) {
                  final q = value.text.trim().toLowerCase();
                  final all = _allCitySuggestions;
                  if (q.isEmpty) return all.take(10);
                  return all
                      .where((c) => c.toLowerCase().contains(q))
                      .take(10);
                },
                onSelected: (v) {
                  _city.text = v;
                },
                fieldViewBuilder:
                    (ctx, textCtrl, focusNode, onFieldSubmitted) {
                  // Синхронизируем внешний _city с внутренним контроллером.
                  if (textCtrl.text != _city.text) {
                    textCtrl.text = _city.text;
                  }
                  return TextField(
                    controller: textCtrl,
                    focusNode: focusNode,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Город',
                      hintText: 'Москва, Ташкент, Бишкек…',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(AppIcons.business, size: 20),
                    ),
                    onChanged: (v) => _city.text = v,
                  );
                },
                optionsViewBuilder: (ctx, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxHeight: 260, maxWidth: 360),
                        child: ListView.separated(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color:
                                scheme.outline.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (_, i) {
                            final opt = options.elementAt(i);
                            return InkWell(
                              onTap: () => onSelected(opt),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    Icon(AppIcons.business,
                                        size: 14,
                                        color: scheme.onSurfaceVariant),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(opt,
                                          style: const TextStyle(
                                              fontSize: 13)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              // ── Телефон с автоформатом (E.164) ───────────────
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  PhoneInputFormatter(),
                  LengthLimitingTextInputFormatter(
                      kPhoneMaxFormattedLength),
                ],
                decoration: const InputDecoration(
                  labelText: 'Телефон',
                  hintText: '+7 920 988 38 76',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.phone, size: 20),
                  helperText: 'Сохраняем в международном формате (E.164)',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _notes,
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Заметки',
                  hintText: 'Что важно помнить про этого партнёра…',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.info_outline, size: 20),
                ),
              ),
              if (_canPickBranch) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Checkbox(
                      value: _attachToBranch,
                      onChanged: (v) => setState(() {
                        _attachToBranch = v ?? false;
                        if (!_attachToBranch) _homeBranchId = null;
                      }),
                    ),
                    const Expanded(
                      child: Text(
                        'Привязать к конкретному филиалу',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                if (_attachToBranch) ...[
                  if (_loadingBranches)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    DropdownButtonFormField<String>(
                      initialValue: _homeBranchId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Филиал-якорь',
                        border: OutlineInputBorder(),
                      ),
                      items: _branches
                          .map((b) => DropdownMenuItem<String>(
                                value: b.id,
                                child: Text(b.name,
                                    style:
                                        const TextStyle(fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _homeBranchId = v),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'Филиал, который ведёт расчёты с этим партнёром (обычно head-офис).',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _feePercent,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  DecimalInputFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Комиссия партнёра %',
                  hintText: 'Например: 1.5',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.percent, size: 20),
                  suffixText: '%',
                  helperText:
                      'Автоматически подставится как комиссия в форме перевода через партнёра',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.warning_amber,
                          size: 16, color: AppColors.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style:
                                TextStyle(color: AppColors.error, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.check, size: 18),
          label: const Text('Создать'),
        ),
      ],
    );
  }
}

/// Диалог редактирования партнёра. Структура — копия Create-диалога,
/// но с префиллом значений и `update_counterparty` RPC. Бухгалтер не
/// видит поля fee/branch (миграция 035 запрещает их менять); creator/
/// director видит всё.
class _EditCounterpartyDialog extends StatefulWidget {
  const _EditCounterpartyDialog({required this.counterparty});
  final _Counterparty counterparty;

  @override
  State<_EditCounterpartyDialog> createState() =>
      _EditCounterpartyDialogState();
}

class _EditCounterpartyDialogState extends State<_EditCounterpartyDialog> {
  late final TextEditingController _name;
  late final TextEditingController _city;
  late final TextEditingController _phone;
  late final TextEditingController _notes;
  late final TextEditingController _feePercent;
  String? _homeBranchId;
  bool _attachToBranch = false;
  bool _saving = false;
  String? _error;

  // F5: редактируемые строки лимита экспозиции (валюта + сумма).
  late final List<_ExposureRow> _limitRows;

  List<_BranchOption> _branches = const [];
  bool _loadingBranches = true;
  bool _canEditPrivileged = false;

  List<String> _historyCities = const [];

  @override
  void initState() {
    super.initState();
    final c = widget.counterparty;
    _name = TextEditingController(text: c.name);
    _city = TextEditingController(text: c.city ?? '');
    _phone = TextEditingController(text: c.phone ?? '');
    _notes = TextEditingController(text: c.notes ?? '');
    _feePercent = TextEditingController(
      text: c.feePercentage == null ? '' : _formatFee(c.feePercentage!),
    );
    _limitRows = c.exposureLimit.entries
        .map((e) => _ExposureRow(
              e.key,
              TextEditingController(text: _formatAmount(e.value)),
            ))
        .toList();
    final user = context.read<AuthBloc>().state.user;
    _canEditPrivileged = userSeesAllBranches(user);
    if (_canEditPrivileged) {
      _loadBranches();
    } else {
      _loadingBranches = false;
    }
    _loadCities();
  }

  String _formatFee(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// Сумма без хвостовых нулей: 5000000.0 → «5000000», 1500.5 → «1500.5».
  String _formatAmount(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    var s = v.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// Сравнивает две карты лимитов с допуском на округление.
  bool _sameLimits(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || (other - e.value).abs() > 1e-6) return false;
    }
    return true;
  }

  /// Добавляет строку лимита для первой ещё не использованной валюты.
  void _addLimitRow() {
    final used = _limitRows.map((r) => r.currency).toSet();
    final next = CurrencyUtils.supported.firstWhere(
      (c) => !used.contains(c),
      orElse: () => CurrencyUtils.supported.first,
    );
    setState(() {
      _limitRows.add(_ExposureRow(next, TextEditingController()));
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _phone.dispose();
    _notes.dispose();
    _feePercent.dispose();
    for (final row in _limitRows) {
      row.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBranches() async {
    try {
      final rows = await Supabase.instance.client
          .from('branches')
          .select('id, name')
          .eq('is_active', true)
          .order('name');
      final list = (rows as List)
          .map((m) =>
              _BranchOption.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
      _deferSetState(() {
        _branches = list;
        _loadingBranches = false;
        final h = widget.counterparty;
        _attachToBranch = h.id.isNotEmpty;
        // Префилл home_branch_id из загруженного партнёра. Берём через
        // прямой запрос: counterparties_list не отдаёт home_branch_id
        // напрямую в моделе (но мы сохранили его в строке).
      });
    } catch (_) {
      _deferSetState(() => _loadingBranches = false);
    }
  }

  Future<void> _loadCities() async {
    try {
      final rows = await Supabase.instance.client.rpc('counterparty_cities');
      final list = (rows as List)
          .map((m) => (m as Map)['city']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      _deferSetState(() => _historyCities = list);
    } catch (_) {}
  }

  void _deferSetState(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(fn);
    });
  }

  List<String> get _allCitySuggestions {
    final seen = <String>{};
    final out = <String>[];
    for (final c in [..._historyCities, ..._kPopularCities]) {
      final t = c.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  Future<void> _submit() async {
    final c = widget.counterparty;
    final name = _name.text.trim();
    if (name.isEmpty || name.length < 2) {
      setState(() => _error = 'Имя должно быть длиннее 1 символа');
      return;
    }
    double? fee;
    final feeText = _feePercent.text.replaceAll(',', '.').trim();
    final feeWasNonEmpty = feeText.isNotEmpty;
    if (feeWasNonEmpty) {
      fee = double.tryParse(feeText);
      if (fee == null || fee < 0) {
        setState(() => _error = 'Комиссия должна быть числом ≥ 0');
        return;
      }
      if (fee > 50) {
        setState(() => _error = 'Слишком большая комиссия: $fee%.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    // Собираем params только из реально изменившихся полей. Для пустых
    // строк шлём '' (RPC интерпретирует как «обнулить»). Для null —
    // не шлём (значит «не менять»).
    final params = <String, dynamic>{'p_counterparty_id': c.id};
    if (name != c.name) params['p_name'] = name;
    if (_city.text != (c.city ?? '')) params['p_city'] = _city.text.trim();
    final newPhone = _phone.text.replaceAll(' ', '').trim();
    final oldPhone = c.phone ?? '';
    if (newPhone != oldPhone) params['p_phone'] = newPhone;
    if (_notes.text != (c.notes ?? '')) params['p_notes'] = _notes.text.trim();
    if (_canEditPrivileged) {
      if (feeWasNonEmpty && fee != c.feePercentage) {
        params['p_fee_percentage'] = fee;
      } else if (!feeWasNonEmpty && c.feePercentage != null) {
        params['p_clear_fee'] = true;
      }
      if (_attachToBranch && _homeBranchId != null) {
        params['p_home_branch_id'] = _homeBranchId;
      } else if (!_attachToBranch) {
        params['p_clear_home_branch'] = true;
      }
      // F5: лимит экспозиции. Собираем только положительные значения,
      // отправляем лишь если карта изменилась относительно исходной.
      final newLimits = <String, double>{};
      for (final row in _limitRows) {
        final cur = row.currency.toUpperCase();
        final v =
            double.tryParse(row.controller.text.replaceAll(',', '.').trim());
        if (v != null && v > 0) newLimits[cur] = v;
      }
      if (!_sameLimits(newLimits, c.exposureLimit)) {
        params['p_exposure_limit_by_currency'] = newLimits;
      }
    }

    if (params.length == 1) {
      setState(() {
        _saving = false;
        _error = 'Нет изменений';
      });
      return;
    }
    try {
      await Supabase.instance.client
          .rpc('update_counterparty', params: params);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _humanizeUpdateError(e);
      });
    }
  }

  String _humanizeUpdateError(Object e) {
    final s = e.toString();
    if (s.contains('Профиль пользователя') ||
        s.contains('Только Creator') ||
        s.contains('чужому филиалу')) {
      // Бизнес-исключения из RPC — показываем как есть, они уже на
      // русском.
      return s.replaceAll(RegExp(r'^[^:]*:\s*'), '');
    }
    if (s.contains('PGRST') || s.contains('42883')) {
      return 'RPC update_counterparty не найдена. Примените миграцию 035.';
    }
    return 'Не удалось сохранить: $s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(AppIcons.tune, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Изменить «${widget.counterparty.name}»',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Имя партнёра *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.person_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Autocomplete<String>(
                initialValue: TextEditingValue(text: _city.text),
                optionsBuilder: (TextEditingValue value) {
                  final q = value.text.trim().toLowerCase();
                  final all = _allCitySuggestions;
                  if (q.isEmpty) return all.take(10);
                  return all
                      .where((c) => c.toLowerCase().contains(q))
                      .take(10);
                },
                onSelected: (v) => _city.text = v,
                fieldViewBuilder:
                    (ctx, textCtrl, focusNode, onFieldSubmitted) {
                  if (textCtrl.text != _city.text) {
                    textCtrl.text = _city.text;
                  }
                  return TextField(
                    controller: textCtrl,
                    focusNode: focusNode,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Город',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(AppIcons.business, size: 20),
                    ),
                    onChanged: (v) => _city.text = v,
                  );
                },
                optionsViewBuilder: (ctx, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxHeight: 260, maxWidth: 360),
                        child: ListView.separated(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color:
                                scheme.outline.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (_, i) {
                            final opt = options.elementAt(i);
                            return InkWell(
                              onTap: () => onSelected(opt),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Text(opt,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  PhoneInputFormatter(),
                  LengthLimitingTextInputFormatter(
                      kPhoneMaxFormattedLength),
                ],
                decoration: const InputDecoration(
                  labelText: 'Телефон',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.phone, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _notes,
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Заметки',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.info_outline, size: 20),
                ),
              ),
              if (_canEditPrivileged) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Checkbox(
                      value: _attachToBranch,
                      onChanged: (v) => setState(() {
                        _attachToBranch = v ?? false;
                        if (!_attachToBranch) _homeBranchId = null;
                      }),
                    ),
                    const Expanded(
                      child: Text('Привязать к конкретному филиалу',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                if (_attachToBranch) ...[
                  if (_loadingBranches)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    DropdownButtonFormField<String>(
                      initialValue: _homeBranchId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Филиал-якорь',
                        border: OutlineInputBorder(),
                      ),
                      items: _branches
                          .map((b) => DropdownMenuItem<String>(
                                value: b.id,
                                child: Text(b.name,
                                    style:
                                        const TextStyle(fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _homeBranchId = v),
                    ),
                ],
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _feePercent,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    DecimalInputFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Комиссия партнёра %',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(AppIcons.percent, size: 20),
                    suffixText: '%',
                  ),
                ),
                // ── F5: лимит экспозиции (потолок |сальдо|) ──
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Icon(AppIcons.shield,
                        size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Лимит экспозиции',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: AppSpacing.xs),
                  child: Text(
                    'Блокирует новые выплаты, если |сальдо| превысит лимит '
                    'в этой валюте. Расчётам не мешает. Пусто = без лимита.',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
                ..._limitRows.map(
                  (row) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: DropdownButtonFormField<String>(
                            initialValue:
                                CurrencyUtils.supported.contains(row.currency)
                                    ? row.currency
                                    : CurrencyUtils.supported.first,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: CurrencyUtils.supported
                                .map((cur) => DropdownMenuItem(
                                      value: cur,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(CurrencyUtils.flag(cur)),
                                          const SizedBox(width: 4),
                                          Text(cur,
                                              style: const TextStyle(
                                                  fontSize: 13)),
                                        ],
                                      ),
                                    ))
                                .toList(),
                            onChanged: (v) => setState(
                                () => row.currency = v ?? row.currency),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextField(
                            controller: row.controller,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              DecimalInputFormatter(),
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.,]')),
                            ],
                            decoration: InputDecoration(
                              labelText: 'Макс. долг',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              suffixText: row.currency,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Убрать лимит',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(AppIcons.close, size: 18),
                          onPressed: () => setState(() {
                            row.controller.dispose();
                            _limitRows.remove(row);
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addLimitRow,
                    icon: const Icon(AppIcons.add, size: 16),
                    label: const Text('Добавить лимит по валюте'),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    'Привязка к филиалу и % комиссии меняются только Creator/Director.',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.warning_amber,
                          size: 16, color: AppColors.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(
                                color: AppColors.error, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.check, size: 18),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// F5: одна редактируемая строка лимита экспозиции в форме партнёра.
/// currency — изменяемая (дропдаун), controller — поле суммы.
class _ExposureRow {
  _ExposureRow(this.currency, this.controller);
  String currency;
  final TextEditingController controller;
}

class _BranchOption {
  _BranchOption({required this.id, required this.name});

  factory _BranchOption.fromMap(Map<String, dynamic> m) => _BranchOption(
        id: m['id'].toString(),
        name: (m['name'] ?? '').toString(),
      );

  final String id;
  final String name;
}

class _RecordOpDialog extends StatefulWidget {
  const _RecordOpDialog({
    required this.counterparty,
    this.presetCategory,
    this.presetDirection,
    this.presetCurrency,
    this.presetAmount,
  });
  final _Counterparty counterparty;
  /// Предзаполненная категория (payout/settlement). Если NULL — оператор
  /// выбирает сам.
  final _OpCategory? presetCategory;
  /// Направление within категории:
  ///   payout:     true=paid_for_us, false=we_paid_for_them
  ///   settlement: true=settle_to_us (он привёз), false=settle_from_us (мы)
  final bool? presetDirection;
  /// Предзаполненная валюта.
  final String? presetCurrency;
  /// Предзаполненная сумма.
  final double? presetAmount;

  @override
  State<_RecordOpDialog> createState() => _RecordOpDialogState();
}

/// 2 категории операций. «Выплата» — фиксирует факт, что кто-то
/// выплатил клиенту; меняет saldo, но НЕ трогает наш кеш-счёт.
/// «Расчёт» — кэш-движение между нами и партнёром, обнуляет долг.
enum _OpCategory { payout, settlement }

class _RecordOpDialogState extends State<_RecordOpDialog> {
  /// Sentinel для пункта «не указан» в дропдауне способа выплаты.
  static const _payoutSentinelNone = '';

  // Состояние формы: категория + направление (within категории).
  _OpCategory _category = _OpCategory.payout;
  bool _direction = true; // payout: true=он выплатил; settle: true=он привёз
  String _currency = 'UZS';
  String? _cashAccountId;
  String _payoutMethod = _payoutSentinelNone;
  final _amount = TextEditingController();
  final _desc = TextEditingController();
  bool _saving = false;
  String? _error;

  // Cross-currency settlement (миграция 040).
  bool _crossSettle = false;
  String _closeCurrency = 'USD';
  final _closeAmount = TextEditingController();
  final _expectedRate = TextEditingController();
  // F8: курс подставлен из exchange_rates автоматически. Сбрасывается,
  // как только оператор правит поле вручную — тогда мы его не перетираем.
  bool _expectedRateAutofilled = false;
  bool _loadingRate = false;

  List<AccountOption> _accounts = const [];
  bool _loadingAccounts = true;
  String? _accountsError;

  @override
  void initState() {
    super.initState();
    // Применяем presets (если открыты из карточки сальдо).
    if (widget.presetCategory != null) {
      _category = widget.presetCategory!;
    }
    if (widget.presetDirection != null) {
      _direction = widget.presetDirection!;
    }
    if (widget.presetCurrency != null && widget.presetCurrency!.isNotEmpty) {
      _currency = widget.presetCurrency!.toUpperCase();
    }
    if (widget.presetAmount != null && widget.presetAmount! > 0) {
      _amount.text = widget.presetAmount!.toStringAsFixed(
          widget.presetAmount! == widget.presetAmount!.roundToDouble() ? 0 : 2);
    }
    _loadAccounts();
  }

  @override
  void dispose() {
    _amount.dispose();
    _desc.dispose();
    _closeAmount.dispose();
    _expectedRate.dispose();
    super.dispose();
  }

  double get _closeAmountValue =>
      double.tryParse(_closeAmount.text.replaceAll(',', '.')) ?? 0;
  double get _expectedRateValue =>
      double.tryParse(_expectedRate.text.replaceAll(',', '.')) ?? 0;

  /// Settlement profit live-preview (только для cross-currency settle).
  /// Знак рассчитывается по направлению:
  ///   settle_from_us: мы платим → меньше = profit
  ///   settle_to_us:   он платит → больше = profit
  double get _settlementProfitPreview {
    if (!_isSettle || !_crossSettle) return 0;
    if (_amountValue <= 0 || _closeAmountValue <= 0) return 0;
    if (_expectedRateValue <= 0) return 0;
    final actualRate = _amountValue / _closeAmountValue;
    final diff = _expectedRateValue - actualRate;
    // settle_from_us → положительный если actual < expected (мы заплатили меньше)
    // settle_to_us   → положительный если actual > expected (он заплатил больше)
    if (_kind == 'settle_from_us') return diff * _closeAmountValue;
    if (_kind == 'settle_to_us') return -diff * _closeAmountValue;
    return 0;
  }

  /// Resolved kind для RPC. payout: true=paid_for_us, false=we_paid_for_them.
  /// settlement: true=settle_to_us (он привёз), false=settle_from_us (мы отдали).
  String get _kind {
    switch (_category) {
      case _OpCategory.payout:
        return _direction ? 'paid_for_us' : 'we_paid_for_them';
      case _OpCategory.settlement:
        return _direction ? 'settle_to_us' : 'settle_from_us';
    }
  }

  bool get _isSettle => _category == _OpCategory.settlement;
  bool get _isPayout => _category == _OpCategory.payout;

  Future<void> _loadAccounts() async {
    final user = context.read<AuthBloc>().state.user;
    final allowed = accessibleBranchIds(user);
    try {
      final rows = await Supabase.instance.client
          .from('branch_accounts')
          .select('id, branch_id, name, currency, type, is_active, '
              'branches(name)')
          .eq('is_active', true)
          .order('name');
      final list = (rows as List)
          .map((m) =>
              AccountOption.fromMap(Map<String, dynamic>.from(m as Map)))
          .where((a) => allowed == null || allowed.contains(a.branchId))
          .toList()
        // Сортировка branch → currency → name. Дропдауны теперь группируют
        // USD/RUB/UZS-счета подряд — операторы не путают их в общем списке.
        ..sort((a, b) {
          final byBranch = a.branchName.compareTo(b.branchName);
          if (byBranch != 0) return byBranch;
          final byCurrency = a.currency.compareTo(b.currency);
          if (byCurrency != 0) return byCurrency;
          return a.name.compareTo(b.name);
        });
      _deferSetState(() {
        _accounts = list;
        _loadingAccounts = false;
      });
    } catch (e) {
      _deferSetState(() {
        _loadingAccounts = false;
        _accountsError = e.toString();
      });
    }
  }

  void _deferSetState(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(fn);
    });
  }

  /// F8: авто-подстановка ожидаемого курса для cross-currency расчёта.
  /// Тянем последний курс из exchange_rates для пары closeCurrency→cashCurrency.
  /// Не перетираем значение, введённое оператором вручную.
  Future<void> _autoFillExpectedRate() async {
    if (!_crossSettle) return;
    // Если оператор уже что-то ввёл сам — не трогаем.
    if (_expectedRate.text.trim().isNotEmpty && !_expectedRateAutofilled) {
      return;
    }
    final from = _closeCurrency.toUpperCase();
    final to = _currency.toUpperCase();
    if (from == to) return; // одинаковые валюты — cross-settle не нужен
    setState(() => _loadingRate = true);
    final rate = await _fetchMarketRate(from, to);
    if (!mounted) return;
    setState(() {
      _loadingRate = false;
      if (rate != null && rate > 0) {
        _expectedRate.text = _formatRate(rate);
        _expectedRateAutofilled = true;
      }
    });
  }

  /// Возвращает курс «1 [from] = X [to]» из exchange_rates.
  /// Сначала прямая пара, затем обратная (1/rate). null — пары нет.
  Future<double?> _fetchMarketRate(String from, String to) async {
    final client = Supabase.instance.client;
    try {
      final direct = await client
          .from('exchange_rates')
          .select('rate')
          .eq('from_currency', from)
          .eq('to_currency', to)
          .order('effective_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final dr = (direct?['rate'] as num?)?.toDouble();
      if (dr != null && dr > 0) return dr;

      final inverse = await client
          .from('exchange_rates')
          .select('rate')
          .eq('from_currency', to)
          .eq('to_currency', from)
          .order('effective_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final ir = (inverse?['rate'] as num?)?.toDouble();
      if (ir != null && ir > 0) return 1 / ir;
    } catch (_) {
      // Тихо игнорируем: поле останется пустым, профит просто не посчитается.
    }
    return null;
  }

  /// До 8 знаков, без хвостовых нулей.
  String _formatRate(double r) {
    var s = r.toStringAsFixed(8);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  static const _payoutMethods = [
    ('cash', 'Наличные', AppIcons.payments),
    ('card', 'Карта', AppIcons.credit_card),
    ('transfer', 'Банк. перевод', AppIcons.account_balance),
    ('other', 'Другое', AppIcons.more_horiz),
  ];

  /// Подсказки описания — chip-row, по тапу подставляют текст.
  static const _descHints = [
    'Зарплата получателю',
    'Возврат долга',
    'Семейный перевод',
    'Аванс',
    'Аренда',
  ];

  List<AccountOption> get _filteredAccounts => _accounts
      .where((a) => a.currency.toUpperCase() == _currency.toUpperCase())
      .toList();

  double get _amountValue =>
      double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0;

  /// Сдвиг saldo при этой операции. + = он становится должен нам больше,
  /// − = мы становимся должны больше. Зеркальная логика RPC:
  ///   paid_for_us → saldo вниз (-amount)
  ///   we_paid_for_them → saldo вверх (+amount)
  ///   settle_to_us → saldo вниз (-amount)
  ///   settle_from_us → saldo вверх (+amount)
  double get _saldoDelta {
    if (_amountValue <= 0) return 0;
    switch (_kind) {
      case 'paid_for_us':
        return -_amountValue;
      case 'we_paid_for_them':
        return _amountValue;
      case 'settle_to_us':
        return -_amountValue;
      case 'settle_from_us':
        return _amountValue;
      default:
        return 0;
    }
  }

  double get _currentSaldo =>
      widget.counterparty.saldo[_currency.toUpperCase()] ?? 0;

  double get _futureSaldo => _currentSaldo + _saldoDelta;

  Future<void> _submit() async {
    final amount = _amountValue;
    if (amount <= 0) {
      setState(() => _error = 'Введите сумму больше 0');
      return;
    }
    if (_isSettle) {
      if (_cashAccountId == null) {
        setState(() => _error = 'Выберите наш кеш-счёт для расчёта');
        return;
      }
      final acc = _accounts.firstWhere(
        (a) => a.id == _cashAccountId,
        orElse: () => AccountOption.empty(),
      );
      if (acc.id.isEmpty) {
        setState(() => _error = 'Счёт не найден; обновите страницу');
        return;
      }
      if (acc.currency.toUpperCase() != _currency.toUpperCase()) {
        setState(() => _error =
            'Валюта операции ($_currency) не совпадает с валютой счёта (${acc.currency})');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('record_counterparty_op', params: {
        'p_counterparty_id': widget.counterparty.id,
        'p_kind': _kind,
        'p_amount': amount,
        'p_currency': _currency,
        if (_desc.text.trim().isNotEmpty) 'p_description': _desc.text.trim(),
        if (_cashAccountId != null && _isSettle)
          'p_cash_account_id': _cashAccountId,
        if (_payoutMethod != _payoutSentinelNone && _isPayout)
          'p_payout_method': _payoutMethod,
        // Cross-currency settlement (миграция 040).
        if (_isSettle && _crossSettle && _closeAmountValue > 0) ...{
          'p_close_amount': _closeAmountValue,
          'p_close_currency': _closeCurrency,
          if (_expectedRateValue > 0) 'p_expected_rate': _expectedRateValue,
        },
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = _humanizeRecordError(e);
      });
    }
  }

  String _humanizeRecordError(Object e) {
    final s = e.toString();
    if (s.contains('архивирован') || s.contains('деактивирован')) {
      return 'Партнёр в архиве — восстановите его перед операцией.';
    }
    if (s.contains('Insufficient') || s.contains('Недостаточно')) {
      return s.replaceAll(RegExp(r'^[^:]*:\s*'), '');
    }
    if (s.contains('PGRST') || s.contains('42883')) {
      return 'RPC record_counterparty_op не найдена. Примените миграции 029/033.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _filteredAccounts;
    final safeAccountId =
        filtered.any((a) => a.id == _cashAccountId) ? _cashAccountId : null;

    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(AppIcons.add, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Запись операции'),
                Text(
                  widget.counterparty.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 1. Категория операции ─────────────────────
              const _RecordSectionTitle('Что произошло'),
              SegmentedButton<_OpCategory>(
                segments: const [
                  ButtonSegment(
                    value: _OpCategory.payout,
                    label: Text('Выплата клиенту'),
                    icon: Icon(Icons.payments_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: _OpCategory.settlement,
                    label: Text('Расчёт между нами'),
                    icon: Icon(Icons.swap_horiz, size: 16),
                  ),
                ],
                selected: {_category},
                onSelectionChanged: (s) => setState(() {
                  _category = s.first;
                  _direction = true;
                }),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // ── 2. Направление в выбранной категории ──────
              _DirectionChips(
                category: _category,
                value: _direction,
                onChanged: (v) => setState(() => _direction = v),
              ),
              const SizedBox(height: 4),
              Text(
                _explainKind(_kind, widget.counterparty.name),
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 3. Сумма + валюта ──────────────────────────
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        DecimalInputFormatter(),
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Сумма',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(AppIcons.payments, size: 20),
                        suffixText: _currency,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue: _currency,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Валюта',
                        border: OutlineInputBorder(),
                      ),
                      items: CurrencyUtils.supported
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(CurrencyUtils.flag(c)),
                                    const SizedBox(width: 6),
                                    Text(c,
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        setState(() => _currency = v ?? _currency);
                        // Меняется валюта cash → пересчитать авто-курс.
                        _autoFillExpectedRate();
                      },
                    ),
                  ),
                ],
              ),
              // ── Saldo preview «было → станет» ─────────────
              if (_amountValue > 0) ...[
                const SizedBox(height: AppSpacing.xs),
                _SaldoPreviewLine(
                  currency: _currency,
                  current: _currentSaldo,
                  future: _futureSaldo,
                ),
              ],
              const SizedBox(height: AppSpacing.md),

              // ── 4. Settle: кеш-счёт ───────────────────────
              if (_isSettle) ...[
                const _RecordSectionTitle('Наш кеш-счёт для расчёта'),
                if (_loadingAccounts)
                  const LinearProgressIndicator(minHeight: 2)
                else if (_accountsError != null)
                  Text(
                    'Не удалось загрузить счета: $_accountsError',
                    style: TextStyle(color: AppColors.error, fontSize: 12),
                  )
                else if (filtered.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.08),
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: Text(
                      'Нет доступных счетов в валюте $_currency. '
                      'Создайте счёт в этой валюте или поменяйте валюту операции.',
                      style: TextStyle(
                        color: AppColors.error,
                        fontSize: 12,
                      ),
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: safeAccountId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Наш кеш-счёт',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(AppIcons.account_balance, size: 20),
                    ),
                    items: filtered
                        .map((a) => DropdownMenuItem(
                              value: a.id,
                              child: Text(
                                a.displayLabel,
                                style: const TextStyle(fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _cashAccountId = v),
                  ),
                const SizedBox(height: AppSpacing.md),
                // ── Cross-currency settlement toggle ──────────
                _CrossSettleBlock(
                  enabled: _crossSettle,
                  cashCurrency: _currency,
                  closeCurrency: _closeCurrency,
                  closeAmountCtrl: _closeAmount,
                  expectedRateCtrl: _expectedRate,
                  amountValue: _amountValue,
                  closeAmountValue: _closeAmountValue,
                  expectedRateValue: _expectedRateValue,
                  settlementProfit: _settlementProfitPreview,
                  kind: _kind,
                  loadingRate: _loadingRate,
                  rateAutofilled: _expectedRateAutofilled,
                  onEnabledChanged: (v) {
                    setState(() {
                      _crossSettle = v;
                      if (!v) {
                        _closeAmount.clear();
                        _expectedRate.clear();
                        _expectedRateAutofilled = false;
                      }
                    });
                    // При включении — подставить рыночный курс.
                    if (v) _autoFillExpectedRate();
                  },
                  onCloseCurrencyChanged: (v) {
                    setState(() => _closeCurrency = v);
                    // Сменили валюту долга → пересчитать авто-курс.
                    _autoFillExpectedRate();
                  },
                  onCloseAmountChanged: () => setState(() {}),
                  onExpectedRateChanged: () => setState(() {
                    // Оператор правит вручную — больше не считаем поле авто.
                    _expectedRateAutofilled = false;
                  }),
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              // ── 5. Payout: способ выплаты chip-row ────────
              if (_isPayout) ...[
                const _RecordSectionTitle('Способ выплаты (необязательно)'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      selected: _payoutMethod == _payoutSentinelNone,
                      onSelected: (_) => setState(
                          () => _payoutMethod = _payoutSentinelNone),
                      label: const Text('Не указан'),
                      labelStyle: const TextStyle(fontSize: 12),
                      showCheckmark: false,
                    ),
                    ..._payoutMethods.map((m) {
                      final selected = _payoutMethod == m.$1;
                      return ChoiceChip(
                        selected: selected,
                        onSelected: (_) =>
                            setState(() => _payoutMethod = m.$1),
                        avatar: Icon(
                          m.$3,
                          size: 14,
                          color: selected
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                        label: Text(m.$2),
                        labelStyle: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                        selectedColor: scheme.primary,
                        showCheckmark: false,
                      );
                    }),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              // ── 6. Описание + подсказки ───────────────────
              TextField(
                controller: _desc,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.description, size: 20),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _descHints
                    .map((h) => ActionChip(
                          label: Text(h, style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onPressed: () {
                            _desc.text = h;
                            _desc.selection = TextSelection.collapsed(
                                offset: h.length);
                            setState(() {});
                          },
                        ))
                    .toList(),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 7. Preview: saldo до → saldo после ────────
              if (_amountValue > 0)
                _SaldoPreviewCard(
                  current: _currentSaldo,
                  future: _futureSaldo,
                  currency: _currency,
                  partnerName: widget.counterparty.name,
                ),

              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.warning_amber,
                          size: 16, color: AppColors.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style:
                                TextStyle(color: AppColors.error, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.check, size: 18),
          label: const Text('Записать'),
        ),
      ],
    );
  }
}

/// 2 чипа направления внутри выбранной категории. Тексты адаптируются
/// под категорию: «он → клиент» / «мы → клиент» для payout и
/// «он привёз кэш» / «мы отдали кэш» для settlement.
class _DirectionChips extends StatelessWidget {
  const _DirectionChips({
    required this.category,
    required this.value,
    required this.onChanged,
  });

  final _OpCategory category;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isPayout = category == _OpCategory.payout;
    final labelTrue =
        isPayout ? 'Он выплатил нашему клиенту' : 'Он привёз нам наличные';
    final labelFalse =
        isPayout ? 'Мы выплатили его клиенту' : 'Мы отдали ему наличные';
    return SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: true,
          label: Text(labelTrue, style: const TextStyle(fontSize: 12)),
          icon: const Icon(Icons.arrow_downward, size: 14),
        ),
        ButtonSegment(
          value: false,
          label: Text(labelFalse, style: const TextStyle(fontSize: 12)),
          icon: const Icon(Icons.arrow_upward, size: 14),
        ),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// Карточка «Saldo до → Saldo после». Показывает текущее и будущее
/// сальдо по валюте операции, с цветовой кодировкой.
class _SaldoPreviewCard extends StatelessWidget {
  const _SaldoPreviewCard({
    required this.current,
    required this.future,
    required this.currency,
    required this.partnerName,
  });

  final double current;
  final double future;
  final String currency;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.10),
            scheme.primary.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.fact_check, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Saldo с $partnerName в $currency',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SaldoValue(value: current, label: 'Сейчас'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(AppIcons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant), // декоративно: до→после
              ),
              _SaldoValue(value: future, label: 'После операции', bold: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _hint(current, future),
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _hint(double before, double after) {
    if (after.abs() < 0.005) return 'Расчёты с партнёром закроются в 0.';
    final whoOwesAfter = after > 0
        ? 'Партнёр останется должен нам'
        : 'Мы останемся должны партнёру';
    return '$whoOwesAfter ${after.abs().formatCurrencyNoDecimals()} $currency';
  }
}

class _SaldoValue extends StatelessWidget {
  const _SaldoValue({
    required this.value,
    required this.label,
    this.bold = false,
  });
  final double value;
  final String label;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final positive = value > 0.005;
    final negative = value < -0.005;
    final color = positive
        ? Colors.green.shade600
        : negative
            ? Colors.red.shade600
            : scheme.onSurfaceVariant;
    final prefix = positive ? '+' : '';
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$prefix${value.formatCurrencyNoDecimals()}',
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: bold ? 18 : 16,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview «saldo было X → станет Y» для конкретной валюты в
/// _RecordOpDialog. Зелёная стрелка = долг партнёра уменьшается в нашу
/// пользу, красная = наша задолженность растёт.
class _SaldoPreviewLine extends StatelessWidget {
  const _SaldoPreviewLine({
    required this.currency,
    required this.current,
    required this.future,
  });
  final String currency;
  final double current;
  final double future;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color colorFor(double v) => v > 0
        ? Colors.green.shade700
        : (v < 0 ? Colors.red.shade700 : scheme.onSurfaceVariant);
    String fmt(double v) =>
        '${v > 0 ? '+' : ''}${v.formatCurrency()} $currency';
    final improving = future.abs() < current.abs(); // долг уменьшается
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Icon(
            improving ? Icons.trending_down : Icons.trending_up,
            size: 14,
            color: improving ? Colors.green.shade700 : Colors.orange.shade700,
          ),
          const SizedBox(width: 6),
          Text(
            'Saldo:',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            fmt(current),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: colorFor(current),
              fontFamily: 'JetBrains Mono',
            ),
          ),
          const SizedBox(width: 4),
          Icon(AppIcons.arrow_forward, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            fmt(future),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: colorFor(future),
              fontFamily: 'JetBrains Mono',
            ),
          ),
        ],
      ),
    );
  }
}

/// Блок «Cross-currency расчёт» в _RecordOpDialog для settle-операций.
/// Когда партнёр привозит UZS вместо USD (или наоборот) — переключаем
/// toggle и указываем:
///   • валюту и сумму закрываемого долга (из saldo)
///   • ожидаемый курс (если знаем sell_rate из transfer-ов)
/// Система покажет live-preview settlement profit/loss до клика «Записать».

class _CrossSettleBlock extends StatelessWidget {
  const _CrossSettleBlock({
    required this.enabled,
    required this.cashCurrency,
    required this.closeCurrency,
    required this.closeAmountCtrl,
    required this.expectedRateCtrl,
    required this.amountValue,
    required this.closeAmountValue,
    required this.expectedRateValue,
    required this.settlementProfit,
    required this.kind,
    required this.loadingRate,
    required this.rateAutofilled,
    required this.onEnabledChanged,
    required this.onCloseCurrencyChanged,
    required this.onCloseAmountChanged,
    required this.onExpectedRateChanged,
  });

  final bool enabled;
  final String cashCurrency;
  final String closeCurrency;
  final TextEditingController closeAmountCtrl;
  final TextEditingController expectedRateCtrl;
  final double amountValue;
  final double closeAmountValue;
  final double expectedRateValue;
  final double settlementProfit;
  final String kind;
  final bool loadingRate;
  final bool rateAutofilled;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String> onCloseCurrencyChanged;
  final VoidCallback onCloseAmountChanged;
  final VoidCallback onExpectedRateChanged;

  static const _bases = ['USD', 'EUR', 'RUB', 'UZS', 'KZT'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: enabled
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: enabled
              ? scheme.primary.withValues(alpha: 0.25)
              : scheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Switch(
                value: enabled,
                onChanged: onEnabledChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Cross-currency расчёт',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: enabled ? scheme.primary : null,
                      ),
                    ),
                    Text(
                      enabled
                          ? 'Закрываем долг в другой валюте, чем платим cash'
                          : 'Включи если saldo в USD, а cash в UZS (или наоборот)',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.sm),
            // Что закрываем (валюта + сумма).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: _bases.contains(closeCurrency)
                        ? closeCurrency
                        : 'USD',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Валюта долга',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _bases
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(CurrencyUtils.flag(c)),
                                  const SizedBox(width: 4),
                                  Text(c,
                                      style: const TextStyle(fontSize: 13)),
                                ],
                              ),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) onCloseCurrencyChanged(v);
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: closeAmountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      DecimalInputFormatter(),
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    onChanged: (_) => onCloseAmountChanged(),
                    decoration: InputDecoration(
                      labelText: 'Закрываем из долга',
                      helperText: 'Sumма в $closeCurrency',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // Ожидаемый курс (F8: авто-подстановка из exchange_rates).
            TextField(
              controller: expectedRateCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                DecimalInputFormatter(),
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              onChanged: (_) => onExpectedRateChanged(),
              decoration: InputDecoration(
                labelText: rateAutofilled
                    ? 'Ожидаемый курс (авто из exchange_rates)'
                    : 'Ожидаемый курс (для расчёта прибыли)',
                helperText:
                    '1 $closeCurrency = X $cashCurrency. Если NULL — профит не считается.',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: loadingRate
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (rateAutofilled
                        ? Tooltip(
                            message: 'Курс подставлен автоматически. '
                                'Можно изменить вручную.',
                            child: Icon(AppIcons.bolt,
                                size: 18, color: scheme.primary),
                          )
                        : null),
              ),
            ),
            // Live preview.
            if (amountValue > 0 && closeAmountValue > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 6),
                decoration: BoxDecoration(
                  color: settlementProfit > 0
                      ? Colors.green.withValues(alpha: 0.1)
                      : (settlementProfit < 0
                          ? Colors.red.withValues(alpha: 0.08)
                          : scheme.surfaceContainerHighest
                              .withValues(alpha: 0.5)),
                  borderRadius:
                      BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(
                      settlementProfit > 0
                          ? Icons.trending_up
                          : (settlementProfit < 0
                              ? Icons.trending_down
                              : Icons.trending_flat),
                      size: 16,
                      color: settlementProfit > 0
                          ? Colors.green.shade700
                          : (settlementProfit < 0
                              ? Colors.red.shade700
                              : scheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        () {
                          final actualRate =
                              amountValue / closeAmountValue;
                          if (expectedRateValue <= 0) {
                            return 'Фактический курс: ${actualRate.toStringAsFixed(2)} '
                                '(нет ожидаемого → профит не считается)';
                          }
                          if (settlementProfit.abs() < 0.005) {
                            return 'Курс совпал — без spread';
                          }
                          return settlementProfit > 0
                              ? 'Прибыль расчёта: +${settlementProfit.formatCurrency()} $cashCurrency'
                              : 'Убыток расчёта: ${settlementProfit.formatCurrency()} $cashCurrency';
                        }(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: settlementProfit > 0
                              ? Colors.green.shade800
                              : (settlementProfit < 0
                                  ? Colors.red.shade800
                                  : null),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _RecordSectionTitle extends StatelessWidget {
  const _RecordSectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Человекочитаемое объяснение каждого kind — берётся из бизнес-описания
/// миграции 029 (raw названия в БД).
String _explainKind(String kind, String partner) {
  switch (kind) {
    case 'paid_for_us':
      return '$partner выплатил нашему клиенту. После записи мы будем должны $partner на сумму операции.';
    case 'we_paid_for_them':
      return 'Мы выплатили клиенту $partner. После записи $partner будет должен нам на сумму операции.';
    case 'settle_to_us':
      return '$partner привёз нам наличные и закрыл часть долга — деньги зачислятся на наш кеш-счёт.';
    case 'settle_from_us':
      return 'Мы отдали $partner наличные — деньги спишутся с нашего кеш-счёта.';
    default:
      return '';
  }
}

// ─── Models ───

class _Counterparty {
  _Counterparty({
    required this.id,
    required this.name,
    this.city,
    this.phone,
    this.notes,
    this.saldo = const {},
    this.exposureLimit = const {},
    this.isActive = true,
    this.feePercentage,
    this.txCount = 0,
    this.lastOpAt,
  });

  factory _Counterparty.fromMap(Map<String, dynamic> m) {
    final saldoRaw = m['saldo_by_currency'];
    final saldo = <String, double>{};
    if (saldoRaw is Map) {
      saldoRaw.forEach((k, v) {
        if (v is num) saldo[k.toString()] = v.toDouble();
        if (v is String) saldo[k.toString()] = double.tryParse(v) ?? 0;
      });
    }
    final limitRaw = m['exposure_limit_by_currency'];
    final limit = <String, double>{};
    if (limitRaw is Map) {
      limitRaw.forEach((k, v) {
        final d = v is num ? v.toDouble() : double.tryParse(v.toString());
        if (d != null && d > 0) limit[k.toString().toUpperCase()] = d;
      });
    }
    return _Counterparty(
      id: m['id'].toString(),
      name: (m['name'] ?? '').toString(),
      city: (m['city'] as String?)?.trim().isEmpty == true
          ? null
          : m['city'] as String?,
      phone: (m['phone'] as String?)?.trim().isEmpty == true
          ? null
          : m['phone'] as String?,
      notes: (m['notes'] as String?)?.trim().isEmpty == true
          ? null
          : m['notes'] as String?,
      saldo: saldo,
      exposureLimit: limit,
      isActive: (m['is_active'] as bool?) ?? true,
      feePercentage: (m['fee_percentage'] as num?)?.toDouble(),
      txCount: (m['tx_count'] as num?)?.toInt() ?? 0,
      lastOpAt: DateTime.tryParse(m['last_op_at']?.toString() ?? ''),
    );
  }

  final String id;
  final String name;
  final String? city;
  final String? phone;
  final String? notes;
  final Map<String, double> saldo;

  /// F5: per-currency потолок |saldo|. Пусто = лимита нет.
  final Map<String, double> exposureLimit;
  final bool isActive;
  final double? feePercentage;
  final int txCount;
  final DateTime? lastOpAt;

  /// Абсолютная сумма по всем валютам saldo — для сортировки. Без
  /// конвертации (нет курсов на странице партнёров), но порядок более
  /// или менее корректный: чем больше «должны» в любой валюте, тем
  /// раньше.
  double get saldoMagnitude =>
      saldo.values.fold<double>(0, (acc, v) => acc + v.abs());
}

class _CounterpartyTx {
  _CounterpartyTx({
    required this.id,
    required this.kind,
    required this.amount,
    required this.currency,
    this.description,
    required this.createdAt,
    this.transferId,
    this.transactionCode,
    this.buyRate,
    this.sellRate,
    this.baseCurrency,
    this.spreadProfit,
    this.viaCounterparty = false,
    this.closesAmount,
    this.closesCurrency,
    this.expectedRate,
    this.settlementProfit,
    this.settlementProfitCurrency,
    this.receiverName,
    this.receiverPhone,
    this.receiverInfo,
  });

  factory _CounterpartyTx.fromMap(Map<String, dynamic> m) {
    return _CounterpartyTx(
      id: m['id'].toString(),
      kind: m['kind'].toString(),
      amount: (m['amount'] as num).toDouble(),
      currency: m['currency'].toString(),
      description: m['description'] as String?,
      createdAt:
          DateTime.tryParse(m['created_at'].toString()) ?? DateTime.now(),
      transferId: m['transfer_id']?.toString(),
      transactionCode: m['transaction_code']?.toString(),
      buyRate: (m['buy_rate'] as num?)?.toDouble(),
      sellRate: (m['sell_rate'] as num?)?.toDouble(),
      baseCurrency: m['base_currency']?.toString(),
      spreadProfit: (m['spread_profit'] as num?)?.toDouble(),
      viaCounterparty: (m['via_counterparty'] as bool?) ?? false,
      closesAmount: (m['closes_amount'] as num?)?.toDouble(),
      closesCurrency: m['closes_currency']?.toString(),
      expectedRate: (m['expected_rate'] as num?)?.toDouble(),
      settlementProfit: (m['settlement_profit'] as num?)?.toDouble(),
      settlementProfitCurrency: m['settlement_profit_currency']?.toString(),
      receiverName: m['receiver_name']?.toString(),
      receiverPhone: m['receiver_phone']?.toString(),
      receiverInfo: m['receiver_info']?.toString(),
    );
  }

  final String id;
  final String kind;
  final double amount;
  final String currency;
  final String? description;
  final DateTime createdAt;
  final String? transferId;
  final String? transactionCode;
  final double? buyRate;
  final double? sellRate;
  final String? baseCurrency;
  final double? spreadProfit;
  final bool viaCounterparty;
  // Settlement spread.
  final double? closesAmount;
  final String? closesCurrency;
  final double? expectedRate;
  final double? settlementProfit;
  final String? settlementProfitCurrency;
  // Получатель связанного перевода (только для paid_for_us tx).
  final String? receiverName;
  final String? receiverPhone;
  final String? receiverInfo;

  /// Cross-currency settlement = у нас разные currency/closesCurrency.
  bool get isCrossCurrencySettle =>
      closesCurrency != null && closesCurrency != currency;
  /// Есть зафиксированный settlement profit (положительный или отрицательный).
  bool get hasSettlementProfit =>
      settlementProfit != null && settlementProfit!.abs() > 0.005;

  /// Признак «партнёрский перевод без проставленных курсов» —
  /// в UI показываем как backfill candidate.
  bool get isMissingRates =>
      viaCounterparty && transferId != null &&
      (buyRate == null || sellRate == null);

  /// Признак «партнёрский перевод с уже проставленными курсами» —
  /// в UI можно показать spread.
  bool get hasSpreadInfo =>
      viaCounterparty &&
      buyRate != null &&
      sellRate != null &&
      spreadProfit != null;
}

String _kindLabel(String kind) {
  switch (kind) {
    case 'paid_for_us':
      return 'Выплатил нашему клиенту';
    case 'we_paid_for_them':
      return 'Мы выплатили его клиенту';
    case 'settle_to_us':
      return 'Погашение долга (к нам)';
    case 'settle_from_us':
      return 'Погашение долга (от нас)';
    default:
      return kind;
  }
}

String _signFor(String kind) {
  switch (kind) {
    case 'we_paid_for_them':
    case 'settle_from_us':
      return '+';
    case 'paid_for_us':
    case 'settle_to_us':
      return '−';
    default:
      return '';
  }
}

IconData _iconFor(String kind) {
  switch (kind) {
    case 'paid_for_us':
    case 'settle_to_us':
      return AppIcons.arrow_downward;
    case 'we_paid_for_them':
    case 'settle_from_us':
      return AppIcons.arrow_upward;
    default:
      return AppIcons.swap_horiz;
  }
}

// _saldoText удалена в пользу _SaldoMini-чипа на карточках партнёров —
// цветной чип с +/− гораздо нагляднее текстовой строки на нескольких
// валютах.
