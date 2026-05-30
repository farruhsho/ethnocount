import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/transfers/widgets/dealer_rates_block.dart';

/// Единый диалог прикрепления перевода к партнёру. Раньше было два
/// отдельных диалога с дублирующейся логикой:
///   • в transfers_page (выбран перевод, оператор ищет партнёра)
///   • в counterparties_page (выбран партнёр, оператор ищет перевод)
///
/// Оба вызывают одну и ту же RPC `attach_transfer_to_partner`, отличаются
/// только тем, какая сторона зафиксирована. Теперь один widget с двумя
/// режимами + общий preview saldo до/после.
enum AttachTransferDialogMode { knownTransfer, knownPartner }

/// Открыть диалог. Возвращает `true` если прикрепление успешно.
Future<bool?> showAttachTransferToPartnerDialog(
  BuildContext context, {
  required AttachTransferDialogMode mode,
  Transfer? transfer,
  Map<String, dynamic>? partner,
}) {
  assert(
    (mode == AttachTransferDialogMode.knownTransfer && transfer != null) ||
        (mode == AttachTransferDialogMode.knownPartner && partner != null),
    'transfer required for knownTransfer mode; partner required for knownPartner mode',
  );
  return showDialog<bool>(
    context: context,
    builder: (_) => AttachTransferToPartnerDialog(
      mode: mode,
      transfer: transfer,
      partner: partner,
    ),
  );
}

class AttachTransferToPartnerDialog extends StatefulWidget {
  const AttachTransferToPartnerDialog({
    super.key,
    required this.mode,
    this.transfer,
    this.partner,
  });

  final AttachTransferDialogMode mode;
  final Transfer? transfer;
  final Map<String, dynamic>? partner;

  @override
  State<AttachTransferToPartnerDialog> createState() =>
      _AttachTransferToPartnerDialogState();
}

