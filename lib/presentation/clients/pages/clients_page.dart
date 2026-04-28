import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:flutter/services.dart';
import 'package:ethnocount/core/utils/phone_country.dart';
import 'package:ethnocount/core/utils/phone_input_formatter.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/clients/bloc/client_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/core/utils/branch_access.dart';

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  String _search = '';
  Client? _selected;

  @override
  void initState() {
    super.initState();
    context.read<ClientBloc>().add(const ClientsLoadRequested());
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ClientBloc, ClientBlocState>(
      listener: (context, state) {
        if (state.status == ClientBlocStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage ?? 'Готово'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          if (state.successMessage?.contains('создан') == true) {
            setState(() => _selected = null);
          }
        }
        if (state.status == ClientBlocStatus.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? 'Ошибка'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      builder: (context, state) {
        if (context.isDesktop) {
          return _DesktopLayout(
            state: state,
            search: _search,
            selected: _selected,
            onSearchChanged: (v) => setState(() => _search = v),
            onSelect: (c) => setState(() => _selected = c),
          );
        }
        return _MobileLayout(
          state: state,
          search: _search,
          onSearchChanged: (v) => setState(() => _search = v),
        );
      },
    );
  }
}

bool _matchesClientSearch(Client c, String search, String q, String qDigits) {
  if (q.isEmpty) return true;
  if (c.name.toLowerCase().contains(q)) return true;
  if (c.counterpartyId.toLowerCase().contains(q)) return true;
  if (c.clientCode.toLowerCase().contains(q)) return true;
  if (c.phone.isNotEmpty && c.phone.contains(search)) return true;
  if (qDigits.isNotEmpty && c.phone.isNotEmpty) {
    final phoneDigits = c.phone.replaceAll(RegExp(r'[^\d]'), '');
    if (phoneDigits.isNotEmpty &&
        (phoneDigits.contains(qDigits) || qDigits.contains(phoneDigits))) {
      return true;
    }
  }
  return false;
}

String _branchLabel(String? branchId, List<Branch> branches) {
  if (branchId == null || branchId.isEmpty) return '—';
  for (final b in branches) {
    if (b.id == branchId) return b.name;
  }
  return '—';
}

List<Widget> _clientBalanceLines(BuildContext context, ClientBalance balance) {
  final keys = balance.balancesByCurrency.keys.toList()..sort();
  if (keys.isEmpty) {
    return [
      Text(
        '${balance.balance.toStringAsFixed(2)} ${balance.currency}',
        style: context.textTheme.titleMedium?.copyWith(
          fontFamily: 'JetBrains Mono',
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      ),
    ];
  }
  return keys.map((cur) {
    final amt = balance.balancesByCurrency[cur] ?? 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '${amt.toStringAsFixed(2)} $cur',
        style: context.textTheme.titleMedium?.copyWith(
          fontFamily: 'JetBrains Mono',
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }).toList();
}

/// Compact one- or two-line balance summary for use in list rows.
/// Hides currencies with zero balance to avoid noise; falls back to the
/// configured wallet currencies when no balance row exists yet.
String _shortBalanceSummary(Client client, ClientBalance? balance) {
  if (balance == null || balance.balancesByCurrency.isEmpty) {
    return '0.00 ${client.currency}';
  }
  final entries = balance.balancesByCurrency.entries
      .where((e) => e.value.abs() > 0.0049)
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  if (entries.isEmpty) {
    // All wallet currencies exist but are zero — show primary as 0.
    return '0.00 ${balance.currency}';
  }
  return entries
      .map((e) => '${e.value.toStringAsFixed(2)} ${e.key}')
      .join(' · ');
}

/// Coloured chip-style label that condenses balances to a single line for
/// data tables. Negative balances are tinted red.
Widget _balancePill(BuildContext context, Client client, ClientBalance? balance) {
  final summary = _shortBalanceSummary(client, balance);
  final isNegative = balance != null &&
      balance.balancesByCurrency.values.any((v) => v < -0.0049);
  final color = balance == null
      ? Theme.of(context).colorScheme.onSurfaceVariant
      : (isNegative ? Colors.red : AppColors.primary);
  return Text(
    summary,
    style: TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: color,
    ),
  );
}

class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({
    required this.state,
    required this.search,
    required this.selected,
    required this.onSearchChanged,
    required this.onSelect,
  });

  final ClientBlocState state;
  final String search;
  final Client? selected;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<Client> onSelect;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final branches =
        filterBranchesByAccess(context.watch<DashboardBloc>().state.branches, user);
    final q = search.toLowerCase().trim();
    final qDigits = search.replaceAll(RegExp(r'[^\d]'), '');
    final filtered = state.clients
        .where((c) => _matchesClientSearch(c, search, q, qDigits))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(),
          const SizedBox(height: AppSpacing.md),
          _SearchBar(onChanged: onSearchChanged),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Client table
                Expanded(
                  flex: 3,
                  child: _ClientTable(
                    clients: filtered,
                    branches: branches,
                    balancesByClientId: state.balancesByClientId,
                    selected: selected,
                    onSelect: onSelect,
                    isLoading: state.status == ClientBlocStatus.loading,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                // Detail panel
                SizedBox(
                  width: 340,
                  child: selected != null
                      ? _ClientDetailPanel(
                          client: selected!,
                          branches: branches,
                          state: state,
                        )
                      : const _EmptyDetailPanel(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.state,
    required this.search,
    required this.onSearchChanged,
  });

  final ClientBlocState state;
  final String search;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final branches =
        filterBranchesByAccess(context.watch<DashboardBloc>().state.branches, user);
    final q = search.toLowerCase().trim();
    final qDigits = search.replaceAll(RegExp(r'[^\d]'), '');
    final filtered = state.clients
        .where((c) => _matchesClientSearch(c, search, q, qDigits))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Клиенты')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context),
        icon: const Icon(Icons.person_add_rounded),
        label: const Text('Добавить'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: _SearchBar(onChanged: onSearchChanged),
          ),
          Expanded(
            child: filtered.isEmpty &&
                    state.status != ClientBlocStatus.loading
                ? const EmptyState(
                    icon: Icons.people_outline_rounded,
                    title: 'Клиенты не найдены',
                    subtitle:
                        'Нет клиентов по текущему поиску. Очистите запрос или добавьте нового клиента.',
                  )
                : RefreshIndicator(
                    onRefresh: () async {
                      context
                          .read<ClientBloc>()
                          .add(const ClientsLoadRequested());
                    },
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final client = filtered[i];
                        final branchName =
                            _branchLabel(client.branchId, branches);
                        final balance = state.balancesByClientId[client.id];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(client.name[0].toUpperCase()),
                          ),
                          title: Text(
                            client.name,
                            style: const TextStyle(fontSize: 15),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${client.counterpartyId} • ${client.phone}',
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                branchName,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              _balancePill(context, client, balance),
                            ],
                          ),
                          isThreeLine: true,
                          onTap: () => _showDetailSheet(context, client),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _showDetailSheet(BuildContext context, Client client) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: context.read<ClientBloc>(),
        child: DraggableScrollableSheet(
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          expand: false,
          builder: (_, ctrl) => SingleChildScrollView(
            controller: ctrl,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: _ClientActions(client: client),
          ),
        ),
      ),
    );
  }
}

