import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  final _exportService = sl<ServerExportService>();
  bool _isExporting = false;
  String? _selectedBranch;
  DateTimeRange? _dateRange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branches = context.select<DashboardBloc, List<(String, String)>>(
      (bloc) => bloc.state.branches.map((b) => (b.id, b.name)).toList(),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Отчёты и экспорт')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Параметры', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('rep-branch-$_selectedBranch'),
                    initialValue: _selectedBranch,
                    decoration: const InputDecoration(
                      labelText: 'Филиал',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Все')),
                      ...branches.map(
                        (b) => DropdownMenuItem(
                          value: b.$1,
                          child: Text(b.$2),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _selectedBranch = v),
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: InkWell(
                    onTap: _pickDateRange,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Период',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.date_range),
                      ),
                      child: Text(
                        _dateRange != null
                            ? '${_fmt(_dateRange!.start)} — ${_fmt(_dateRange!.end)}'
                            : 'Все время',
                      ),
                    ),
                  ),
                ),
                if (_dateRange != null)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Сбросить период',
                    onPressed: () => setState(() => _dateRange = null),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            if (_isExporting)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: AppSpacing.md),
                      Text('Генерация отчёта...'),
                    ],
                  ),
                ),
              ),
            Text('Доступные отчёты', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.receipt_long,
              title: 'Журнал операций (Ledger)',
              description: 'Полный журнал дебетовых и кредитовых записей по филиалу',
              requiresBranch: true,
              isEnabled: _selectedBranch != null && !_isExporting,
              onExport: () => _export('ledger'),
            ),
            _ReportCard(
              icon: Icons.swap_horiz,
              title: 'История переводов',
              description: 'Все переводы с деталями: суммы, курсы, комиссии, статусы',
              requiresBranch: false,
              isEnabled: !_isExporting,
              onExport: () => _export('transfers'),
            ),
            _ReportCard(
              icon: Icons.payments,
              title: 'Отчёт по комиссиям',
              description: 'Все комиссии с привязкой к переводам',
              requiresBranch: false,
              isEnabled: !_isExporting,
              onExport: () => _export('commissions'),
            ),
            _ReportCard(
              icon: Icons.summarize,
              title: 'Ежемесячный финансовый отчёт',
              description: 'Итоги по счетам: дебет, кредит, нетто, количество операций',
              requiresBranch: true,
              isEnabled: _selectedBranch != null && !_isExporting,
              onExport: () => _export('monthly_summary'),
            ),
          ],
        ),
      ),
    );
  }

  static const _reportNames = {
    'ledger': 'Журнал операций',
    'transfers': 'История переводов',
    'commissions': 'Отчёт по комиссиям',
    'monthly_summary': 'Ежемесячный отчёт',
  };

  Future<void> _export(String type) async {
    setState(() => _isExporting = true);
    final reportName = _reportNames[type] ?? type;
    try {
      final url = await _exportService.exportReport(
        reportType: type,
        branchId: _selectedBranch,
        startDate: _dateRange?.start,
        endDate: _dateRange?.end,
      );
      if (mounted) {
        final isLocal = url == 'local';
        final period = _dateRange != null
            ? ' ${_fmt(_dateRange!.start)}–${_fmt(_dateRange!.end)}'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(url != null
                ? (isLocal
                    ? 'Скачан: $reportName$period'
                    : 'Скачивание: $reportName$period (Excel)')
                : 'Нет данных для отчёта «$reportName»'),
            backgroundColor: url != null ? Colors.green.shade700 : Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка экспорта: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
    );
    if (picked != null) setState(() => _dateRange = picked);
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

class _ReportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool requiresBranch;
  final bool isEnabled;
  final VoidCallback onExport;

  const _ReportCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.requiresBranch,
    required this.isEnabled,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isEnabled
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(icon,
              color: isEnabled
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant),
        ),
        title: Text(title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description),
            if (requiresBranch && !isEnabled)
              Text('Выберите филиал',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  )),
          ],
        ),
        trailing: FilledButton.tonalIcon(
          onPressed: isEnabled ? onExport : null,
          icon: const Icon(Icons.download),
          label: const Text('Excel'),
        ),
      ),
    );
  }
}
