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
import 'package:ethnocount/presentation/clients/widgets/client_detail_screen.dart';
import 'package:ethnocount/presentation/clients/widgets/clients_list_pane.dart';
import 'package:ethnocount/presentation/clients/widgets/convert_currency_dialog.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/core/utils/branch_access.dart';

import 'package:ethnocount/core/icons/app_icons.dart';
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
        if (context.isDesktop && context.isDark) {
          return _DesktopHeroLayout(
            state: state,
            selected: _selected,
            onSelect: (c) => setState(() => _selected = c),
          );
        }
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

// ─── Desktop hero (dark, design-spec list pane) ───

class _DesktopHeroLayout extends StatelessWidget {
  const _DesktopHeroLayout({
    required this.state,
    required this.selected,
    required this.onSelect,
  });

  final ClientBlocState state;
  final Client? selected;
  final ValueChanged<Client> onSelect;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final allBranches =
        filterBranchesByAccess(context.watch<DashboardBloc>().state.branches, user);
    final allowed = accessibleBranchIds(user); // null = creator/director
    final clients = state.clients
        .where((c) =>
            allowed == null ||
            c.branchId == null ||
            allowed.contains(c.branchId))
        .toList();

    // Sum of USD balances only (no async FX) — safe lower bound for the
    // "USD-экв." mini-stat tile.
    double totalUsd = 0;
    for (final c in clients) {
      final bal = state.balancesByClientId[c.id];
      if (bal == null) continue;
      final usdInWallet = bal.balancesByCurrency['USD'];
      if (usdInWallet != null) {
        totalUsd += usdInWallet;
      } else if (bal.currency == 'USD') {
        totalUsd += bal.balance;
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 380,
          child: ClientsListPane(
            clients: clients,
            balances: state.balancesByClientId,
            selectedId: selected?.id,
            onSelect: onSelect,
            canCreate: true,
            onCreate: () => _showCreateDialog(context),
            totalUsdEquivalent: totalUsd,
          ),
        ),
        Expanded(
          child: Container(
            color: AppColors.darkBg,
            child: selected == null
                ? _emptyDetail(context)
                : _ClientDetailPanel(
                    client: selected!,
                    branches: allBranches,
                    state: state,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _emptyDetail(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.person_outline,
                size: 48, color: AppColors.darkTextDisabled),
            const SizedBox(height: 14),
            Text(
              'Выберите клиента',
              style: context.textTheme.titleMedium?.copyWith(
                color: AppColors.darkTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Слева — список ваших контрагентов с балансами и фильтрами.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    final allowed = accessibleBranchIds(user); // null = creator/director
    final q = search.toLowerCase().trim();
    final qDigits = search.replaceAll(RegExp(r'[^\d]'), '');
    final filtered = state.clients
        .where((c) =>
            (allowed == null ||
                c.branchId == null ||
                allowed.contains(c.branchId)) &&
            _matchesClientSearch(c, search, q, qDigits))
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
            // Master-detail: пока никого не выбрано — список занимает всю
            // ширину; как только пользователь выбрал клиента, между списком
            // и detail-панелью появляется draggable-divider — оператор сам
            // настраивает удобную ширину колонки (см. [_ResizableMasterDetail]).
            child: selected == null
                ? _ClientTable(
                    clients: filtered,
                    branches: branches,
                    balancesByClientId: state.balancesByClientId,
                    selected: selected,
                    onSelect: onSelect,
                    isLoading: state.status == ClientBlocStatus.loading,
                    compact: false,
                  )
                : _ResizableMasterDetail(
                    master: _ClientTable(
                      clients: filtered,
                      branches: branches,
                      balancesByClientId: state.balancesByClientId,
                      selected: selected,
                      onSelect: onSelect,
                      isLoading: state.status == ClientBlocStatus.loading,
                      compact: true,
                    ),
                    detail: _ClientDetailPanel(
                      client: selected!,
                      branches: branches,
                      state: state,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Master-detail с draggable-divider'ом. Оператор сам ставит удобную
/// ширину левой колонки; значение хранится в state виджета (живёт пока
/// открыт экран клиентов — для большего нужен UserPrefs).
class _ResizableMasterDetail extends StatefulWidget {
  const _ResizableMasterDetail({
    required this.master,
    required this.detail,
  });

  final Widget master;
  final Widget detail;

  @override
  State<_ResizableMasterDetail> createState() => _ResizableMasterDetailState();
}

class _ResizableMasterDetailState extends State<_ResizableMasterDetail> {
  static const double _minMaster = 280;
  static const double _minDetail = 420;
  static const double _initial = 380;
  static const double _handleWidth = 12;

  double _masterWidth = _initial;
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxMaster = (maxWidth - _minDetail - _handleWidth)
            .clamp(_minMaster, double.infinity);
        final width = _masterWidth.clamp(_minMaster, maxMaster);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: width, child: widget.master),
            _DragHandle(
              width: _handleWidth,
              active: _hovering || _dragging,
              onHoverChanged: (h) => setState(() => _hovering = h),
              onDragStart: () => setState(() => _dragging = true),
              onDragEnd: () => setState(() => _dragging = false),
              onDragDelta: (dx) {
                setState(() {
                  _masterWidth =
                      (_masterWidth + dx).clamp(_minMaster, maxMaster);
                });
              },
              onResetTap: () => setState(() => _masterWidth = _initial),
            ),
            Expanded(child: widget.detail),
          ],
        );
      },
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.width,
    required this.active,
    required this.onHoverChanged,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragDelta,
    required this.onResetTap,
  });

  final double width;
  final bool active;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onResetTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => onDragStart(),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onHorizontalDragCancel: onDragEnd,
        onHorizontalDragUpdate: (d) => onDragDelta(d.delta.dx),
        onDoubleTap: onResetTap, // двойной клик = вернуть дефолт
        child: SizedBox(
          width: width,
          child: Center(
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: active
                    ? scheme.primary.withValues(alpha: 0.7)
                    : scheme.outline.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
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
    final allowed = accessibleBranchIds(user); // null = creator/director
    final q = search.toLowerCase().trim();
    final qDigits = search.replaceAll(RegExp(r'[^\d]'), '');
    final filtered = state.clients
        .where((c) =>
            (allowed == null ||
                c.branchId == null ||
                allowed.contains(c.branchId)) &&
            _matchesClientSearch(c, search, q, qDigits))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Клиенты')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context),
        icon: const Icon(AppIcons.person_add),
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
                    icon: AppIcons.people_outline,
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
    final bloc = context.read<ClientBloc>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: false,
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: ClientDetailScreen(clientId: client.id),
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
          icon: const Icon(AppIcons.person_add),
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
          prefixIcon: const Icon(AppIcons.search, size: 20),
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
    this.compact = false,
  });

  final List<Client> clients;
  final List<Branch> branches;
  final Map<String, ClientBalance> balancesByClientId;
  final Client? selected;
  final ValueChanged<Client> onSelect;
  final bool isLoading;

  /// Когда detail-панель открыта — таблица сжимается в вертикальный список
  /// карточек, влезающий в 380 px колонку.
  final bool compact;

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
            Icon(AppIcons.people_outline,
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

    if (compact) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          itemCount: clients.length,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
          ),
          itemBuilder: (ctx, i) {
            final client = clients[i];
            final isSelected = selected?.id == client.id;
            final balance = balancesByClientId[client.id];
            return Material(
              color: isSelected
                  ? Theme.of(context).colorScheme.primaryContainer
                      .withValues(alpha: 0.4)
                  : Colors.transparent,
              child: InkWell(
                onTap: () => onSelect(client),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.15),
                        child: Text(
                          client.name.isEmpty ? '?' : client.name[0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              client.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _shortBalanceSummary(client, balance),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'JetBrains Mono',
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        AppIcons.chevron_right,
                        size: 16,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
                    mainAxisSize: MainAxisSize.min,
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
                      Flexible(
                        child: Text(
                          client.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
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

            // Wallets — каждая валюта = отдельная кликабельная строка с
            // кнопкой конвертации.
            _DesktopWalletsBlock(
              client: widget.client,
              balance: balance,
            ),
            const SizedBox(height: AppSpacing.md),

            // Actions
            _ClientActions(client: widget.client, balance: balance),

            const SizedBox(height: AppSpacing.md),
            _TelegramSettingsBlock(client: widget.client),

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
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _TransactionTile(tx: transactions[i]),
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
  const _ClientActions({required this.client, this.balance});
  final Client client;
  final ClientBalance? balance;

  @override
  Widget build(BuildContext context) {
    final hasBalance = balance != null &&
        balance!.balancesByCurrency.values.any((v) => v > 0.0049);
    const compactPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 8);
    const compactTextStyle =
        TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showOperationDialog(context, isDeposit: true),
            icon: const Icon(AppIcons.add_circle_outline, size: 16),
            label: const Text('Пополнить'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.green,
              padding: compactPadding,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showOperationDialog(context, isDeposit: false),
            icon: const Icon(AppIcons.remove_circle_outline, size: 16),
            label: const Text('Списать'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              padding: compactPadding,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: hasBalance
                ? () => showConvertCurrencyDialog(
                      context: context,
                      client: client,
                      balance: balance,
                      initialFrom: _initialFrom(),
                    )
                : null,
            icon: const Icon(AppIcons.swap_horiz, size: 16),
            label: const Text('Обмен'),
            style: OutlinedButton.styleFrom(
              padding: compactPadding,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
          ),
        ),
      ],
    );
  }

  /// Берём кошелёк с самым большим положительным балансом, иначе основной.
  String _initialFrom() {
    final b = balance;
    if (b == null) return client.currency;
    String? best;
    double bestAmt = 0;
    for (final e in b.balancesByCurrency.entries) {
      if (e.value > bestAmt) {
        bestAmt = e.value;
        best = e.key;
      }
    }
    return best ?? client.currency;
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

/// Список кошельков клиента в desktop-карточке.  Каждый кошелёк = строка с
/// кодом валюты, остатком и кнопкой конвертации (через [_DotMenu] чтобы не
/// перегружать UI). Тап по строке открывает диалог конвертации с этой валюты.
class _DesktopWalletsBlock extends StatelessWidget {
  const _DesktopWalletsBlock({required this.client, required this.balance});
  final Client client;
  final ClientBalance? balance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final wallets = <_DesktopWallet>[];
    final seen = <String>{};
    void add(String c, double amt, {bool primary = false}) {
      if (!seen.add(c)) return;
      wallets.add(_DesktopWallet(c, amt, primary));
    }
    add(client.currency,
        balance?.balancesByCurrency[client.currency] ?? balance?.balance ?? 0,
        primary: true);
    for (final c in client.walletCurrencies) {
      add(c, balance?.balancesByCurrency[c] ?? 0);
    }
    if (balance != null) {
      for (final e in balance!.balancesByCurrency.entries) {
        add(e.key, e.value);
      }
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.10),
            AppColors.secondary.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Кошельки',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: secondary,
                ),
              ),
              const Spacer(),
              Text(
                '${wallets.length} ${wallets.length == 1 ? 'валюта' : (wallets.length < 5 ? 'валюты' : 'валют')}',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // При большом количестве валют переключаемся на 2-колоночную
          // сетку — иначе блок съедает 300-400px и для истории операций
          // ниже остаётся слишком мало места для скролла. Порог 3
          // подобран эмпирически: 2 валюты в одну колонку читаются
          // комфортно, 3+ уже стоят дороже скролла.
          if (wallets.length <= 2)
            for (var i = 0; i < wallets.length; i++) ...[
              _DesktopWalletRow(
                client: client,
                balance: balance,
                wallet: wallets[i],
              ),
              if (i < wallets.length - 1)
                Divider(
                  height: 14,
                  color: scheme.outline.withValues(alpha: 0.15),
                ),
            ]
          else
            _DesktopWalletsGrid(
              client: client,
              balance: balance,
              wallets: wallets,
            ),
        ],
      ),
    );
  }
}

/// Compact 2-column grid used when a client has 3+ wallets — keeps the
/// balances visible without eating the transaction history's scroll area.
class _DesktopWalletsGrid extends StatelessWidget {
  const _DesktopWalletsGrid({
    required this.client,
    required this.balance,
    required this.wallets,
  });
  final Client client;
  final ClientBalance? balance;
  final List<_DesktopWallet> wallets;

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight + CrossAxisAlignment.stretch требовали bounded
    // высоты от parent; в Column на дисплее с tx-историей это могло
    // схлопывать сетку в 0px. Переходим на простой Row(start) + фикс
    // высоту 50 на ячейку — гарантированно рендерится.
    const cellHeight = 50.0;
    final cells = <Widget>[];
    for (var i = 0; i < wallets.length; i += 2) {
      final left = wallets[i];
      final right = i + 1 < wallets.length ? wallets[i + 1] : null;
      cells.add(Padding(
        padding: EdgeInsets.only(bottom: i + 2 >= wallets.length ? 0 : 8),
        child: SizedBox(
          height: cellHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _DesktopWalletCompact(
                  client: client,
                  balance: balance,
                  wallet: left,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: right == null
                    ? const SizedBox.shrink()
                    : _DesktopWalletCompact(
                        client: client,
                        balance: balance,
                        wallet: right,
                      ),
              ),
            ],
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: cells,
    );
  }
}

/// Compressed wallet row: smaller badge, no "Кошелёк X" label (currency
/// code in the badge is enough), amount right-aligned. Designed to fit
/// two-per-row in the wallets grid.
class _DesktopWalletCompact extends StatelessWidget {
  const _DesktopWalletCompact({
    required this.client,
    required this.balance,
    required this.wallet,
  });
  final Client client;
  final ClientBalance? balance;
  final _DesktopWallet wallet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNeg = wallet.amount < -0.0049;
    final color = isNeg ? AppColors.error : AppColors.primary;
    final canConvert = wallet.amount > 0.0049;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canConvert
            ? () => showConvertCurrencyDialog(
                  context: context,
                  client: client,
                  balance: balance,
                  initialFrom: wallet.currency,
                )
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: scheme.outline.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(7),
                ),
                alignment: Alignment.center,
                child: Text(
                  wallet.currency,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (wallet.isPrimary)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.primary
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(100),
                            ),
                            child: Text(
                              'ОСН',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      '${wallet.amount.toStringAsFixed(2)} ${wallet.currency}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isNeg ? AppColors.error : scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              if (canConvert)
                Icon(
                  AppIcons.swap_horiz,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopWallet {
  final String currency;
  final double amount;
  final bool isPrimary;
  const _DesktopWallet(this.currency, this.amount, this.isPrimary);
}

class _DesktopWalletRow extends StatelessWidget {
  const _DesktopWalletRow({
    required this.client,
    required this.balance,
    required this.wallet,
  });
  final Client client;
  final ClientBalance? balance;
  final _DesktopWallet wallet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNeg = wallet.amount < -0.0049;
    final color = isNeg ? AppColors.error : AppColors.primary;
    final canConvert = wallet.amount > 0.0049;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canConvert
            ? () => showConvertCurrencyDialog(
                  context: context,
                  client: client,
                  balance: balance,
                  initialFrom: wallet.currency,
                )
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  wallet.currency,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'Кошелёк ${wallet.currency}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (wallet.isPrimary) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Text(
                          'ОСН',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                '${wallet.amount.toStringAsFixed(2)} ${wallet.currency}',
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isNeg ? AppColors.error : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(AppIcons.swap_horiz, size: 16),
                tooltip: canConvert
                    ? 'Конвертировать ${wallet.currency} в другую валюту'
                    : 'Нет средств для конвертации',
                onPressed: canConvert
                    ? () => showConvertCurrencyDialog(
                          context: context,
                          client: client,
                          balance: balance,
                          initialFrom: wallet.currency,
                        )
                    : null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
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
                  ? AppIcons.add_circle_outline
                  : AppIcons.remove_circle_outline,
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
                initialValue: _opCurrency,
                decoration: const InputDecoration(
                  labelText: 'Валюта операции',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.currency_exchange),
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

// ─── Telegram Settings Block ───

class _TelegramSettingsBlock extends StatefulWidget {
  const _TelegramSettingsBlock({required this.client});
  final Client client;

  @override
  State<_TelegramSettingsBlock> createState() => _TelegramSettingsBlockState();
}

class _TelegramSettingsBlockState extends State<_TelegramSettingsBlock> {
  bool _editing = false;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.client.telegramChatId ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Берём свежего клиента из bloc state (после save bloc обновляет
  /// selectedClient + clients, поэтому здесь видим актуальный chat_id).
  Client _currentClient(ClientBlocState s) {
    if (s.selectedClient?.id == widget.client.id) return s.selectedClient!;
    for (final c in s.clients) {
      if (c.id == widget.client.id) return c;
    }
    return widget.client;
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ClientBloc, ClientBlocState>(
      listenWhen: (prev, curr) => prev.status != curr.status,
      listener: (context, state) {
        // После успешного save закрываем режим редактирования.
        if (state.status == ClientBlocStatus.success && _editing) {
          setState(() => _editing = false);
        }
      },
      builder: (context, state) {
        final client = _currentClient(state);
        final isOperating = state.status == ClientBlocStatus.operating;
        final hasChatId = (client.telegramChatId ?? '').isNotEmpty;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(AppIcons.send, size: 18,
                      color: Color(0xFF2AABEE)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Telegram-уведомления',
                      style: context.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasChatId && !_editing)
                    _StatusPill(
                      icon: AppIcons.check_circle,
                      text: 'подключено',
                      color: Colors.green,
                    )
                  else if (!hasChatId && !_editing)
                    _StatusPill(
                      icon: AppIcons.power_off,
                      text: 'не привязано',
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_editing)
                _editForm(context, client, isOperating)
              else if (hasChatId)
                _connectedRow(context, client, isOperating)
              else
                _emptyRow(context, isOperating),
            ],
          ),
        );
      },
    );
  }

  // ─── режим: уже подключено ───
  Widget _connectedRow(BuildContext context, Client client, bool isOperating) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(AppIcons.chat_bubble_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableText(
                client.telegramChatId ?? '',
                style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: isOperating
                    ? null
                    : () => context.read<ClientBloc>().add(
                          ClientTelegramTestRequested(client.id),
                        ),
                icon: const Icon(AppIcons.send, size: 18),
                label: const Text('Тест'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton.outlined(
              onPressed: isOperating
                  ? null
                  : () {
                      _ctrl.text = client.telegramChatId ?? '';
                      setState(() => _editing = true);
                    },
              icon: const Icon(AppIcons.edit, size: 18),
              tooltip: 'Изменить',
            ),
            const SizedBox(width: 4),
            IconButton.outlined(
              onPressed: isOperating
                  ? null
                  : () => _confirmAndUnlink(context, client),
              icon: const Icon(AppIcons.link_off, size: 18),
              tooltip: 'Отвязать',
              style: IconButton.styleFrom(foregroundColor: Colors.red),
            ),
          ],
        ),
      ],
    );
  }

  // ─── режим: не привязано (компактно) ───
  Widget _emptyRow(BuildContext context, bool isOperating) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isOperating
            ? null
            : () {
                _ctrl.text = '';
                setState(() => _editing = true);
              },
        icon: const Icon(AppIcons.add_link, size: 18),
        label: const Text('Привязать Telegram-группу'),
      ),
    );
  }

  // ─── режим: ввод/редактирование ───
  Widget _editForm(BuildContext context, Client client, bool isOperating) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Введите chat_id группы клиента (число с «-» для супергрупп). '
          'Бот должен быть админом группы.',
          style: context.textTheme.bodySmall?.copyWith(
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _ctrl,
          autofocus: true,
          enabled: !isOperating,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            hintText: '-1001234567890',
            prefixIcon: Icon(AppIcons.chat_bubble_outline, size: 18),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]')),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isOperating
                    ? null
                    : () {
                        final v = _ctrl.text.trim();
                        if (v.isEmpty) return;
                        context.read<ClientBloc>().add(
                              ClientTelegramChatIdUpdated(
                                clientId: client.id,
                                chatId: v,
                              ),
                            );
                      },
                icon: isOperating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(AppIcons.save, size: 18),
                label: const Text('Сохранить'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: isOperating
                  ? null
                  : () => setState(() => _editing = false),
              child: const Text('Отмена'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmAndUnlink(BuildContext context, Client client) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Отвязать Telegram-группу?'),
        content: Text(
          'Уведомления о пополнении/снятии/выкупе клиента «${client.name}» '
          'больше не будут отправляться в Telegram.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Отвязать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    context.read<ClientBloc>().add(
          ClientTelegramChatIdUpdated(
            clientId: client.id,
            chatId: null,
          ),
        );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.text,
    required this.color,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Transaction Tile (полная карточка операции в истории) ───

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.tx});
  final ClientTransaction tx;

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year}, '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final isDeposit = tx.isDeposit;
    final isConv = tx.isConversion;
    final color = isConv
        ? AppColors.primary
        : (isDeposit ? Colors.green : Colors.red);
    final scheme = Theme.of(context).colorScheme;
    final secondary = context.isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final convMeta = tx.conversionMeta;
    final convFrom = convMeta?['from']?.toString();
    final convTo = convMeta?['to']?.toString();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isConv
                    ? AppIcons.swap_horiz
                    : (isDeposit
                        ? AppIcons.arrow_downward
                        : AppIcons.arrow_upward),
                color: color,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                isConv && convFrom != null && convTo != null
                    ? (isDeposit
                        ? 'Конвертация $convFrom → $convTo'
                        : 'Конвертация $convFrom → $convTo')
                    : (isDeposit ? 'Пополнение' : 'Снятие'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              Text(
                '${isDeposit ? '+' : '−'}'
                '${tx.amount.toStringAsFixed(2)} ${tx.currency}',
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          if ((tx.transactionCode ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              tx.transactionCode!,
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if ((tx.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              tx.description!,
              style: const TextStyle(fontSize: 13),
            ),
          ],
          if (tx.balanceAfter != null) ...[
            const SizedBox(height: 4),
            Text(
              'Остаток: ${tx.balanceAfter!.toStringAsFixed(2)} ${tx.currency}',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 12,
                color: secondary,
              ),
            ),
          ],
          const SizedBox(height: 6),
          DefaultTextStyle.merge(
            style: TextStyle(fontSize: 11, color: secondary),
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.person_outline,
                        size: 12, color: secondary),
                    const SizedBox(width: 2),
                    Text(tx.createdByName ?? '—'),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.access_time,
                        size: 12, color: secondary),
                    const SizedBox(width: 2),
                    Text(_fmtDate(tx.createdAt)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
            Icon(AppIcons.person_add),
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
                    prefixIcon: Icon(AppIcons.person_outline),
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
                        : const Icon(AppIcons.phone),
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
                        : const Icon(AppIcons.flag),
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
                    initialValue: effectiveBranchId != null &&
                            branches.any((b) => b.id == effectiveBranchId)
                        ? effectiveBranchId
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Филиал *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(AppIcons.account_tree),
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
                  initialValue: _currency,
                  decoration: const InputDecoration(
                    labelText: 'Основная валюта *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(AppIcons.currency_exchange),
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
                    : const Icon(AppIcons.check),
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
