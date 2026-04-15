import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/bank_import/bloc/bank_import_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';

class BankImportPage extends StatefulWidget {
  const BankImportPage({super.key});

  @override
  State<BankImportPage> createState() => _BankImportPageState();
}

class _BankImportPageState extends State<BankImportPage> {
  String? _selectedBranchId;
  String? _selectedAccountId;
  final _categoryCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();

  @override
  void dispose() {
    _categoryCtrl.dispose();
    _bankNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.bytes == null) return;

    if (!mounted) return;
    context.read<BankImportBloc>().add(BankImportFilePicked(
          file.path ?? 'file',
          file.bytes!,
          bankName: _bankNameCtrl.text.trim().isEmpty ? null : _bankNameCtrl.text.trim(),
        ));
  }

  void _doImport() {
    final user = context.read<AuthBloc>().state.user;
    if (user == null || _selectedBranchId == null || _selectedAccountId == null) return;

    context.read<BankImportBloc>().add(BankImportExecute(
          branchId: _selectedBranchId!,
          accountId: _selectedAccountId!,
          createdBy: user.id,
          category: _categoryCtrl.text.trim().isEmpty ? null : _categoryCtrl.text.trim(),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final dashState = context.watch<DashboardBloc>().state;
    final user = context.watch<AuthBloc>().state.user;
    final branches = filterBranchesByAccess(dashState.branches, user);
    final accounts = _selectedBranchId != null
        ? (dashState.branchAccounts[_selectedBranchId] ?? [])
        : <BranchAccount>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Импорт из банка'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/ledger'),
        ),
      ),
      body: BlocConsumer<BankImportBloc, BankImportState>(
        listener: (context, state) {
          if (state.status == BankImportStatus.success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Импортировано ${state.importedCount} операций'),
                backgroundColor: Colors.green,
              ),
            );
            context.go('/ledger');
          }
          if (state.status == BankImportStatus.error) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.errorMessage ?? 'Ошибка'),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
        builder: (context, state) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '1. Выберите файл выписки',
                          style: context.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Поддерживаются CSV и Excel (Сбербанк, Альфа-Банк, Тинькофф и др.)',
                          style: context.textTheme.bodySmall?.copyWith(
                            color: context.isDark
                                ? AppColors.darkTextSecondary
                                : AppColors.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _bankNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Банк (опционально)',
                            hintText: 'Сбербанк, Альфа-Банк...',
                            prefixIcon: Icon(Icons.account_balance),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: state.status == BankImportStatus.importing
                              ? null
                              : _pickFile,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Выбрать файл'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (state.transactions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '2. Настройка импорта',
                                style: context.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${state.transactions.length} операций',
                                style: context.textTheme.bodySmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            value: _selectedBranchId,
                            decoration: const InputDecoration(
                              labelText: 'Филиал',
                              prefixIcon: Icon(Icons.business),
                            ),
                            items: branches
                                .map((b) => DropdownMenuItem(
                                      value: b.id,
                                      child: Text(b.name),
                                    ))
                                .toList(),
                            onChanged: (v) {
                              setState(() {
                                _selectedBranchId = v;
                                _selectedAccountId = null;
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: _selectedAccountId,
                            decoration: const InputDecoration(
                              labelText: 'Счёт/карта',
                              prefixIcon: Icon(Icons.credit_card),
                            ),
                            items: accounts
                                .map((a) => DropdownMenuItem(
                                      value: a.id,
                                      child: Text('${a.name} (${a.type.displayName})'),
                                    ))
                                .toList(),
                            onChanged: (v) => setState(() => _selectedAccountId = v),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _categoryCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Категория (опционально)',
                              hintText: 'Например: Закупки, Аренда',
                              prefixIcon: Icon(Icons.category_outlined),
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: state.status == BankImportStatus.importing ||
                                    _selectedBranchId == null ||
                                    _selectedAccountId == null
                                ? null
                                : _doImport,
                            icon: state.status == BankImportStatus.importing
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.check),
                            label: Text(
                              state.status == BankImportStatus.importing
                                  ? 'Импорт...'
                                  : 'Импортировать',
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Text(
                            'Предпросмотр',
                            style: context.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('Дата')),
                              DataColumn(label: Text('Сумма')),
                              DataColumn(label: Text('Описание')),
                              DataColumn(label: Text('Тип')),
                            ],
                            rows: state.transactions.take(20).map((tx) {
                              return DataRow(
                                cells: [
                                  DataCell(Text(tx.date.formatted)),
                                  DataCell(Text(
                                    tx.amount.withCurrency(tx.currency),
                                    style: TextStyle(
                                      color: tx.isCredit ? Colors.green : Colors.red,
                                    ),
                                  )),
                                  DataCell(Text(
                                    tx.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  )),
                                  DataCell(Text(tx.isCredit ? 'Поступление' : 'Списание')),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                        if (state.transactions.length > 20)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              '... и ещё ${state.transactions.length - 20}',
                              style: context.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
