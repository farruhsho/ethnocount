import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';

/// F4 (AML/KYC). Панель для Creator/Director: настройка порогов
/// (идентификация / крупная разовая / суточный и месячный лимиты по
/// валютам) и просмотр/закрытие журнала флагов.
///
/// Всё через RPC из миграций 061/062. Сервер сам проверяет роль —
/// бухгалтер сюда не попадёт даже если откроет.
Future<void> showAmlControlSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: _AmlControlPanel(),
    ),
  );
}

class _AmlControlPanel extends StatefulWidget {
  const _AmlControlPanel();

  @override
  State<_AmlControlPanel> createState() => _AmlControlPanelState();
}

class _AmlControlPanelState extends State<_AmlControlPanel> {
  bool _loading = true;
  bool _saving = false;
  String? _error;

  final List<_ThrRow> _rows = [];
  List<Map<String, dynamic>> _flags = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final settings = await client
          .rpc('aml_get_settings')
          .timeout(const Duration(seconds: 12));
      final flags = await client
          .rpc('aml_flags_list', params: {'p_limit': 200})
          .timeout(const Duration(seconds: 12));

      for (final r in _rows) {
        r.dispose();
      }
      _rows.clear();
      _rows.addAll(_rowsFromSettings(settings));
      _flags = (flags as List)
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _loading = false;
        _error = s.contains('42883') || s.contains('PGRST202')
            ? 'Примените миграции 061 и 062 (AML/KYC).'
            : (s.contains('authenticated') || s.contains('Creator/Director')
                ? 'Доступно только Creator/Director.'
                : 'Не удалось загрузить: $s');
      });
    }
  }

  List<_ThrRow> _rowsFromSettings(dynamic settings) {
    Map<String, double> pick(String key) {
      final out = <String, double>{};
      if (settings is Map && settings[key] is Map) {
        (settings[key] as Map).forEach((k, v) {
          final d = double.tryParse(v.toString());
          if (d != null) out[k.toString().toUpperCase()] = d;
        });
      }
      return out;
    }

    final idReq = pick('idRequiredByCurrency');
    final review = pick('singleTxReviewByCurrency');
    final daily = pick('dailyLimitByCurrency');
    final monthly = pick('monthlyLimitByCurrency');
    final currencies = <String>{
      ...idReq.keys,
      ...review.keys,
      ...daily.keys,
      ...monthly.keys,
    }.toList()
      ..sort();
    return [
      for (final c in currencies)
        _ThrRow(c, idReq[c], review[c], daily[c], monthly[c]),
    ];
  }

  void _addCurrency() async {
    final used = _rows.map((r) => r.currency).toSet();
    final available =
        CurrencyUtils.supported.where((c) => !used.contains(c)).toList();
    if (available.isEmpty) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Валюта для лимитов'),
        children: [
          for (final c in available)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Text('${CurrencyUtils.flag(c)}  $c'),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _rows.add(_ThrRow(picked, null, null, null, null)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final idReq = <String, double>{};
    final review = <String, double>{};
    final daily = <String, double>{};
    final monthly = <String, double>{};
    for (final r in _rows) {
      final cur = r.currency.toUpperCase();
      void put(Map<String, double> m, TextEditingController c) {
        final d = double.tryParse(c.text.trim().replaceAll(',', '.'));
        if (d != null && d > 0) m[cur] = d;
      }

      put(idReq, r.idReq);
      put(review, r.review);
      put(daily, r.daily);
      put(monthly, r.monthly);
    }
    try {
      await Supabase.instance.client.rpc('aml_update_settings', params: {
        'p_id_required_by_currency': idReq,
        'p_single_tx_review_by_currency': review,
        'p_daily_limit_by_currency': daily,
        'p_monthly_limit_by_currency': monthly,
      }).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Пороги AML сохранены'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() => _saving = false);
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не сохранилось: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _resolve(String id, String status) async {
    try {
      await Supabase.instance.client.rpc('aml_resolve_flag', params: {
        'p_flag_id': id,
        'p_status': status,
      }).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не удалось обновить флаг: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final openCount =
        _flags.where((f) => (f['status'] ?? 'open') == 'open').length;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
      child: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  const Icon(AppIcons.shield, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'AML / KYC контроль',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Обновить',
                    icon: const Icon(AppIcons.refresh, size: 18),
                    onPressed: _loading ? null : _loadAll,
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(AppIcons.close, size: 18),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            TabBar(
              tabs: [
                const Tab(text: 'Пороги'),
                Tab(text: openCount > 0 ? 'Флаги ($openCount)' : 'Флаги'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _ErrorBox(message: _error!, onRetry: _loadAll)
                      : TabBarView(
                          children: [
                            _buildThresholds(),
                            _buildFlags(),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThresholds() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              const Text(
                'Пороги — это предупреждения при создании перевода. '
                'Они ничего не блокируют: оператор видит флаг и решает сам. '
                'Значение 0 / пусто = порога нет.',
                style: TextStyle(fontSize: 11.5, color: AppColors.darkTextSecondary),
              ),
              const SizedBox(height: 12),
              if (_rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Лимиты не заданы.\nДобавьте валюту ниже.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.darkTextTertiary),
                    ),
                  ),
                ),
              for (final row in _rows)
                _ThresholdCard(
                  row: row,
                  onRemove: () => setState(() {
                    row.dispose();
                    _rows.remove(row);
                  }),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addCurrency,
                  icon: const Icon(AppIcons.add, size: 18),
                  label: const Text('Добавить валюту'),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.check, size: 18),
              label: Text(_saving ? 'Сохранение…' : 'Сохранить пороги'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFlags() {
    if (_flags.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Флагов пока нет.',
            style: TextStyle(color: AppColors.darkTextTertiary),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: _flags.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _FlagTile(
        flag: _flags[i],
        onResolve: (status) => _resolve(_flags[i]['id'].toString(), status),
      ),
    );
  }
}

class _ThresholdCard extends StatelessWidget {
  const _ThresholdCard({required this.row, required this.onRemove});

  final _ThrRow row;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${CurrencyUtils.flag(row.currency)}  ${row.currency}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Убрать валюту',
                icon: const Icon(AppIcons.close, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: _numField('Док. с суммы', row.idReq)),
              const SizedBox(width: 8),
              Expanded(child: _numField('Крупная разовая', row.review)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _numField('Лимит / сутки', row.daily)),
              const SizedBox(width: 8),
              Expanded(child: _numField('Лимит / месяц', row.monthly)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
    );
  }
}

class _FlagTile extends StatelessWidget {
  const _FlagTile({required this.flag, required this.onResolve});

  final Map<String, dynamic> flag;
  final void Function(String status) onResolve;

  @override
  Widget build(BuildContext context) {
    final status = (flag['status'] ?? 'open').toString();
    final severity = (flag['severity'] ?? 'medium').toString();
    final sevColor = severity == 'high'
        ? AppColors.error
        : severity == 'low'
            ? AppColors.info
            : AppColors.warning;
    final statusColor = status == 'cleared'
        ? AppColors.success
        : status == 'reviewed'
            ? AppColors.info
            : AppColors.warning;
    final amount = double.tryParse('${flag['amount']}');
    final cur = (flag['currency'] ?? '').toString();
    final phone = (flag['subject_phone'] ?? '').toString();
    final name = (flag['subject_name'] ?? '').toString();
    final code = (flag['transaction_code'] ?? '').toString();
    final createdRaw = flag['created_at']?.toString();
    String when = '';
    if (createdRaw != null) {
      final dt = DateTime.tryParse(createdRaw);
      if (dt != null) when = DateFormat('dd.MM HH:mm').format(dt.toLocal());
    }
    final warnings = <String>[];
    final details = flag['details'];
    if (details is Map && details['warnings'] is List) {
      for (final w in (details['warnings'] as List)) {
        warnings.add(w.toString());
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: sevColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  severity.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: sevColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  (flag['flag_type'] ?? '').toString(),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                status,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (name.isNotEmpty) name,
              if (phone.isNotEmpty) phone,
              if (amount != null && amount > 0)
                '${amount.toStringAsFixed(amount % 1 == 0 ? 0 : 2)} $cur',
              if (code.isNotEmpty) code,
              if (when.isNotEmpty) when,
            ].join(' · '),
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.darkTextSecondary),
          ),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '• $w',
                style: const TextStyle(fontSize: 11, color: AppColors.warning),
              ),
            ),
          if (status == 'open')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => onResolve('reviewed'),
                    child: const Text('Проверено'),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => onResolve('cleared'),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.success),
                    child: const Text('Снять'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.error_outline, color: AppColors.error),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(AppIcons.refresh, size: 18),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThrRow {
  _ThrRow(
    this.currency,
    double? idReq,
    double? review,
    double? daily,
    double? monthly,
  )   : idReq = TextEditingController(text: _fmt(idReq)),
        review = TextEditingController(text: _fmt(review)),
        daily = TextEditingController(text: _fmt(daily)),
        monthly = TextEditingController(text: _fmt(monthly));

  final String currency;
  final TextEditingController idReq;
  final TextEditingController review;
  final TextEditingController daily;
  final TextEditingController monthly;

  static String _fmt(double? v) {
    if (v == null || v <= 0) return '';
    return v % 1 == 0 ? v.toStringAsFixed(0) : v.toString();
  }

  void dispose() {
    idReq.dispose();
    review.dispose();
    daily.dispose();
    monthly.dispose();
  }
}