class _AttachTransferToPartnerDialogState
    extends State<AttachTransferToPartnerDialog> {
  final _search = TextEditingController();
  Timer? _debounce;

  // Списки кандидатов (загружаются через RPC).
  List<Map<String, dynamic>> _partners = const [];
  List<Map<String, dynamic>> _transfers = const [];
  bool _loading = true;

  // Selection ids — то, что НЕ зафиксировано режимом.
  String? _selectedPartnerId;
  String? _selectedTransferId;

  // Cached данные о выбранном объекте для preview saldo.
  Map<String, dynamic>? _selectedPartnerData;
  Map<String, dynamic>? _selectedTransferData;

  bool _useDealer = false;
  String _baseCurrency = 'USD';
  final _buyRate = TextEditingController();
  final _sellRate = TextEditingController();
  String _payoutMethod = 'cash';

  bool _saving = false;
  String? _error;

  static const _payoutMethods = [
    ('cash', 'Наличные'),
    ('card', 'Карта'),
    ('transfer', 'Банк'),
    ('other', 'Другое'),
  ];

  bool get _knownTransfer =>
      widget.mode == AttachTransferDialogMode.knownTransfer;

  @override
  void initState() {
    super.initState();
    // Предустановка зафиксированной стороны.
    if (widget.mode == AttachTransferDialogMode.knownPartner) {
      _selectedPartnerId = widget.partner?['id']?.toString();
      _selectedPartnerData = widget.partner;
    }
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _buyRate.dispose();
    _sellRate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (_knownTransfer) {
        // Загружаем партнёров.
        final rows = await Supabase.instance.client.rpc(
          'counterparties_list',
          params: {'p_include_archived': false},
        ).timeout(const Duration(seconds: 12));
        final list = (rows as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList();
        if (!mounted) return;
        setState(() {
          _partners = list;
          _loading = false;
        });
      } else {
        await _searchTransfers('');
      }
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _error = s.contains('PGRST') || s.contains('42883')
            ? 'Примените миграции 034 и 041 (counterparties + attach RPC).'
            : 'Не удалось загрузить данные: $s';
      });
    }
  }

  Future<void> _searchTransfers(String q) async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('transfers_attachable_to_partner', params: {
        if (q.trim().isNotEmpty) 'p_search': q.trim(),
        'p_limit': 50,
      }).timeout(const Duration(seconds: 12));
      final list = (rows as List)
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _transfers = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _error = s.contains('PGRST') || s.contains('42883')
            ? 'RPC не найден. Примените миграцию 041.'
            : 'Не удалось загрузить переводы: $s';
      });
    }
  }

  void _onSearchChanged(String s) {
    if (_knownTransfer) {
      // По партнёрам — фильтруем локально, дополнительный запрос не нужен.
      setState(() {});
      return;
    }
    // По переводам — серверный поиск с debounce.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchTransfers(s);
    });
  }

  List<Map<String, dynamic>> get _filteredPartners {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _partners;
    return _partners.where((p) {
      final name = (p['name'] ?? '').toString().toLowerCase();
      final city = (p['city'] ?? '').toString().toLowerCase();
      return name.contains(q) || city.contains(q);
    }).toList();
  }

  /// Для preview: saldo выбранного партнёра в валюте перевода (до операции).
  /// Если partner ещё не выбран или нет валюты — null.
  double? get _saldoBefore {
    final partner = _selectedPartnerData;
    if (partner == null) return null;
    final saldo = partner['saldo_by_currency'];
    final currency = _previewCurrency;
    if (saldo is! Map || currency == null) return null;
    final v = saldo[currency];
    if (v == null) return 0;
    return (v as num).toDouble();
  }

  /// Сумма, на которую саldo «прибавится в минус» (то, что станет
  /// должен партнёр). После миграции 047 это всегда amount перевода
  /// в валюте перевода — base_currency больше не сворачивает.
  double? get _saldoDelta {
    final t = _knownTransfer ? widget.transfer : null;
    final selected = !_knownTransfer ? _selectedTransferData : null;
    if (t != null) return -t.amount;
    if (selected != null) return -((selected['amount'] as num).toDouble());
    return null;
  }

  String? get _previewCurrency {
    if (_knownTransfer) return widget.transfer?.currency;
    final m = _selectedTransferData;
    if (m == null) return null;
    return m['currency']?.toString();
  }

  Future<void> _submit() async {
    if (_selectedPartnerId == null) {
      setState(() => _error = 'Выберите партнёра');
      return;
    }
    if (_selectedTransferId == null && !_knownTransfer) {
      setState(() => _error = 'Выберите перевод');
      return;
    }
    if (_useDealer) {
      final buy = double.tryParse(_buyRate.text.replaceAll(',', '.')) ?? 0;
      final sell = double.tryParse(_sellRate.text.replaceAll(',', '.')) ?? 0;
      if (buy <= 0 || sell <= 0) {
        setState(() => _error = 'Введите buy и sell rate');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final transferId =
          _knownTransfer ? widget.transfer!.id : _selectedTransferId!;
      final params = <String, dynamic>{
        'p_transfer_id': transferId,
        'p_counterparty_id': _selectedPartnerId,
        'p_payout_method': _payoutMethod,
      };
      if (_useDealer) {
        params['p_buy_rate'] =
            double.tryParse(_buyRate.text.replaceAll(',', '.')) ?? 0;
        params['p_sell_rate'] =
            double.tryParse(_sellRate.text.replaceAll(',', '.')) ?? 0;
        params['p_base_currency'] = _baseCurrency;
      }
      await Supabase.instance.client
          .rpc('attach_transfer_to_partner', params: params);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _humanizeError(e);
      });
    }
  }

  /// Разбираем типовые ошибки RPC в человекочитаемое сообщение. Длинная
  /// цепочка contains() гораздо проще для глаза, чем вложенные тернары.
  String _humanizeError(Object e) {
    final s = e.toString();
    if (s.contains('PGRST') || s.contains('42883')) {
      return 'Примените миграцию 041.';
    }
    if (s.contains('уже привязан')) {
      return 'Перевод уже привязан к другому партнёру.';
    }
    if (s.contains('чужой филиал') ||
        s.contains('Чужой') ||
        s.contains('чужого филиала')) {
      return 'Можно прикреплять только свои переводы.';
    }
    if (s.contains('другому филиалу')) {
      return 'Партнёр привязан к другому филиалу. Только Director может прикреплять.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(scheme),
              const SizedBox(height: AppSpacing.sm),
              if (_knownTransfer) _knownTransferBox(scheme),
              if (!_knownTransfer) _knownPartnerBox(scheme),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  labelText: _knownTransfer
                      ? 'Поиск партнёра'
                      : 'Поиск: код, ФИО получателя, телефон',
                  prefixIcon: const Icon(AppIcons.search, size: 18),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: 220,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _knownTransfer
                        ? _partnersList(scheme)
                        : _transfersList(scheme),
              ),
              const SizedBox(height: AppSpacing.sm),
              _payoutMethodRow(),
              const SizedBox(height: AppSpacing.sm),
              _dealerToggle(scheme),
              if (_useDealer) ...[
                const SizedBox(height: AppSpacing.sm),
                DealerRatesBlock(
                  baseCurrency: _baseCurrency,
                  sourceCurrency:
                      _previewCurrency ?? _baseCurrency,
                  onBaseChanged: (v) => setState(() => _baseCurrency = v),
                  buyController: _buyRate,
                  sellController: _sellRate,
                  showFillMarketRate: true,
                ),
              ],
              if (_previewBlock() != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _previewBlock()!,
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(color: AppColors.error, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Отмена'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving || !_canSubmit ? null : _submit,
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(AppIcons.check, size: 18),
                    label: const Text('Привязать'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _canSubmit {
    if (_selectedPartnerId == null) return false;
    if (!_knownTransfer && _selectedTransferId == null) return false;
    return true;
  }

  Widget _header(ColorScheme scheme) {
    final title = _knownTransfer
        ? 'Привязать к партнёру: ${widget.transfer?.transactionCode ?? widget.transfer!.id.substring(0, 8)}'
        : 'Прикрепить перевод к ${widget.partner?['name'] ?? '—'}';
    return Row(
      children: [
        Icon(AppIcons.account_tree, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(AppIcons.close),
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    );
  }

  Widget _knownTransferBox(ColorScheme scheme) {
    final t = widget.transfer!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Сумма: ${t.amount.formatCurrencyNoDecimals()} ${t.currency} → '
        '${(t.receiverName ?? '').isEmpty ? '—' : t.receiverName}',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _knownPartnerBox(ColorScheme scheme) {
    final p = widget.partner!;
    final saldoMap = p['saldo_by_currency'];
    String? saldoLine;
    if (saldoMap is Map && saldoMap.isNotEmpty) {
      final parts = saldoMap.entries
          .where((e) => ((e.value as num?) ?? 0) != 0)
          .map((e) =>
              '${(e.value as num).toDouble().formatCurrencyNoDecimals()} ${e.key}')
          .toList();
      if (parts.isNotEmpty) saldoLine = 'Saldo: ${parts.join(' / ')}';
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${p['name'] ?? '—'}'
            '${(p['city'] as String?)?.isNotEmpty == true ? ' · ${p['city']}' : ''}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          if (saldoLine != null) ...[
            const SizedBox(height: 2),
            Text(saldoLine, style: const TextStyle(fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _partnersList(ColorScheme scheme) {
    final list = _filteredPartners;
    if (list.isEmpty) {
      return Center(
        child: Text('Нет партнёров',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: scheme.outline.withValues(alpha: 0.12),
      ),
      itemBuilder: (_, i) {
        final p = list[i];
        final id = p['id']?.toString() ?? '';
        final selected = _selectedPartnerId == id;
        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: scheme.primary.withValues(alpha: 0.1),
          onTap: () => setState(() {
            _selectedPartnerId = id;
            _selectedPartnerData = p;
          }),
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: scheme.primary.withValues(alpha: 0.15),
            child: Text(
              (p['name'] ?? '?').toString().characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ),
          title: Text(
            (p['name'] ?? '—').toString(),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          subtitle: (p['city'] as String?)?.isNotEmpty == true
              ? Text(p['city'].toString(),
                  style: const TextStyle(fontSize: 11))
              : null,
          trailing: selected
              ? Icon(AppIcons.check_circle, size: 18, color: scheme.primary)
              : null,
        );
      },
    );
  }

  Widget _transfersList(ColorScheme scheme) {
    if (_transfers.isEmpty) {
      return Center(
        child: Text('Нет подходящих переводов',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: _transfers.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: scheme.outline.withValues(alpha: 0.12),
      ),
      itemBuilder: (_, i) {
        final r = _transfers[i];
        final id = r['id']?.toString() ?? '';
        final selected = _selectedTransferId == id;
        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: scheme.primary.withValues(alpha: 0.1),
          onTap: () => setState(() {
            _selectedTransferId = id;
            _selectedTransferData = r;
          }),
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: scheme.primary.withValues(alpha: 0.12),
            child: Icon(AppIcons.swap_horiz, size: 14, color: scheme.primary),
          ),
          title: Row(
            children: [
              Text(
                r['transaction_code']?.toString() ?? '—',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r['receiver_name']?.toString() ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            '${r['amount']} ${r['currency']} · '
            '${r['from_branch_name'] ?? '—'} · '
            '${(r['status'] ?? '').toString()}',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: selected
              ? Icon(AppIcons.check_circle, size: 18, color: scheme.primary)
              : null,
        );
      },
    );
  }

  Widget _payoutMethodRow() {
    return Row(
      children: [
        const Text('Способ выплаты:', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 4,
            children: _payoutMethods.map((m) {
              final selected = _payoutMethod == m.$1;
              return ChoiceChip(
                selected: selected,
                onSelected: (_) =>
                    setState(() => _payoutMethod = m.$1),
                label:
                    Text(m.$2, style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _dealerToggle(ColorScheme scheme) {
    // Material+InkWell оборачивает строку — тап по тексту тоже
    // переключает (см. _DealerModeToggle из partner_transfer_dialog).
    final radius = BorderRadius.circular(AppSpacing.radiusMd);
    return Material(
      color: _useDealer
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => setState(() => _useDealer = !_useDealer),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 2),
          child: Row(
            children: [
              Switch(
                value: _useDealer,
                onChanged: (v) => setState(() => _useDealer = v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Дилерская модель (spread = buy − sell)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _useDealer ? scheme.primary : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Live-preview саldo «до и после». Доступен только когда выбраны
  /// обе стороны (партнёр и перевод). Сравнивает saldo[currency]
  /// до и после операции — оператор сразу видит сколько партнёр будет
  /// должен в конкретной валюте.
  Widget? _previewBlock() {
    final before = _saldoBefore;
    final delta = _saldoDelta;
    final currency = _previewCurrency;
    if (before == null || delta == null || currency == null) return null;
    final after = before + delta;
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.primary.withValues(alpha: 0.10),
                scheme.primary.withValues(alpha: 0.04),
              ],
            ),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border:
                Border.all(color: scheme.primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.fact_check, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Что произойдёт',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _kv('Сейчас должен',
                  '${before.formatCurrencyNoDecimals()} $currency',
                  highlight: false),
              const SizedBox(height: 2),
              _kv('Изменение',
                  '${delta < 0 ? '' : '+'}${delta.formatCurrencyNoDecimals()} $currency',
                  highlight: false, accent: scheme.error),
              const SizedBox(height: 2),
              _kv('Станет должен',
                  '${after.formatCurrencyNoDecimals()} $currency',
                  highlight: true,
                  accent: after < 0 ? scheme.error : scheme.primary),
            ],
          ),
        );
      },
    );
  }

  Widget _kv(String k, String v,
      {bool highlight = false, Color? accent}) {
    return Builder(builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        children: [
          Expanded(
            child: Text(
              k,
              style:
                  TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            v,
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w700,
              color: accent ?? scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    });
  }
}