void _showCreateDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => BlocProvider.value(
      value: context.read<ClientBloc>(),
      child: const _CreateClientDialog(),
    ),
  );
}

// ─── Header ───

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Клиентские счета',
                style: context.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                'Управление счетами клиентов компании',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: () => _showCreateDialog(context),
          icon: const Icon(Icons.person_add_rounded),
          label: const Text('Добавить клиента'),
        ),
      ],
    );
  }
}

// ─── Search Bar ───

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Поиск по имени, коду, телефону...',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: AppSpacing.md),
        ),
      ),
    );
  }
}

// ─── Client Table ───

class _ClientTable extends StatelessWidget {
  const _ClientTable({
    required this.clients,
    required this.branches,
    required this.balancesByClientId,
    required this.selected,
    required this.onSelect,
    required this.isLoading,
  });

  final List<Client> clients;
  final List<Branch> branches;
  final Map<String, ClientBalance> balancesByClientId;
  final Client? selected;
  final ValueChanged<Client> onSelect;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (clients.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline,
                size: 48,
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary),
            const SizedBox(height: AppSpacing.md),
            Text('Клиенты не найдены',
                style: context.textTheme.bodyLarge?.copyWith(
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                )),
          ],
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 20,
          headingRowColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: const [
            DataColumn(label: Text('ID контрагента')),
            DataColumn(label: Text('Имя клиента')),
            DataColumn(label: Text('Телефон')),
            DataColumn(label: Text('Страна')),
            DataColumn(label: Text('Филиал')),
            DataColumn(label: Text('Баланс')),
            DataColumn(label: Text('Статус')),
          ],
          rows: clients.map((client) {
            final isSelected = selected?.id == client.id;
            final balance = balancesByClientId[client.id];
            return DataRow(
              selected: isSelected,
              onSelectChanged: (_) => onSelect(client),
              cells: [
                DataCell(
                  Text(
                    client.counterpartyId,
                    style: const TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 12,
                    ),
                  ),
                ),
                DataCell(
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                        child: Text(
                          client.name[0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(client.name),
                    ],
                  ),
                ),
                DataCell(Text(client.phone)),
                DataCell(Text(client.country.isEmpty ? '—' : client.country)),
                DataCell(Text(_branchLabel(client.branchId, branches))),
                DataCell(_balancePill(context, client, balance)),
                DataCell(
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: client.isActive
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      client.isActive ? 'Активен' : 'Неактивен',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: client.isActive ? Colors.green : Colors.red,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ─── Detail Panel ───

class _ClientDetailPanel extends StatefulWidget {
  const _ClientDetailPanel({
    required this.client,
    required this.branches,
    required this.state,
  });
  final Client client;
  final List<Branch> branches;
  final ClientBlocState state;

  @override
  State<_ClientDetailPanel> createState() => _ClientDetailPanelState();
}

class _ClientDetailPanelState extends State<_ClientDetailPanel> {
  @override
  void initState() {
    super.initState();
    context
        .read<ClientBloc>()
        .add(ClientDetailRequested(widget.client.id));
  }

  @override
  void didUpdateWidget(_ClientDetailPanel old) {
    super.didUpdateWidget(old);
    if (old.client.id != widget.client.id) {
      context
          .read<ClientBloc>()
          .add(ClientDetailRequested(widget.client.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = widget.state.selectedClient?.id == widget.client.id
        ? widget.state.selectedBalance
        : null;
    final transactions =
        widget.state.selectedClient?.id == widget.client.id
            ? widget.state.transactions
            : <ClientTransaction>[];

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Client info
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  child: Text(
                    widget.client.name[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.client.name,
                          style: context.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        widget.client.counterpartyId,
                        style: const TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        'Филиал: ${_branchLabel(widget.client.branchId, widget.branches)}',
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Balance card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.1),
                    AppColors.primary.withValues(alpha: 0.05),
                  ],
                ),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Балансы',
                    style: context.textTheme.labelSmall?.copyWith(
                      color: context.isDark
                          ? AppColors.darkTextSecondary
                          : AppColors.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (balance == null)
                    Text(
                      '—',
                      style: context.textTheme.headlineSmall?.copyWith(
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    )
                  else
                    ..._clientBalanceLines(context, balance),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Actions
            _ClientActions(client: widget.client),

            const Divider(height: AppSpacing.xl),

            Text('Последние операции',
                style: context.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),

            Expanded(
              child: transactions.isEmpty
                  ? const Center(child: Text('Нет операций'))
                  : ListView.separated(
                      itemCount: transactions.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final tx = transactions[i];
                        final isDeposit = tx.isDeposit;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isDeposit
                                ? Icons.arrow_downward_rounded
                                : Icons.arrow_upward_rounded,
                            color: isDeposit ? Colors.green : Colors.red,
                            size: 18,
                          ),
                          title: Text(
                            tx.description ?? tx.type,
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: Text(
                            '${isDeposit ? '+' : '-'}${tx.amount.toStringAsFixed(2)} ${tx.currency}',
                            style: TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDeposit ? Colors.green : Colors.red,
                            ),
                          ),
                          subtitle: Text(
                            _formatDate(tx.createdAt),
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _EmptyDetailPanel extends StatelessWidget {
  const _EmptyDetailPanel();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_search_rounded,
                size: 48,
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Выберите клиента',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Client Actions (Deposit / Debit) ───

class _ClientActions extends StatelessWidget {
  const _ClientActions({required this.client});
  final Client client;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showOperationDialog(context, isDeposit: true),
            icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
            label: const Text('Пополнить'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.green),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showOperationDialog(context, isDeposit: false),
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
            label: const Text('Списать'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ),
      ],
    );
  }

  void _showOperationDialog(BuildContext context, {required bool isDeposit}) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<ClientBloc>(),
        child: _TransactionDialog(client: client, isDeposit: isDeposit),
      ),
    );
  }
}

// ─── Transaction Dialog ───

class _TransactionDialog extends StatefulWidget {
  const _TransactionDialog({
    required this.client,
    required this.isDeposit,
  });
  final Client client;
  final bool isDeposit;

  @override
  State<_TransactionDialog> createState() => _TransactionDialogState();
}

class _TransactionDialogState extends State<_TransactionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  late String _opCurrency;

  static const _currencyChoices = [
    'USD', 'USDT', 'EUR', 'RUB', 'UZS', 'TRY', 'AED', 'CNY', 'KZT', 'KGS', 'TJS',
  ];

  @override
  void initState() {
    super.initState();
    _opCurrency = widget.client.walletCurrencies.isNotEmpty
        ? widget.client.walletCurrencies.first
        : widget.client.currency;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isDeposit ? 'Пополнение счёта' : 'Списание со счёта';
    final color = widget.isDeposit ? Colors.green : Colors.red;

    return BlocListener<ClientBloc, ClientBlocState>(
      listener: (context, state) {
        if (state.status == ClientBlocStatus.success ||
            state.status == ClientBlocStatus.error) {
          Navigator.of(context).pop();
        }
      },
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              widget.isDeposit
                  ? Icons.add_circle_outline_rounded
                  : Icons.remove_circle_outline_rounded,
              color: color,
            ),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Form(
          key: _formKey,
          child: BlocBuilder<ClientBloc, ClientBlocState>(
            builder: (context, st) {
              final bal = st.selectedClient?.id == widget.client.id
                  ? st.selectedBalance
                  : null;
              final fromBal = bal?.balancesByCurrency.keys ?? const <String>[];
              final opts = <String>{
                ...widget.client.walletCurrencies,
                widget.client.currency,
                ...fromBal,
                ..._currencyChoices,
              }.toList()
                ..sort();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              Text(
                'Клиент: ${widget.client.name}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                value: _opCurrency,
                decoration: const InputDecoration(
                  labelText: 'Валюта операции',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.currency_exchange_outlined),
                ),
                items: opts
                    .map((c) =>
                        DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _opCurrency = v);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _amountCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Сумма',
                  suffixText: _opCurrency,
                  border: const OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Введите сумму';
                  if ((double.tryParse(v) ?? 0) <= 0) return 'Сумма > 0';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)',
                  border: OutlineInputBorder(),
                ),
              ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          BlocBuilder<ClientBloc, ClientBlocState>(
            builder: (context, state) {
              final isLoading =
                  state.status == ClientBlocStatus.operating;
              return FilledButton(
                onPressed: isLoading ? null : _submit,
                style:
                    FilledButton.styleFrom(backgroundColor: color),
                child: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(widget.isDeposit ? 'Пополнить' : 'Списать'),
              );
            },
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amountCtrl.text);
    final desc =
        _descCtrl.text.isEmpty ? null : _descCtrl.text;

    if (widget.isDeposit) {
      context.read<ClientBloc>().add(ClientDepositRequested(
            clientId: widget.client.id,
            amount: amount,
            description: desc,
            currency: _opCurrency,
          ));
    } else {
      context.read<ClientBloc>().add(ClientDebitRequested(
            clientId: widget.client.id,
            amount: amount,
            description: desc,
            currency: _opCurrency,
          ));
    }
  }
}

// ─── Create Client Dialog ───

class _CreateClientDialog extends StatefulWidget {
  const _CreateClientDialog();

  @override
  State<_CreateClientDialog> createState() => _CreateClientDialogState();
}

class _CreateClientDialogState extends State<_CreateClientDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  String _currency = 'USD';
  String? _branchId;
  CountryMatch? _detectedCountry;

  static const _currencies = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'TRY', 'AED', 'CNY', 'KZT', 'KGS', 'TJS'];

  @override
  void initState() {
    super.initState();
    _phoneCtrl.addListener(_onPhoneChanged);
  }

  void _onPhoneChanged() {
    final match = PhoneCountryDetector.detect(_phoneCtrl.text);
    if (match?.countryCode != _detectedCountry?.countryCode) {
      setState(() {
        _detectedCountry = match;
        if (match != null) {
          _countryCtrl.text = match.countryName;
        }
      });
    }
  }

  @override
  void dispose() {
    _phoneCtrl.removeListener(_onPhoneChanged);
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final branches =
        filterBranchesByAccess(context.watch<DashboardBloc>().state.branches, user);
    final effectiveBranchId =
        _branchId ?? (branches.length == 1 ? branches.first.id : null);

    return BlocListener<ClientBloc, ClientBlocState>(
      listener: (context, state) {
        if (state.status == ClientBlocStatus.success ||
            state.status == ClientBlocStatus.error) {
          Navigator.of(context).pop();
        }
      },
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.person_add_rounded),
            SizedBox(width: 8),
            Text('Новый клиент'),
          ],
        ),
        content: Form(
          key: _formKey,
          child: SizedBox(
            width: context.isDesktop ? 420 : double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Полное имя *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Введите имя' : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _phoneCtrl,
                  decoration: InputDecoration(
                    labelText: 'Телефон *',
                    border: const OutlineInputBorder(),
                    prefixIcon: _detectedCountry != null
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: CountryBadge(match: _detectedCountry!, size: 24),
                          )
                        : const Icon(Icons.phone_outlined),
                    suffixIcon: _detectedCountry != null
                        ? Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Chip(
                              label: Text(
                                _detectedCountry!.countryName,
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          )
                        : null,
                    hintText: '+998 90 123 45 67',
                  ),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    PhoneInputFormatter(),
                    LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
                  ],
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Введите телефон';
                    final digits = v.replaceAll(RegExp(r'[^\d]'), '');
                    if (digits.length < 10) return 'Номер слишком короткий (мин. 10 цифр)';
                    if (digits.length > kPhoneMaxDigits) return 'Номер слишком длинный (макс. $kPhoneMaxDigits цифр)';
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _countryCtrl,
                  decoration: InputDecoration(
                    labelText: 'Страна',
                    border: const OutlineInputBorder(),
                    prefixIcon: _detectedCountry != null
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: CountryBadge(match: _detectedCountry!, size: 24),
                          )
                        : const Icon(Icons.flag_outlined),
                    helperText: _detectedCountry != null
                        ? 'Определено по номеру телефона'
                        : null,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (branches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      'Нет доступных филиалов. Клиента можно создать после назначения филиала.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    value: effectiveBranchId != null &&
                            branches.any((b) => b.id == effectiveBranchId)
                        ? effectiveBranchId
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Филиал *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.account_tree_outlined),
                    ),
                    items: branches
                        .map((b) => DropdownMenuItem(
                              value: b.id,
                              child: Text(b.name),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _branchId = v),
                    validator: (_) => effectiveBranchId == null
                        ? 'Выберите филиал'
                        : null,
                  ),
                const SizedBox(height: AppSpacing.sm),
                DropdownButtonFormField<String>(
                  key: ValueKey('client-curr-$_currency'),
                  value: _currency,
                  decoration: const InputDecoration(
                    labelText: 'Основная валюта *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.currency_exchange_outlined),
                  ),
                  items: _currencies
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _currency = v ?? 'USD'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          BlocBuilder<ClientBloc, ClientBlocState>(
            builder: (context, state) {
              final isLoading =
                  state.status == ClientBlocStatus.operating;
              return FilledButton.icon(
                onPressed:
                    (isLoading || branches.isEmpty) ? null : _submit,
                icon: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Создать'),
              );
            },
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final user = context.read<AuthBloc>().state.user;
    final branches = filterBranchesByAccess(
      context.read<DashboardBloc>().state.branches,
      user,
    );
    final bid =
        _branchId ?? (branches.length == 1 ? branches.first.id : null);
    if (bid == null || bid.isEmpty) return;
    context.read<ClientBloc>().add(ClientCreateRequested(
          name: _nameCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          country: _countryCtrl.text.trim(),
          currency: _currency,
          branchId: bid,
        ));
  }
}
