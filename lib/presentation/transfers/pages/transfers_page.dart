import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/routing/route_names.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/transfer_issuance.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/domain/services/transfer_invoice_service.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/common/widgets/desktop_data_grid.dart';
import 'package:ethnocount/presentation/common/widgets/filter_panel.dart';
import 'package:ethnocount/presentation/common/widgets/shimmer_loading.dart';
import 'package:ethnocount/presentation/common/widgets/empty_state.dart';
import 'package:ethnocount/presentation/common/widgets/responsive_sheet.dart';
import 'package:ethnocount/presentation/common/widgets/export_dialog.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/data/datasources/remote/client_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/presentation/transfers/widgets/accept_transfer_account_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/attach_transfer_to_partner_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/dispatch_courier_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/edit_transfer_dialog.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_filter_bar.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_filter_chips.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_row_card.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_status_chip.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfers_hero_header.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/icons/app_icons.dart';

/// Card vs cash детектор: true если счёт получателя — карта. Используется
/// чтобы пропустить курьерскую доставку для электронных переводов.
bool _isReceiverCard(
  Map<String, List<BranchAccount>> branchAccounts,
  Transfer t,
) {
  if (t.toAccountId.isEmpty) return false;
  final list = branchAccounts[t.toBranchId];
  if (list == null) return false;
  final acc = list.where((a) => a.id == t.toAccountId).firstOrNull;
  return acc?.type == AccountType.card;
}

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  final _exportService = sl<ServerExportService>();
  final _invoiceService = sl<TransferInvoiceService>();
  bool _isExporting = false;
  bool _isInvoiceSaving = false;
  TransferStatus? _statusFilter;
  String? _branchFilter;
  DateTimeRange? _dateRange;
  TrinaGridStateManager? _gridStateManager;

  /// Режим фильтра по партнёру:
  ///   'all'     — показываем все переводы (по умолчанию);
  ///   'partner' — только переводы через counterparty (viaCounterpartyId != null);
  ///   'direct'  — только внутрифирменные (viaCounterpartyId == null).
  String _partnerMode = 'all';

  /// Локальный поиск по коду / имени / телефону. Применяется client-side
  /// в дополнение к серверным фильтрам — чтобы не дёргать сервер на
  /// каждый символ.
  String _searchQuery = '';

  /// Кэш партнёров {id → (name, city)} — используется в колонке «Партнёр»
  /// таблицы переводов и в фильтр-стрипе. Тянем один раз на mount; счёт
  /// партнёров маленький (≤50), realtime-подписка не нужна.
  Map<String, _PartnerLite> _partners = const {};

  @override
  void initState() {
    super.initState();
    _loadTransfers();
    _loadPartners();
  }

  Future<void> _loadPartners() async {
    try {
      final rows = await Supabase.instance.client
          .from('counterparties')
          .select('id,name,city')
          .order('name');
      if (!mounted) return;
      final map = <String, _PartnerLite>{};
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        final id = m['id']?.toString();
        if (id == null) continue;
        map[id] = _PartnerLite(
          name: (m['name'] ?? '').toString(),
          city: (m['city'] as String?)?.trim().isEmpty == true
              ? null
              : m['city'] as String?,
        );
      }
      setState(() => _partners = map);
    } catch (_) {
      // Партнёры могут быть недоступны (таблицы нет / RLS) — это не
      // блокирует страницу. Колонка «Партнёр» просто покажет «—».
    }
  }

  void _loadTransfers() {
    context.read<TransferBloc>().add(TransfersLoadRequested(
          statusFilter: _statusFilter,
          branchId: _branchFilter,
          startDate: _dateRange?.start,
          endDate: _dateRange?.end,
        ));
  }

  /// Подгоняем client-side фильтр Trina под выбранный контакт (имя/телефон).
  /// Применяется по любой из 4 колонок: отправитель/получатель × имя/телефон.
  /// Это работает поверх встроенных per-column фильтров — клиент остаётся
  /// в фокусе, можно дальше уточнить руками.
  void _applyContactFilter(Client? c) {
    final sm = _gridStateManager;
    if (sm == null) return;
    if (c == null) {
      sm.setFilter(null);
      return;
    }
    final needle = c.name.trim().toLowerCase();
    final phoneNeedle = c.phone.replaceAll(RegExp(r'\D'), '');
    sm.setFilter((row) {
      String cell(String f) => row.cells[f]?.value?.toString() ?? '';
      final sName = cell('senderName').toLowerCase();
      final rName = cell('receiverName').toLowerCase();
      final sPhone = cell('senderPhone').replaceAll(RegExp(r'\D'), '');
      final rPhone = cell('receiverPhone').replaceAll(RegExp(r'\D'), '');
      final byName = needle.isNotEmpty &&
          (sName.contains(needle) || rName.contains(needle));
      final byPhone = phoneNeedle.isNotEmpty &&
          (sPhone.contains(phoneNeedle) || rPhone.contains(phoneNeedle));
      return byName || byPhone;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = context.select<AuthBloc, dynamic>((b) => b.state.user);
    final canManageTransfers = user?.canManageTransfers ?? false;
    final canBranchTopUp = user?.canBranchTopUp ?? false;
    final allBranches = context.select<DashboardBloc, List<Branch>>(
      (bloc) => bloc.state.branches,
    );
    final branches = filterBranchesByAccess(allBranches, user);

    final isMobile = !context.isDesktop;

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          _loadTransfers();
          if (state.successMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.successMessage!),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        if (state.status == TransferBlocStatus.error &&
            state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage!),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: DataGridShortcuts(
      stateManager: _gridStateManager,
      onExport: _onExport,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: isMobile && canManageTransfers
            ? FloatingActionButton.extended(
                onPressed: () => context.goNamed(RouteNames.createTransfer),
                icon: const Icon(AppIcons.add),
                label: const Text('Новый перевод'),
              )
            : null,
        body: Column(
        children: [
          // Page header вариантов:
          //   • desktop + dark → полный hero (KPI-strip + chip-strip)
          //   • mobile  + dark → компактный header + filter-chips
          //                       (KPI-блок съел бы пол-экрана)
          //   • light/legacy   → старый header + ContactPipelineRow
          if (context.isDesktop && context.isDark) ...[
            _buildHeroHeaderSection(context, canManageTransfers),
            _buildHeroFilterChips(context),
          ] else if (context.isDark) ...[
            _buildHeader(context, canManageTransfers, canBranchTopUp),
            _buildHeroFilterChips(context),
          ] else ...[
            _buildHeader(context, canManageTransfers, canBranchTopUp),
            _ContactPipelineRow(
              onContactSelected: _applyContactFilter,
              statusFilter: _statusFilter,
              onStatusSelected: (s) {
                setState(() => _statusFilter = s);
                _loadTransfers();
              },
            ),
          ],

          // Legacy FilterPanel — только в light-теме. В dark (моб/деск)
          // вместо неё уже работают TransferFilterChips сверху.
          if (!context.isDark) FilterPanel(
            onReset: () {
              setState(() {
                _statusFilter = null;
                _branchFilter = null;
                _dateRange = null;
              });
              _loadTransfers();
            },
            trailing: FilledButton.icon(
              onPressed: _isExporting ? null : _onExport,
              icon: _isExporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.download, size: 16),
              label: Text(
                _isExporting ? 'Загрузка...' : 'Excel',
                style: const TextStyle(fontSize: 13),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            children: [
              FilterDropdown<TransferStatus>(
                label: 'Статус',
                items: TransferStatus.values,
                value: _statusFilter,
                itemLabel: (s) => s.displayName,
                width: 150,
                onChanged: (val) {
                  setState(() => _statusFilter = val);
                  _loadTransfers();
                },
              ),
              FilterDropdown<String>(
                label: 'Филиал',
                items: branches.map((b) => b.id).toList(),
                value: _branchFilter,
                itemLabel: (id) => branches.firstWhere((b) => b.id == id).name,
                width: 180,
                onChanged: (val) {
                  setState(() => _branchFilter = val);
                  _loadTransfers();
                },
              ),
              DateRangeFilter(
                startDate: _dateRange?.start,
                endDate: _dateRange?.end,
                onChanged: (range) {
                  setState(() => _dateRange = range);
                  _loadTransfers();
                },
              ),
            ],
          ),

          // Data grid
          Expanded(
            child: BlocBuilder<TransferBloc, TransferBlocState>(
              builder: (context, state) {
                // Используем общий хелпер `_visibleAndCounts` — он учитывает:
                //   • Доступ по филиалу (бухгалтер видит только свои);
                //   • Partner mode (все / через партнёра / свои);
                //   • Поиск по коду/имени/телефону.
                // Раньше тут был свой урезанный фильтр и счётчики
                // расходились с тем, что было нарисовано в чипах.
                final visibleTransfers = _visibleAndCounts(state).visible;
                if (state.status == TransferBlocStatus.loading &&
                    visibleTransfers.isEmpty) {
                  return _buildLoadingSkeleton();
                }

                if (visibleTransfers.isEmpty) {
                  final hasFilters = _statusFilter != null ||
                      _branchFilter != null ||
                      _dateRange != null ||
                      _partnerMode != 'all' ||
                      _searchQuery.isNotEmpty;
                  return _buildEmptyState(
                    context,
                    canManageTransfers,
                    hasActiveFilters: hasFilters,
                    onResetFilters: hasFilters
                        ? () {
                            setState(() {
                              _statusFilter = null;
                              _branchFilter = null;
                              _dateRange = null;
                              _partnerMode = 'all';
                              _searchQuery = '';
                            });
                            _loadTransfers();
                          }
                        : null,
                  );
                }

                if (context.isDesktop) {
                  final branchAccounts = context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
                    (bloc) => bloc.state.branchAccounts,
                  );
                  return StreamBuilder<List<AppUser>>(
                    stream: sl<UserRemoteDataSource>().watchUsers(),
                    builder: (ctx, userSnap) {
                      final userNames = <String, String>{};
                      for (final u in userSnap.data ?? []) {
                        userNames[u.id] = u.displayName.isNotEmpty
                            ? u.displayName
                            : (u.email.isNotEmpty ? u.email : '—');
                      }
                      if (!userSnap.hasData && userSnap.connectionState == ConnectionState.waiting) {
                        return _buildLoadingSkeleton();
                      }
                      return _buildDesktopGrid(
                        context,
                        visibleTransfers,
                        allBranches,
                        branchAccounts,
                        canManageTransfers,
                        userNames,
                      );
                    },
                  );
                }

                final branchAccounts = context.select<DashboardBloc, Map<String, List<BranchAccount>>>(
                  (bloc) => bloc.state.branchAccounts,
                );
                return _buildMobileList(
                  context,
                  visibleTransfers,
                  allBranches,
                  branchAccounts,
                  canManageTransfers,
                );
              },
            ),
          ),
        ],
      ),
      ),
    ),
    );
  }

  Widget _buildHeader(BuildContext context, bool canManageTransfers, bool canBranchTopUp) {
    final isMobile = !context.isDesktop;

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Переводы',
                style: context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Принятые',
              onPressed: () => context.goNamed(RouteNames.acceptedTransfers),
              icon: const Icon(AppIcons.check_circle_outline),
            ),
            if (canBranchTopUp)
              IconButton(
                tooltip: 'Пополнение филиала',
                onPressed: () => context.go('/transfers/topup'),
                icon: const Icon(AppIcons.add_business),
              ),
            if (canManageTransfers)
              IconButton(
                tooltip: 'Управление переводами',
                onPressed: () => context.go('/transfers/manage'),
                icon: const Icon(AppIcons.inbox),
              ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Переводы',
                style: context.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Между филиалами: создание, приём и фильтры',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => context.goNamed(RouteNames.acceptedTransfers),
            icon: const Icon(AppIcons.check_circle_outline, size: 18),
            label: const Text('Принятые'),
          ),
          if (canBranchTopUp)
            OutlinedButton.icon(
              onPressed: () => context.go('/transfers/topup'),
              icon: const Icon(AppIcons.add_business, size: 18),
              label: const Text('Пополнение филиала'),
            ),
          if (canManageTransfers) ...[
            OutlinedButton.icon(
              onPressed: () => context.go('/transfers/manage'),
              icon: const Icon(AppIcons.inbox, size: 18),
              label: const Text('Управление'),
            ),
            FilledButton.icon(
              onPressed: () => context.goNamed(RouteNames.createTransfer),
              icon: const Icon(AppIcons.add, size: 18),
              label: const Text('Новый перевод'),
            ),
          ],
        ],
      ),
    );
  }

  /// Показываем имя пользователя, не UID. Если не найден — «—».
  static String _userDisplay(Map<String, String> userNames, String userId) {
    final name = userNames[userId];
    return (name != null && name.isNotEmpty) ? name : '—';
  }

  // ─── Hero-layout helpers (desktop+dark, design-spec) ─────────────

  /// Returns transfers the current user is allowed to see, plus the
  /// per-status count map. Reused by hero header + filter chips so both
  /// reflect the same access-filtered view.
  ///
  /// Применяет также UI-фильтры (partner mode + search) — таблица и
  /// статус-чипы будут считать одни и те же данные, чтобы счётчики
  /// «Ожидают: 3» не врали при включённом partner-фильтре.
  ({List<Transfer> visible, Map<TransferStatus, int> perStatus})
      _visibleAndCounts(TransferBlocState state) {
    final user = context.read<AuthBloc>().state.user;
    final allowed = accessibleBranchIds(user);
    final accessFiltered = allowed == null
        ? state.transfers
        : state.transfers
            .where((t) =>
                allowed.contains(t.fromBranchId) ||
                allowed.contains(t.toBranchId))
            .toList();

    final q = _searchQuery.trim().toLowerCase();
    final needleDigits = q.replaceAll(RegExp(r'\D'), '');

    bool matches(Transfer t) {
      // Partner mode
      if (_partnerMode == 'partner' && t.viaCounterpartyId == null) {
        return false;
      }
      if (_partnerMode == 'direct' && t.viaCounterpartyId != null) {
        return false;
      }
      // Search
      if (q.isEmpty) return true;
      final code = (t.transactionCode ?? t.id).toLowerCase();
      if (code.contains(q)) return true;
      final sName = (t.senderName ?? '').toLowerCase();
      final rName = (t.receiverName ?? '').toLowerCase();
      if (sName.contains(q) || rName.contains(q)) return true;
      if (needleDigits.isNotEmpty) {
        final sPhone =
            (t.senderPhone ?? '').replaceAll(RegExp(r'\D'), '');
        final rPhone =
            (t.receiverPhone ?? '').replaceAll(RegExp(r'\D'), '');
        if (sPhone.contains(needleDigits) ||
            rPhone.contains(needleDigits)) {
          return true;
        }
      }
      return false;
    }

    final visible = accessFiltered.where(matches).toList();
    final perStatus = <TransferStatus, int>{};
    for (final t in visible) {
      perStatus[t.status] = (perStatus[t.status] ?? 0) + 1;
    }
    return (visible: visible, perStatus: perStatus);
  }

  Widget _buildHeroHeaderSection(
      BuildContext context, bool canManageTransfers) {
    return BlocBuilder<TransferBloc, TransferBlocState>(
      builder: (context, state) {
        final v = _visibleAndCounts(state);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final todayItems =
            v.visible.where((t) => !t.createdAt.isBefore(today)).toList();
        // USD-volume для KPI — суммируем только USD-переводы, чтобы не
        // тащить async FX lookup. Остальные показываем через счётчик.
        final usdToday = todayItems
            .where((t) => t.currency.toUpperCase() == 'USD')
            .fold<double>(0, (sum, t) => sum + t.amount);
        return TransfersHeroHeader(
          kpis: TransfersKpis(
            totalToday: todayItems.length,
            usdToday: usdToday,
            pendingCount: v.perStatus[TransferStatus.created] ?? 0,
            toDeliveryCount: v.perStatus[TransferStatus.toDelivery] ?? 0,
            deliveredCount: v.perStatus[TransferStatus.delivered] ?? 0,
          ),
          onCreate: () => context.goNamed(RouteNames.createTransfer),
          onRefresh: _loadTransfers,
          canCreate: canManageTransfers,
        );
      },
    );
  }

  Widget _buildHeroFilterChips(BuildContext context) {
    return BlocBuilder<TransferBloc, TransferBlocState>(
      builder: (context, state) {
        final v = _visibleAndCounts(state);
        final user = context.read<AuthBloc>().state.user;
        final branches = filterBranchesByAccess(
          context.read<DashboardBloc>().state.branches,
          user,
        );
        // Полная панель фильтров (status-чипы + филиал + период +
        // partner-mode + поиск + reset). Заменила голую chip-строку.
        return TransferFilterBar(
          buckets: TransferFilterChips.bucketsFor(
            totalCount: v.visible.length,
            perStatusCount: v.perStatus,
          ),
          statusFilter: _statusFilter,
          onStatusChanged: (s) {
            setState(() => _statusFilter = s);
            _loadTransfers();
          },
          branches: branches,
          branchFilter: _branchFilter,
          onBranchChanged: (id) {
            setState(() => _branchFilter = id);
            _loadTransfers();
          },
          dateRange: _dateRange,
          onDateRangeChanged: (r) {
            setState(() => _dateRange = r);
            _loadTransfers();
          },
          partnerMode: _partnerMode,
          onPartnerModeChanged: (m) {
            setState(() => _partnerMode = m);
          },
          searchQuery: _searchQuery,
          onSearchChanged: (q) {
            setState(() => _searchQuery = q);
          },
          onResetAll: () {
            setState(() {
              _statusFilter = null;
              _branchFilter = null;
              _dateRange = null;
              _partnerMode = 'all';
              _searchQuery = '';
            });
            _loadTransfers();
          },
        );
      },
    );
  }

  Widget _buildDesktopGrid(
    BuildContext context,
    List<Transfer> transfers,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers, [
    Map<String, String> userNames = const {},
  ]) {
    String branchName(String id) {
      final match = branches.where((b) => b.id == id);
      return match.isNotEmpty ? match.first.name : id;
    }

    String accountName(String id) {
      for (final list in branchAccounts.values) {
        final acc = list.where((a) => a.id == id).firstOrNull;
        if (acc != null) return acc.name;
      }
      return id;
    }

    // Новый порядок колонок (по UX-запросу оператора):
    //   1. Статус — первый и frozen, потому что это самый
    //      «работающий» столбец: жмут на чипу — продвигается стейт-машина.
    //   2. Код, Дата — также frozen, чтобы скролл вправо не «терял»
    //      привязку строки.
    //   3. Партнёр — сразу после кода, со значком ⇄ и именем counterparty,
    //      чтобы partner-переводы было видно издалека (раньше колонки не
    //      было совсем — оператор не мог отличить partner-payout от
    //      внутреннего перевода).
    //   4. Дальше — Откуда / Куда / Стороны / Суммы / Авторы.
    final columns = [
      TrinaColumn(
        title: 'Статус',
        field: 'status',
        type: TrinaColumnType.text(),
        width: 130,
        minWidth: 80,
        frozen: TrinaColumnFrozen.start,
        enableSorting: true,
        enableFilterMenuItem: true,
        renderer: (ctx) {
          final value = ctx.cell.value.toString();
          final statusEnum = TransferStatus.values
              .where((e) => e.name == value)
              .firstOrNull;
          if (statusEnum == null) return Text(value);
          final idx = ctx.rowIdx;
          if (idx < 0 || idx >= transfers.length) {
            return TransferStatusChip(status: statusEnum);
          }
          final t = transfers[idx];
          final advance = TransferAdvanceAction.resolve(
            context,
            t,
            onShowDetails: () => _showTransferDetailDialog(
              context,
              t,
              branches,
              branchAccounts,
              userNames,
              canManageTransfers,
            ),
          );
          return Align(
            alignment: Alignment.centerLeft,
            child: TransferStatusChip(
              status: statusEnum,
              onTap: advance?.run,
              tooltip: advance?.tooltip,
            ),
          );
        },
      ),
      FinancialColumns.text(title: 'Код', field: 'code', width: 100, frozen: true),
      FinancialColumns.text(title: 'Дата', field: 'date', width: 95),
      // Колонка «Партнёр» с собственным рендером (chip с иконкой ⇄).
      // value хранит имя или '—' — это даёт работать сортировке/фильтру
      // без переопределения. Renderer добавляет иконку только когда есть
      // партнёр, чтобы строки без партнёра не были визуально «шумными».
      TrinaColumn(
        title: 'Партнёр',
        field: 'partner',
        type: TrinaColumnType.text(),
        width: 150,
        minWidth: 90,
        enableSorting: true,
        enableFilterMenuItem: true,
        renderer: (ctx) {
          final v = ctx.cell.value.toString();
          if (v.isEmpty || v == '—') {
            return Text(
              '—',
              style: TextStyle(color: AppColors.darkTextTertiary),
            );
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(AppIcons.swap_horiz,
                    size: 12, color: AppColors.purple),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  v,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          );
        },
      ),
      FinancialColumns.text(title: 'Филиал отправителя', field: 'from', width: 140),
      FinancialColumns.text(title: 'Счёт отправителя', field: 'fromAccount', width: 140),
      FinancialColumns.text(title: 'Имя отправителя', field: 'senderName', width: 120),
      FinancialColumns.text(title: 'Телефон отправителя', field: 'senderPhone', width: 120),
      FinancialColumns.text(title: 'Филиал получателя', field: 'to', width: 140),
      FinancialColumns.text(title: 'Имя получателя', field: 'receiverName', width: 120),
      FinancialColumns.text(title: 'Телефон получателя', field: 'receiverPhone', width: 120),
      FinancialColumns.text(title: 'Сумма', field: 'amountDisplay', width: 110),
      FinancialColumns.text(title: 'Валюта отправителя', field: 'fromCurrency', width: 75),
      FinancialColumns.text(title: 'Курс', field: 'rate', width: 60),
      FinancialColumns.text(title: 'Конвертировано', field: 'convertedDisplay', width: 110),
      FinancialColumns.text(title: 'Валюта получателя', field: 'toCurrency', width: 75),
      FinancialColumns.text(title: 'Комиссия', field: 'commissionDisplay', width: 90),
      FinancialColumns.text(title: 'Создал', field: 'createdBy', width: 85),
      FinancialColumns.text(title: 'Принял', field: 'confirmedBy', width: 85),
    ];

    final rows = transfers.map((t) {
      final sentCur = t.currency;
      final recvCur = t.toCurrency ?? t.currency;
      final sentText = t.isSplitCurrency
          ? t.splitPartsDisplay
          : '${t.totalDebitAmount.formatCurrencyNoDecimals()} $sentCur';
      final recvAmount = t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;
      final recvText = '${recvAmount.formatCurrencyNoDecimals()} $recvCur';
      final rateDisplay = sentCur != recvCur
          ? t.exchangeRate.toString()
          : '—';
      final commissionText = t.commission > 0
          ? '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}'
          : '—';

      // Имя партнёра для отображения и фильтрации/сортировки. Для
      // не-партнёрских переводов — пустая строка (рендерер покажет «—»).
      final partnerDisplay = (t.viaCounterpartyId != null &&
              _partners[t.viaCounterpartyId!] != null)
          ? _partners[t.viaCounterpartyId!]!.name
          : '';

      return TrinaRow(cells: {
        'code': TrinaCell(value: t.transactionCode ?? t.id.substring(0, 8)),
        'date': TrinaCell(value: t.createdAt.fullFormatted),
        'partner': TrinaCell(value: partnerDisplay),
        'from': TrinaCell(value: branchName(t.fromBranchId)),
        'fromAccount': TrinaCell(value: accountName(t.fromAccountId)),
        'senderName': TrinaCell(value: t.senderName ?? '—'),
        'senderPhone': TrinaCell(value: t.senderPhone ?? '—'),
        'to': TrinaCell(value: branchName(t.toBranchId)),
        'receiverName': TrinaCell(value: t.receiverName ?? '—'),
        'receiverPhone': TrinaCell(value: t.receiverPhone ?? '—'),
        'amountDisplay': TrinaCell(value: sentText),
        'fromCurrency': TrinaCell(value: sentCur),
        'rate': TrinaCell(value: rateDisplay),
        'convertedDisplay': TrinaCell(value: recvText),
        'toCurrency': TrinaCell(value: recvCur),
        'commissionDisplay': TrinaCell(value: commissionText),
        'status': TrinaCell(value: t.status.name),
        'createdBy': TrinaCell(value: _userDisplay(userNames, t.createdBy)),
        'confirmedBy': TrinaCell(value: t.confirmedBy != null ? _userDisplay(userNames, t.confirmedBy!) : '—'),
      });
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: DesktopDataGrid(
        // v2 — после ввода новой колонки «Партнёр» и переноса «Статус» в
        // начало. Старые сохранённые preferences не подходят (порядка
        // не было), поэтому ключ сменили — у пользователей сразу
        // отрисуется новый layout, потом можно перетащить как удобно.
        gridId: 'transfers_v2',
        columns: columns,
        rows: rows,
        // Замораживаем Статус + Код + Дата — это «якорь» строки. Дальше
        // оператор скроллит вправо и всегда видит, на какую запись смотрит.
        frozenColumns: 3,
        showPagination: transfers.length > 50,
        onLoaded: (event) {
          _gridStateManager = event.stateManager;
        },
        onRowDoubleTap: (event) {
          final idx = event.rowIdx;
          if (idx >= 0 && idx < transfers.length) {
            _showTransferDetailDialog(
              context,
              transfers[idx],
              branches,
              branchAccounts,
              userNames,
              canManageTransfers,
            );
          }
        },
      ),
    );
  }

  Widget _buildMobileList(
    BuildContext context,
    List<Transfer> transfers,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers,
  ) {
    // Dark-тема: компактные карточки `TransferRowCard` из дизайн-системы
    // (border-left по цвету статуса, branch-code pills, mono amount).
    // Тап открывает detail-sheet с инлайн-кнопками действий (Принять /
    // Отдать курьеру / Выдать / Изменить).
    //
    // Light-тема: оставлен legacy `_TransferCard` с инлайн-actions —
    // переходить на dark-only design в светлой теме нет смысла.
    final useDarkRows = context.isDark;
    final branchById = <String, Branch>{for (final b in branches) b.id: b};

    return RefreshIndicator(
      onRefresh: () async => _loadTransfers(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.sm,
          80, // extra space so FAB never hides the last card
        ),
        itemCount: transfers.length,
        separatorBuilder: (_, _) =>
            SizedBox(height: useDarkRows ? 8 : 0),
        itemBuilder: (context, index) {
          final t = transfers[index];
          if (useDarkRows) {
            final fromB = branchById[t.fromBranchId];
            final toB = branchById[t.toBranchId];
            final id = (t.transactionCode != null &&
                    t.transactionCode!.isNotEmpty)
                ? t.transactionCode!
                : t.id;
            // Partner-name для бейджа: если перевод через counterparty
            // и нам известно её имя — показываем чип «⇄ Имя». Иначе null.
            final partnerName = t.viaCounterpartyId == null
                ? null
                : _partners[t.viaCounterpartyId!]?.name;
            return TransferRowCard(
              id: id,
              status: t.status,
              fromBranchCode: fromB?.code ?? '—',
              toBranchCode: toB?.code ?? '—',
              amount: t.amount,
              currency: t.currency,
              toCurrency: t.toCurrency ?? t.currency,
              received: t.convertedAmount,
              receiverName: t.receiverName ?? '—',
              createdAt: t.createdAt,
              partnerName: partnerName,
              onTap: () => _showTransferDetailSheet(
                context,
                t,
                branches,
                branchAccounts,
                canManageTransfers,
              ),
            );
          }
          return _TransferCard(
            transfer: t,
            branches: branches,
            branchAccounts: branchAccounts,
            canManageTransfers: canManageTransfers,
            onEdit: t.isEditable && canManageTransfers
                ? () => _showEditTransferDialog(context, t)
                : null,
            onConfirm: t.isCreated
                ? () => _handleConfirmTransfer(context, t)
                : null,
            onDispatch: t.isToDelivery && !_isReceiverCard(branchAccounts, t)
                ? () => showDispatchCourierDialog(context, t)
                : null,
            onDetails: () => _showTransferDetailSheet(
              context,
              t,
              branches,
              branchAccounts,
              canManageTransfers,
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: 8,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ShimmerLoading.listTile(),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    bool canManageTransfers, {
    bool hasActiveFilters = false,
    VoidCallback? onResetFilters,
  }) {
    if (hasActiveFilters && onResetFilters != null) {
      return EmptyState(
        icon: AppIcons.filter_alt_off,
        title: 'Нет переводов по фильтрам',
        subtitle:
            'Сбросьте период, статус или филиал — возможно, записи скрыты фильтром.',
        actionLabel: 'Сбросить фильтры',
        actionIcon: AppIcons.filter_alt_off,
        onAction: onResetFilters,
      );
    }
    return EmptyState(
      icon: AppIcons.inbox,
      title: 'Переводы пока отсутствуют',
      subtitle:
          'Создайте первый перевод между филиалами или пополните счёт через «Пополнение филиала».',
      actionLabel: canManageTransfers ? 'Создать перевод' : null,
      actionIcon: AppIcons.add,
      onAction: canManageTransfers
          ? () => context.goNamed(RouteNames.createTransfer)
          : null,
    );
  }

  void _showEditTransferDialog(BuildContext context, Transfer t) {
    showDialog(
      context: context,
      builder: (ctx) => EditTransferDialog(
        transfer: t,
        onSaved: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _handleConfirmTransfer(BuildContext context, Transfer t) {
    if (t.toAccountId.isNotEmpty) {
      context.read<TransferBloc>().add(TransferConfirmRequested(t.id));
      return;
    }
    showAcceptTransferAccountDialog(context, t);
  }

  /// Открепление перевода от партнёра. RPC detach_transfer_from_partner
  /// (миграция 041): откат saldo + удаление counterparty_transactions +
  /// сброс via_counterparty_id и spread_profit.
  Future<void> _handleDetachFromPartner(
      BuildContext context, Transfer t) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(AppIcons.warning_amber, color: AppColors.warning, size: 22),
            const SizedBox(width: 8),
            const Expanded(child: Text('Открепить от партнёра?')),
          ],
        ),
        content: Text(
          'Перевод ${t.transactionCode ?? ''} перестанет считаться партнёрским.\n\n'
          'Что произойдёт:\n'
          '• Saldo партнёра откатится назад (мы перестанем числиться должниками)\n'
          '• Запись «paid_for_us» исчезнет из истории партнёра\n'
          '• spread_profit обнулится\n'
          '• Деньги на счёте отправителя НЕ затрагиваются\n\n'
          'В amendment_history останется запись «detach_from_partner».',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(AppIcons.account_tree, size: 18),
            label: const Text('Открепить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Supabase.instance.client.rpc(
        'detach_transfer_from_partner',
        params: {'p_transfer_id': t.id},
      );
      messenger.showSnackBar(SnackBar(
        content: Text('Перевод ${t.transactionCode ?? ''} откреплён'),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ));
      if (context.mounted) {
        context.read<TransferBloc>().add(const TransfersLoadRequested());
      }
    } catch (e) {
      final s = e.toString();
      messenger.showSnackBar(SnackBar(
        content: Text(s.contains('PGRST') || s.contains('42883')
            ? 'RPC не найден. Примените миграцию 041.'
            : s.contains('чужой филиал') || s.contains('Чужой')
                ? 'Можно откреплять только переводы из своего филиала.'
                : 'Не удалось открепить: $s'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 5),
      ));
    }
  }

  /// Открывает диалог «На партнёрский» — выбор партнёра + опц. дилерские
  /// курсы. Вызывает RPC attach_transfer_to_partner.
  Future<void> _showAttachToPartnerDialog(
      BuildContext context, Transfer t) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showAttachTransferToPartnerDialog(
      context,
      mode: AttachTransferDialogMode.knownTransfer,
      transfer: t,
    );
    if (ok == true) {
      messenger.showSnackBar(SnackBar(
        content: const Row(
          children: [
            Icon(AppIcons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Перевод привязан к партнёру'),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ));
      // Перерисовываем список переводов чтобы сразу подтянулась новая
      // привязка (статус остался тот же, но via_counterparty_id появился
      // и аналитика партнёра обновится).
      if (context.mounted) {
        context.read<TransferBloc>().add(const TransfersLoadRequested());
      }
    }
  }

  void _showTransferDetailSheet(
    BuildContext context,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    bool canManageTransfers,
  ) {
    // Mobile flow doesn't have eager user names — try the cached user list
    // from UserRemoteDataSource.watchUsers() so signatures aren't blank.
    showResponsiveSheet<void>(
      context: context,
      builder: (ctx) {
        final transferBloc = context.read<TransferBloc>();
        return BlocProvider.value(
          value: transferBloc,
          child: StreamBuilder<List<AppUser>>(
            stream: sl<UserRemoteDataSource>().watchUsers(),
            builder: (innerCtx, snap) {
              final userNames = <String, String>{};
              for (final u in snap.data ?? const <AppUser>[]) {
                userNames[u.id] = u.displayName.isNotEmpty
                    ? u.displayName
                    : (u.email.isNotEmpty ? u.email : '—');
              }
              return _TransferDetailContent(
                transfer: t,
                branches: branches,
                branchAccounts: branchAccounts,
                userNames: userNames,
                canManageTransfers: canManageTransfers,
                onEdit: () {
                  Navigator.of(innerCtx).pop();
                  _showEditTransferDialog(context, t);
                },
                onConfirm: () {
                  Navigator.of(innerCtx).pop();
                  _handleConfirmTransfer(context, t);
                },
                onDispatch: () {
                  Navigator.of(innerCtx).pop();
                  showDispatchCourierDialog(context, t);
                },
                onIssueAll: () async {
                  // Полная выдача теперь идёт через тот же диалог, что и
                  // частичная — иначе оператор не выбирает счёт, и RPC
                  // выдачи списывает с дефолтного to_account_id (карта/
                  // касса не различимы). Сумма автоподставляется = весь
                  // остаток, оператор может поправить или выбрать счёт.
                  final result = await _showPartialIssueDialog(
                    innerCtx,
                    t,
                    payoutAccounts: branchAccounts[t.toBranchId] ?? const [],
                    presetFullRemaining: true,
                  );
                  if (result != null && context.mounted) {
                    Navigator.of(innerCtx).pop();
                    context.read<TransferBloc>().add(TransferIssuePartialRequested(
                          transferId: t.id,
                          amount: result.amount,
                          note: result.note,
                          fromAccountId: result.fromAccountId,
                        ));
                  }
                },
                onIssuePartial: () async {
                  final result = await _showPartialIssueDialog(
                    innerCtx,
                    t,
                    payoutAccounts: branchAccounts[t.toBranchId] ?? const [],
                  );
                  if (result != null && context.mounted) {
                    Navigator.of(innerCtx).pop();
                    context.read<TransferBloc>().add(TransferIssuePartialRequested(
                          transferId: t.id,
                          amount: result.amount,
                          note: result.note,
                          fromAccountId: result.fromAccountId,
                        ));
                  }
                },
                onClose: () => Navigator.of(innerCtx).pop(),
                onDownloadInvoice: () => _handleDownloadInvoice(
                  innerCtx,
                  t,
                  branches,
                  branchAccounts,
                  userNames,
                ),
                onAttachToPartner: () async {
                  Navigator.of(innerCtx).pop();
                  await _showAttachToPartnerDialog(context, t);
                },
                onDetachFromPartner: () async {
                  Navigator.of(innerCtx).pop();
                  await _handleDetachFromPartner(context, t);
                },
              );
            },
          ),
        );
      },
    );
  }

  void _showTransferDetailDialog(
    BuildContext context,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
    bool canManageTransfers,
  ) {
    final transferBloc = context.read<TransferBloc>();

    showResponsiveSheet<void>(
      context: context,
      builder: (ctx) {
        final content = _TransferDetailContent(
          transfer: t,
          branches: branches,
          branchAccounts: branchAccounts,
          userNames: userNames,
          canManageTransfers: canManageTransfers,
          onEdit: () {
            Navigator.of(ctx).pop();
            _showEditTransferDialog(context, t);
          },
          onConfirm: () {
            Navigator.of(ctx).pop();
            _handleConfirmTransfer(context, t);
          },
          onDispatch: () {
            Navigator.of(ctx).pop();
            showDispatchCourierDialog(context, t);
          },
          onIssueAll: () async {
            // см. комментарий выше — теперь все «выдать всё/остаток» идут
            // через тот же диалог, чтобы кассир обязательно выбрал счёт
            // (карта или наличные), и RPC корректно списал баланс.
            final result = await _showPartialIssueDialog(
              ctx,
              t,
              payoutAccounts: branchAccounts[t.toBranchId] ?? const [],
              presetFullRemaining: true,
            );
            if (result != null && context.mounted) {
              Navigator.of(ctx).pop();
              context.read<TransferBloc>().add(TransferIssuePartialRequested(
                    transferId: t.id,
                    amount: result.amount,
                    note: result.note,
                    fromAccountId: result.fromAccountId,
                  ));
            }
          },
          onIssuePartial: () async {
            final result = await _showPartialIssueDialog(
              ctx,
              t,
              payoutAccounts: branchAccounts[t.toBranchId] ?? const [],
            );
            if (result != null && context.mounted) {
              Navigator.of(ctx).pop();
              context.read<TransferBloc>().add(TransferIssuePartialRequested(
                    transferId: t.id,
                    amount: result.amount,
                    note: result.note,
                    fromAccountId: result.fromAccountId,
                  ));
            }
          },
          onClose: () => Navigator.of(ctx).pop(),
          onDownloadInvoice: () => _handleDownloadInvoice(
            ctx,
            t,
            branches,
            branchAccounts,
            userNames,
          ),
          onAttachToPartner: () async {
            Navigator.of(ctx).pop();
            await _showAttachToPartnerDialog(context, t);
          },
          onDetachFromPartner: () async {
            Navigator.of(ctx).pop();
            await _handleDetachFromPartner(context, t);
          },
        );
        return BlocProvider.value(
          value: transferBloc,
          child: content,
        );
      },
    );
  }

  Future<_PartialIssueResult?> _showPartialIssueDialog(
    BuildContext sheetContext,
    Transfer t, {
    List<BranchAccount> payoutAccounts = const [],
    bool presetFullRemaining = false,
  }) async {
    final repo = sl<TransferRepository>();
    // Refresh transfer just before showing the dialog so the remaining
    // amount reflects any tranches issued by other users since this list
    // was fetched.
    final fresh = await repo.getTransfer(t.id);
    final actual = fresh.fold((_) => t, (loaded) => loaded);
    if (!mounted) return null;
    if (!sheetContext.mounted) return null;
    final cur = actual.toCurrency ?? actual.currency;
    final remaining = actual.remainingToIssue;
    if (remaining <= 0) {
      ScaffoldMessenger.of(sheetContext).showSnackBar(
        const SnackBar(content: Text('Нет остатка к выдаче.')),
      );
      return null;
    }
    // Берём актуальные балансы из дашборд-стрима — они синхронны с realtime
    // обновлениями `account_balances` (см. DashboardBloc).
    final balances = context.read<DashboardBloc>().state.accountBalances;
    return showDialog<_PartialIssueResult>(
      context: sheetContext,
      barrierDismissible: false,
      builder: (_) => _PartialIssueDialog(
        transactionCode: actual.transactionCode ?? actual.id.substring(0, 8),
        remaining: remaining,
        currency: cur,
        alreadyIssued: actual.issuedAmount,
        totalAmount: actual.convertedAmount,
        payoutAccounts: payoutAccounts,
        balances: balances,
        presetFullRemaining: presetFullRemaining,
      ),
    );
  }

  Future<void> _handleDownloadInvoice(
    BuildContext sheetContext,
    Transfer t,
    List<Branch> branches,
    Map<String, List<BranchAccount>> branchAccounts,
    Map<String, String> userNames,
  ) async {
    if (_isInvoiceSaving) return;
    setState(() => _isInvoiceSaving = true);

    final branchNames = <String, String>{
      for (final b in branches) b.id: b.name,
    };
    final accountNames = <String, String>{
      for (final list in branchAccounts.values)
        for (final a in list) a.id: a.name,
    };

    final messenger = ScaffoldMessenger.of(context);

    // Pull the latest payout tranches so the invoice carries up-to-date
    // history. Soft-fail to an empty list — the invoice still renders.
    List<TransferIssuance> issuances = const [];
    if (t.issuedAmount > 0 || t.isDelivered) {
      try {
        issuances =
            await sl<TransferRemoteDataSource>().fetchIssuances(t.id);
      } catch (_) {/* ignore */}
    }

    try {
      final ok = await _invoiceService.exportInvoice(
        t,
        branchNames: branchNames,
        accountNames: accountNames,
        userNames: userNames,
        issuances: issuances,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'Инвойс ${t.transactionCode ?? ''} сохранён (Word)'
              : 'Не удалось сформировать инвойс.'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Ошибка инвойса: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isInvoiceSaving = false);
    }
  }

  Future<void> _onExport() async {
    if (_isExporting) return;
    final settings = await showDialog<ExportSettings>(
      context: context,
      builder: (ctx) => ExportDialog(
        title: 'Настройки экспорта переводов',
        columns: ExportColumnPresets.transfers,
      ),
    );
    if (settings == null || !mounted) return;
    setState(() => _isExporting = true);
    try {
      final url = await _exportService.exportTransfers(
        branchId: _branchFilter,
        startDate: _dateRange?.start,
        endDate: _dateRange?.end,
        exportSettings: settings,
      );
      if (!mounted) return;
      final period = _dateRange != null
          ? ' ${_dateRange!.start.day.toString().padLeft(2, '0')}.${_dateRange!.start.month.toString().padLeft(2, '0')}–${_dateRange!.end.day.toString().padLeft(2, '0')}.${_dateRange!.end.month.toString().padLeft(2, '0')}.${_dateRange!.end.year}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            url != null
                ? 'Скачан: История переводов$period (Excel)'
                : 'Нет данных для экспорта переводов.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка экспорта: $e')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.branches,
    this.branchAccounts = const {},
    this.canManageTransfers = false,
    this.onEdit,
    this.onConfirm,
    this.onDispatch,
    this.onDetails,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final bool canManageTransfers;
  final VoidCallback? onEdit;
  final VoidCallback? onConfirm;
  final VoidCallback? onDispatch;
  final VoidCallback? onDetails;

  String _branchName(String id) {
    final match = branches.where((b) => b.id == id);
    return match.isNotEmpty ? match.first.name : id.substring(0, 8);
  }

  String _accountName(String id) {
    for (final list in branchAccounts.values) {
      final acc = list.where((a) => a.id == id).firstOrNull;
      if (acc != null) return acc.name;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final t = transfer;
    final sentCur = t.currency;
    final recvCur = t.toCurrency ?? t.currency;
    final isCrossCurrency = sentCur != recvCur;

    final secondaryColor =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    final advance = TransferAdvanceAction.resolve(
      context,
      t,
      onShowDetails: onDetails,
    );

    final isMobile = !context.isDesktop;
    return Card(
      elevation: 0,
      margin: EdgeInsets.only(bottom: AppSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onDetails,
        child: Padding(
        padding: EdgeInsets.all(isMobile ? AppSpacing.lg : AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: route + status (tappable to advance workflow)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_branchName(t.fromBranchId)} → ${_branchName(t.toBranchId)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TransferStatusChip(
                  status: t.status,
                  onTap: advance?.run,
                  tooltip: advance?.tooltip,
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Transaction code + account
            if (t.transactionCode != null)
              Text(
                t.transactionCode!,
                style: TextStyle(
                  fontSize: 12,
                  color: secondaryColor,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            if (t.senderName != null && t.senderName!.isNotEmpty)
              Text(
                'Отправитель: ${t.senderName}${t.senderPhone != null && t.senderPhone!.isNotEmpty ? ' • ${t.senderPhone}' : ''}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (t.receiverName != null && t.receiverName!.isNotEmpty)
              Text(
                'Получатель: ${t.receiverName}${t.receiverPhone != null && t.receiverPhone!.isNotEmpty ? ' • ${t.receiverPhone}' : ''}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              'Счёт: ${_accountName(t.fromAccountId)}',
              style: TextStyle(fontSize: 12, color: secondaryColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.sm),

            // Sent → Received amounts
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  // Sent
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Отдали',
                          style: TextStyle(fontSize: 11, color: secondaryColor, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${t.totalDebitAmount.formatCurrencyNoDecimals()} $sentCur',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrains Mono',
                            color: Color(0xFFE53935),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Arrow + rate
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      children: [
                        const Icon(AppIcons.arrow_forward, size: 18),
                        if (isCrossCurrency)
                          Text(
                            '×${t.exchangeRate}',
                            style: TextStyle(fontSize: 10, color: secondaryColor),
                          ),
                      ],
                    ),
                  ),
                  // Received
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Получат',
                          style: TextStyle(fontSize: 11, color: secondaryColor, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted).formatCurrencyNoDecimals()} $recvCur',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrains Mono',
                            color: Color(0xFF43A047),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Partial issuance progress (compact bar) — only for confirmed
            // transfers with at least one tranche issued. Keeps the card
            // glanceable while still flagging incomplete payouts.
            if (t.isToDelivery && t.issuedAmount > 0) ...[
              const SizedBox(height: 8),
              _CardPayoutProgress(transfer: t),
            ],

            // Commission + date
            const SizedBox(height: 6),
            Row(
              children: [
                if (t.commission > 0)
                  Flexible(
                    child: Text(
                      'Комиссия: ${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const Spacer(),
                Text(
                  t.createdAt.historyFormatted,
                  style: TextStyle(fontSize: 12, color: secondaryColor),
                ),
              ],
            ),

            // Inline actions on the card. Full issuance UI остаётся в detail
            // dialog'е, чтобы оператор видел остаток и историю выдач.
            if ((t.isCreated || t.isToDelivery) &&
                (onEdit != null || onConfirm != null || onDispatch != null)) ...[
              SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (onEdit != null)
                    OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(AppIcons.edit, size: 18),
                      label: const Text('Изменить'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  if (onConfirm != null)
                    FilledButton(
                      onPressed: onConfirm,
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                      child: const Text('Принять'),
                    ),
                  if (onDispatch != null)
                    FilledButton.icon(
                      onPressed: onDispatch,
                      icon: const Icon(AppIcons.local_shipping, size: 18),
                      label: const Text('Отдать курьеру'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        backgroundColor: AppColors.info,
                      ),
                    ),
                ],
              ),
            ],
            // Готов к выдаче: из любого пред-финального статуса.
            // Курьерская доставка опциональна — оператор может выдать сразу
            // из toDelivery (cash без трекинга, card-перевод) или после
            // возврата курьера (withCourier).
            if (t.isWithCourier || t.isToDelivery) ...[
              SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onDetails,
                  icon: const Icon(AppIcons.payments, size: 18),
                  label: Text(t.isPartiallyIssued
                      ? 'Продолжить выдачу'
                      : 'Открыть для выдачи'),
                  style: FilledButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

// ─── Detail dialog content ─────────────────────────────────────────────
//
// Single source of truth for the per-transfer detail UI. Renders:
//   • header (transaction code, status badge)
//   • parties (откуда / куда: филиал, счёт, имя, телефон, реквизиты)
//   • split-currency parts table (when present)
//   • accounting figures: списание / получит / комиссия / курс
//   • signatures (создал / принял / выдал / отклонил / отменил)
//   • amendment history (правки до подтверждения)
//   • actions: Скачать инвойс (Word), [Изменить], [Принять], [Отдать курьеру], [Выдать]

class _TransferDetailContent extends StatelessWidget {
  const _TransferDetailContent({
    required this.transfer,
    required this.branches,
    required this.branchAccounts,
    required this.userNames,
    required this.canManageTransfers,
    required this.onEdit,
    required this.onConfirm,
    required this.onDispatch,
    required this.onIssueAll,
    required this.onIssuePartial,
    required this.onClose,
    required this.onDownloadInvoice,
    required this.onAttachToPartner,
    required this.onDetachFromPartner,
  });

  final Transfer transfer;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final Map<String, String> userNames;
  final bool canManageTransfers;
  final VoidCallback onEdit;
  final VoidCallback onConfirm;
  final VoidCallback onDispatch;
  final VoidCallback onIssueAll;
  final VoidCallback onIssuePartial;
  final VoidCallback onClose;
  final VoidCallback onDownloadInvoice;
  final VoidCallback onAttachToPartner;
  final VoidCallback onDetachFromPartner;

  String _branchName(String id) {
    final match = branches.where((b) => b.id == id);
    return match.isNotEmpty ? match.first.name : id;
  }

  String _accountName(String id) {
    if (id.isEmpty) return '—';
    for (final list in branchAccounts.values) {
      final acc = list.where((a) => a.id == id).firstOrNull;
      if (acc != null) return acc.name;
    }
    return id;
  }

  String _userDisplay(String? id) {
    if (id == null || id.isEmpty) return '—';
    final n = userNames[id];
    if (n != null && n.isNotEmpty) return n;
    return id.length >= 8 ? id.substring(0, 8) : id;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final body = _buildBody(context);
    final actions = _buildActions(context);
    final title = transfer.transactionCode ?? 'Перевод';

    if (isDesktop) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title bar
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: context.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      icon: const Icon(AppIcons.close),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Body
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                  child: body,
                ),
              ),
              // Actions
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: context.isDark
                          ? AppColors.darkBorder
                          : AppColors.lightBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ResponsiveSheetScaffold(
      title: title,
      trailing: IconButton(
        icon: const Icon(AppIcons.close),
        onPressed: onClose,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: actions,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final t = transfer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusHeader(transfer: t),
        const SizedBox(height: AppSpacing.md),
        _PartiesBlock(
          fromBranch: _branchName(t.fromBranchId),
          fromAccount: _accountName(t.fromAccountId),
          toBranch: _branchName(t.toBranchId),
          toAccount: _accountName(t.toAccountId),
          transfer: t,
        ),
        const SizedBox(height: AppSpacing.md),
        if (t.isSplitCurrency) ...[
          _SplitPartsBlock(
            transfer: t,
            accountNameResolver: _accountName,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _AmountsBlock(transfer: t),
        if (t.isToDelivery || t.isWithCourier || t.isDelivered || t.issuedAmount > 0) ...[
          const SizedBox(height: AppSpacing.md),
          _PayoutProgressBlock(
            transfer: t,
            userResolver: _userDisplay,
            accountResolver: _accountName,
          ),
        ],
        if (t.commission > 0) ...[
          const SizedBox(height: AppSpacing.md),
          _CommissionBlock(transfer: t),
        ],
        if (t.description != null && t.description!.trim().isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            title: 'Назначение платежа',
            child: Text(
              t.description!.trim(),
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _SignaturesBlock(
          transfer: t,
          userResolver: _userDisplay,
        ),
        if (t.amendmentHistory.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _AmendmentsBlock(
            transfer: t,
            userResolver: _userDisplay,
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    final t = transfer;
    return [
      OutlinedButton.icon(
        onPressed: onDownloadInvoice,
        icon: const Icon(AppIcons.description, size: 18),
        label: const Text('Скачать инвойс'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
      // Кнопка партнёрской привязки — зависит от текущего состояния:
      //   • не привязан → «На партнёрский» (attach)
      //   • привязан    → «Открепить от партнёра» (detach)
      if (canManageTransfers && !t.isPartnerTransfer)
        OutlinedButton.icon(
          onPressed: onAttachToPartner,
          icon: const Icon(AppIcons.account_tree, size: 18),
          label: const Text('На партнёрский'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.secondary,
            side: const BorderSide(color: AppColors.secondary),
            minimumSize: const Size(0, 44),
          ),
        ),
      if (canManageTransfers && t.isPartnerTransfer)
        OutlinedButton.icon(
          onPressed: onDetachFromPartner,
          icon: const Icon(AppIcons.account_tree, size: 18),
          label: const Text('Открепить'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.warning,
            side: const BorderSide(color: AppColors.warning),
            minimumSize: const Size(0, 44),
          ),
        ),
      if (canManageTransfers && t.isEditable)
        OutlinedButton.icon(
          onPressed: onEdit,
          icon: const Icon(AppIcons.edit, size: 18),
          label: const Text('Изменить'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        ),
      if (t.isCreated)
        FilledButton(
          onPressed: onConfirm,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Принять'),
        ),
      // toDelivery: для cash — отдать курьеру; для card — сразу выдача.
      if (t.isToDelivery && !_isReceiverCard(branchAccounts, t))
        FilledButton.icon(
          onPressed: onDispatch,
          icon: const Icon(AppIcons.local_shipping, size: 18),
          label: const Text('Отдать курьеру'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.info,
            minimumSize: const Size(0, 44),
          ),
        ),
      // Выдача доступна из любого пред-финального статуса:
      // toDelivery (быстрый путь — cash без курьера ИЛИ card) или
      // withCourier (после возврата курьера).
      if (t.isWithCourier || t.isToDelivery) ...[
        OutlinedButton.icon(
          onPressed: onIssuePartial,
          icon: const Icon(AppIcons.payments, size: 18),
          label: const Text('Выдать частично'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.primary),
            minimumSize: const Size(0, 44),
          ),
        ),
        FilledButton.icon(
          onPressed: onIssueAll,
          icon: const Icon(AppIcons.check_circle_outline, size: 18),
          label: Text(t.isPartiallyIssued ? 'Выдать остаток' : 'Выдать всё'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            minimumSize: const Size(0, 44),
          ),
        ),
      ],
    ];
  }
}

/// Card-shaped section with optional title.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.padding});

  final String title;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: context.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final secondaryColor = context.isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final advance = TransferAdvanceAction.resolve(context, t);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (t.transactionCode != null && t.transactionCode!.isNotEmpty)
                Text(
                  t.transactionCode!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrains Mono',
                    color: secondaryColor,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                'Создан: ${t.createdAt.fullFormatted}',
                style: TextStyle(fontSize: 12, color: secondaryColor),
              ),
              if (t.isPartnerTransfer) ...[
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.account_tree,
                          size: 12, color: AppColors.secondary),
                      const SizedBox(width: 4),
                      Text(
                        'Через партнёра',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.secondary,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (t.spreadProfit != null && t.spreadProfit! > 0.005) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.trending_up,
                            size: 11, color: Colors.green.shade700),
                        const SizedBox(width: 2),
                        Text(
                          '+${t.spreadProfit!.toStringAsFixed(0)} ${t.currency}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.green.shade700,
                            fontFamily: 'JetBrains Mono',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        TransferStatusChip(
          status: t.status,
          showIcon: true,
          onTap: advance?.run,
          tooltip: advance?.tooltip,
        ),
      ],
    );
  }
}

class _PartiesBlock extends StatelessWidget {
  const _PartiesBlock({
    required this.fromBranch,
    required this.fromAccount,
    required this.toBranch,
    required this.toAccount,
    required this.transfer,
  });

  final String fromBranch;
  final String fromAccount;
  final String toBranch;
  final String toAccount;
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isMobile = !context.isDesktop;
    final from = _PartyCard(
      title: 'Отправитель',
      branch: fromBranch,
      account: fromAccount,
      name: t.senderName,
      phone: t.senderPhone,
      info: t.senderInfo,
      icon: AppIcons.north_east,
      accentColor: const Color(0xFFE53935),
    );
    final to = _PartyCard(
      title: 'Получатель',
      branch: toBranch,
      account: toAccount.isNotEmpty ? toAccount : null,
      name: t.receiverName,
      phone: t.receiverPhone,
      info: t.receiverInfo,
      icon: AppIcons.south_west,
      accentColor: const Color(0xFF43A047),
      // Кнопка копирования телефона нужна выдающему бухгалтеру —
      // показывается, когда перевод подтверждён, но ещё не выдан.
      copyablePhone: t.status == TransferStatus.toDelivery,
    );

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          from,
          const SizedBox(height: AppSpacing.sm),
          to,
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: from),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: to),
        ],
      ),
    );
  }
}

class _PartyCard extends StatelessWidget {
  const _PartyCard({
    required this.title,
    required this.branch,
    this.account,
    this.name,
    this.phone,
    this.info,
    required this.icon,
    required this.accentColor,
    this.copyablePhone = false,
  });

  final String title;
  final String branch;
  final String? account;
  final String? name;
  final String? phone;
  final String? info;
  final IconData icon;
  final Color accentColor;
  final bool copyablePhone;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    Widget kv(String label, String? value) {
      final v = (value ?? '').trim();
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 12, height: 1.35),
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(color: secondary),
              ),
              TextSpan(
                text: v,
                style: TextStyle(
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: accentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            branch,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          kv('Счёт', account),
          kv('Имя', name),
          _phoneRow(context, phone),
          kv('Реквизиты', info),
        ],
      ),
    );
  }

  Widget _phoneRow(BuildContext context, String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    if (!copyablePhone) {
      // Стандартное отображение, как у остальных kv-полей.
      final isDark = context.isDark;
      final secondary =
          isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 12, height: 1.35),
            children: [
              TextSpan(text: 'Телефон: ', style: TextStyle(color: secondary)),
              TextSpan(
                text: v,
                style: TextStyle(
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // Версия с кнопкой копирования — для confirmed-перевода, чтобы
    // бухгалтер мог быстро забрать номер при выдаче.
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final primary = isDark
        ? AppColors.darkTextPrimary
        : AppColors.lightTextPrimary;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, height: 1.35),
                children: [
                  TextSpan(
                    text: 'Телефон: ',
                    style: TextStyle(color: secondary),
                  ),
                  TextSpan(text: v, style: TextStyle(color: primary)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: v));
              if (!context.mounted) return;
              context.showSuccessSnackBar('Телефон $v скопирован');
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                AppIcons.copy,
                size: 14,
                color: accentColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitPartsBlock extends StatelessWidget {
  const _SplitPartsBlock({
    required this.transfer,
    required this.accountNameResolver,
  });

  final Transfer transfer;
  final String Function(String) accountNameResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final parts = t.transferParts ?? const [];
    if (parts.isEmpty) return const SizedBox.shrink();

    final isDark = context.isDark;
    final headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      color: isDark
          ? AppColors.darkTextSecondary
          : AppColors.lightTextSecondary,
    );

    // Per-currency totals (e.g. 500 USD + 30 000 RUB)
    final byCurrency = <String, double>{};
    for (final p in parts) {
      byCurrency[p.currency] = (byCurrency[p.currency] ?? 0) + p.amount;
    }

    return _SectionCard(
      title: 'Разделение по счетам отправителя',
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('Счёт', style: headerStyle)),
                Expanded(flex: 3,
                    child: Text('Сумма', style: headerStyle, textAlign: TextAlign.right)),
                Expanded(flex: 2,
                    child: Text('Валюта', style: headerStyle, textAlign: TextAlign.center)),
              ],
            ),
          ),
          const Divider(height: 1),
          // Parts
          ...parts.map((p) {
            final accName = p.accountName.isNotEmpty
                ? p.accountName
                : accountNameResolver(p.accountId);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Text(
                      accName,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      p.amount.formatCurrencyNoDecimals(),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      p.currency,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  'Итого:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                  ),
                ),
                ...byCurrency.entries.map((e) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${e.value.formatCurrencyNoDecimals()} ${e.key}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountsBlock extends StatelessWidget {
  const _AmountsBlock({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final recvCur = t.toCurrency ?? t.currency;
    final isCross = recvCur != t.currency;
    final receiverAmount = t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;

    Widget metric(String label, String value, {Color? color}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: secondary, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFamily: 'JetBrains Mono',
              color: color,
            ),
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'Сумма перевода',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: metric(
                  'Списание (Дебет)',
                  '${t.totalDebitAmount.formatCurrencyNoDecimals()} ${t.currency}',
                  color: const Color(0xFFE53935),
                ),
              ),
              if (isCross)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      const Icon(AppIcons.swap_horiz, size: 18),
                      Text(
                        '×${t.exchangeRate}',
                        style: TextStyle(fontSize: 10, color: secondary),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: metric(
                    'Получит (Кредит)',
                    '${receiverAmount.formatCurrencyNoDecimals()} $recvCur',
                    color: const Color(0xFF43A047),
                  ),
                ),
              ),
            ],
          ),
          if (isCross) ...[
            const SizedBox(height: 8),
            Text(
              'Курс ${t.currency} → $recvCur: ${t.exchangeRate}    •    Конвертированная сумма: ${t.convertedAmount.formatCurrencyNoDecimals()} $recvCur',
              style: TextStyle(fontSize: 11, color: secondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommissionBlock extends StatelessWidget {
  const _CommissionBlock({required this.transfer});
  final Transfer transfer;

  String _modeLabel(CommissionMode m) {
    switch (m) {
      case CommissionMode.fromSender:
        return 'Отдельно с отправителя';
      case CommissionMode.fromTransfer:
        return 'Внутри суммы перевода';
      case CommissionMode.toReceiver:
        return 'Сверх суммы (получателю)';
      case CommissionMode.fromAccount:
        return 'Со второго счёта филиала';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return _SectionCard(
      title: 'Комиссия',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${t.commission.formatCurrencyNoDecimals()} ${t.commissionCurrency}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const SizedBox(width: 10),
              if (t.commissionType == CommissionType.percentage)
                _Pill(label: '${t.commissionValue}%', color: AppColors.warning)
              else
                const _Pill(label: 'Фикс.', color: Colors.blueGrey),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Режим: ${_modeLabel(t.commissionMode)}',
            style: TextStyle(fontSize: 12, color: secondary),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SignaturesBlock extends StatelessWidget {
  const _SignaturesBlock({required this.transfer, required this.userResolver});
  final Transfer transfer;
  final String Function(String?) userResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final rows = <(String, String, IconData, Color)>[];
    rows.add((
      'Создал',
      '${userResolver(t.createdBy)} • ${t.createdAt.historyFormatted}',
      AppIcons.add_box,
      Colors.blueGrey,
    ));
    if (t.confirmedAt != null) {
      rows.add((
        'Принял',
        '${userResolver(t.confirmedBy)} • ${t.confirmedAt!.historyFormatted}',
        AppIcons.check_circle_outline,
        AppColors.success,
      ));
    }
    if (t.dispatchedAt != null) {
      final courier = [
        if (t.courierName != null && t.courierName!.isNotEmpty) t.courierName,
        if (t.courierPhone != null && t.courierPhone!.isNotEmpty) t.courierPhone,
      ].whereType<String>().join(' • ');
      final tail = courier.isNotEmpty ? '\nКурьер: $courier' : '';
      rows.add((
        'Отдал курьеру',
        '${userResolver(t.dispatchedBy)} • ${t.dispatchedAt!.historyFormatted}$tail',
        AppIcons.local_shipping,
        AppColors.info,
      ));
    }
    if (t.issuedAt != null) {
      rows.add((
        'Выдал',
        '${userResolver(t.issuedBy)} • ${t.issuedAt!.historyFormatted}',
        AppIcons.payments,
        AppColors.primary,
      ));
    }

    return _SectionCard(
      title: 'Подписи и операции',
      child: Column(
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(r.$3, size: 16, color: r.$4),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: Text(
                      r.$1,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r.$2,
                      style: const TextStyle(fontSize: 12, height: 1.4),
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

/// Progress + history block for partial issuance. Pulls tranches from
/// `transfer_issuances` via the repository realtime stream so the list
/// updates instantly when another user issues a tranche.
class _PayoutProgressBlock extends StatelessWidget {
  const _PayoutProgressBlock({
    required this.transfer,
    required this.userResolver,
    this.accountResolver,
  });

  final Transfer transfer;
  final String Function(String?) userResolver;
  final String Function(String)? accountResolver;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final cur = t.toCurrency ?? t.currency;
    final total = t.convertedAmount;
    final issued = t.issuedAmount;
    final remaining = (total - issued).clamp(0.0, double.infinity);
    final progress = total > 0 ? (issued / total).clamp(0.0, 1.0) : 0.0;

    String label;
    Color barColor;
    if (t.isDelivered) {
      label = 'Полностью выдано';
      barColor = Colors.teal;
    } else if (issued > 0) {
      label = 'Частично выдано';
      barColor = AppColors.warning;
    } else {
      label = 'Ожидает выдачи';
      barColor = AppColors.success;
    }

    return _SectionCard(
      title: 'Выдача получателю',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$label: ${issued.formatCurrencyNoDecimals()} / ${total.formatCurrencyNoDecimals()} $cur',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: barColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor:
                  (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          if (remaining > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Остаток к выдаче: ${remaining.formatCurrencyNoDecimals()} $cur',
              style: TextStyle(fontSize: 12, color: secondary),
            ),
          ],
          const SizedBox(height: 12),
          StreamBuilder<List<TransferIssuance>>(
            stream: sl<TransferRepository>().watchIssuances(t.id),
            builder: (ctx, snap) {
              final list = snap.data ?? const <TransferIssuance>[];
              if (list.isEmpty) {
                return Text(
                  snap.connectionState == ConnectionState.waiting
                      ? 'Загрузка истории выдач…'
                      : 'Выдач ещё не было.',
                  style: TextStyle(fontSize: 12, color: secondary),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'История выдач (${list.length})',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: secondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (var i = 0; i < list.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.teal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.teal,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${list[i].amount.formatCurrencyNoDecimals()} ${list[i].currency}'
                                  '   •   ${list[i].issuedAt.historyFormatted}'
                                  '   •   ${userResolver(list[i].issuedBy)}',
                                  style: const TextStyle(fontSize: 12, height: 1.35),
                                ),
                                if (list[i].fromAccountId != null &&
                                    accountResolver != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        Icon(AppIcons.credit_card,
                                            size: 12, color: secondary),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            'Со счёта: ${accountResolver!(list[i].fromAccountId!)}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: secondary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (list[i].note != null && list[i].note!.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      list[i].note!.trim(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: secondary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AmendmentsBlock extends StatelessWidget {
  const _AmendmentsBlock({required this.transfer, required this.userResolver});
  final Transfer transfer;
  final String Function(String?) userResolver;

  String _formatChange(MapEntry<String, dynamic> e) {
    final v = e.value;
    if (v is Map) {
      final from = v['from']?.toString() ?? '—';
      final to = v['to']?.toString() ?? '—';
      return '${e.key}: $from → $to';
    }
    return '${e.key}: $v';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return _SectionCard(
      title: 'История изменений',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in transfer.amendmentHistory)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: AppColors.warning,
                      width: 3,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${userResolver(e.userId)} • ${e.at.historyFormatted}',
                      style: TextStyle(
                        fontSize: 11,
                        color: secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (e.changes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      ...e.changes.entries.map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _formatChange(c),
                            style: const TextStyle(
                                fontSize: 12, height: 1.35),
                          ),
                        ),
                      ),
                    ],
                    if (e.note != null && e.note!.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Прим.: ${e.note!.trim()}',
                        style: TextStyle(
                            fontSize: 12, color: secondary, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact payout progress shown inside a transfer card on the list view.
/// Designed to stay glanceable when there are thousands of transfers per day.
class _CardPayoutProgress extends StatelessWidget {
  const _CardPayoutProgress({required this.transfer});
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final isDark = context.isDark;
    final secondary =
        isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final cur = t.toCurrency ?? t.currency;
    final total = t.convertedAmount;
    final issued = t.issuedAmount;
    final remaining = (total - issued).clamp(0.0, double.infinity);
    final progress = total > 0 ? (issued / total).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(AppIcons.payments, size: 14, color: Colors.teal),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Выдано ${issued.formatCurrencyNoDecimals()} / ${total.formatCurrencyNoDecimals()} $cur',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${(progress * 100).toStringAsFixed(0)}%   •   ост. ${remaining.formatCurrencyNoDecimals()} $cur',
              style: TextStyle(fontSize: 11, color: secondary),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor:
                (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
            valueColor: AlwaysStoppedAnimation(
              progress >= 1 ? Colors.teal : AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }
}

/// Result of a partial-issue dialog: the amount entered and an optional note.
class _PartialIssueResult {
  final double amount;
  final String? note;
  final String? fromAccountId;
  const _PartialIssueResult(this.amount, this.note, this.fromAccountId);
}

class _PartialIssueDialog extends StatefulWidget {
  const _PartialIssueDialog({
    required this.transactionCode,
    required this.remaining,
    required this.currency,
    required this.alreadyIssued,
    required this.totalAmount,
    this.payoutAccounts = const [],
    this.balances = const {},
    this.presetFullRemaining = false,
  });

  final String transactionCode;
  final double remaining;
  final String currency;
  final double alreadyIssued;
  final double totalAmount;

  /// Счета получающего филиала, из которых можно выдать (карта/наличные).
  final List<BranchAccount> payoutAccounts;

  /// Балансы по `account_id` для подсказки оператору, хватит ли денег
  /// в кассе/на карте на выдачу. Передаётся из `DashboardBloc.state.
  /// accountBalances`. Если карта пуста — баланс просто не показывается.
  final Map<String, double> balances;

  /// Если true — поле «сумма выдачи» автозаполняется остатком (для кейса
  /// «Выдать всё/остаток» из карточки перевода). Оператор всё ещё может
  /// поправить значение или выбрать другой счёт.
  final bool presetFullRemaining;

  @override
  State<_PartialIssueDialog> createState() => _PartialIssueDialogState();
}

class _PartialIssueDialogState extends State<_PartialIssueDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _submitting = false;
  String? _accountId;

  @override
  void initState() {
    super.initState();
    // Преселект: первый счёт нужной валюты с положительным балансом,
    // иначе первый счёт нужной валюты, иначе первый из списка.
    final list = widget.payoutAccounts;
    if (list.isNotEmpty) {
      final match = list.where((a) => a.currency == widget.currency).toList();
      BranchAccount picked;
      if (match.isNotEmpty) {
        // Среди подходящих по валюте — отдаём предпочтение тому, на котором
        // достаточно денег (баланс ≥ суммы к выдаче), иначе первому.
        final solvent = match.firstWhere(
          (a) => (widget.balances[a.id] ?? 0) >= widget.remaining,
          orElse: () => match.first,
        );
        picked = solvent;
      } else {
        picked = list.first;
      }
      _accountId = picked.id;
    }
    if (widget.presetFullRemaining) {
      _amountCtrl.text = widget.remaining.toStringAsFixed(2);
    }
  }

  void _quickAmount(double v) {
    _amountCtrl.text = v.toStringAsFixed(2);
    _formKey.currentState?.validate();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.currency;
    final remaining = widget.remaining;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(AppIcons.payments, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(child: Text('Выдача ${widget.transactionCode}')),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Сумма перевода: ${widget.totalAmount.formatCurrencyNoDecimals()} $cur',
                        style: const TextStyle(fontSize: 12)),
                    Text('Уже выдано: ${widget.alreadyIssued.formatCurrencyNoDecimals()} $cur',
                        style: const TextStyle(fontSize: 12)),
                    Text(
                      'К выдаче: ${remaining.formatCurrencyNoDecimals()} $cur',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Сумма выдачи *',
                  border: const OutlineInputBorder(),
                  suffixText: cur,
                ),
                onChanged: (_) => setState(() {}),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Введите сумму';
                  final parsed = double.tryParse(v.replaceAll(',', '.').trim());
                  if (parsed == null) return 'Некорректная сумма';
                  if (parsed <= 0) return 'Сумма должна быть больше нуля';
                  if (parsed > remaining + 1e-6) {
                    return 'Не больше ${remaining.formatCurrencyNoDecimals()} $cur';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _QuickChip(
                    label: '25%',
                    onTap: () => _quickAmount(remaining * 0.25),
                  ),
                  _QuickChip(
                    label: '50%',
                    onTap: () => _quickAmount(remaining * 0.5),
                  ),
                  _QuickChip(
                    label: '75%',
                    onTap: () => _quickAmount(remaining * 0.75),
                  ),
                  _QuickChip(
                    label: 'Весь остаток',
                    primary: true,
                    onTap: () => _quickAmount(remaining),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (widget.payoutAccounts.isNotEmpty) ...[
                _PayoutAccountPicker(
                  accounts: widget.payoutAccounts,
                  balances: widget.balances,
                  expectedCurrency: widget.currency,
                  amount: double.tryParse(
                          _amountCtrl.text.replaceAll(',', '.').trim()) ??
                      0,
                  selectedId: _accountId,
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() => _accountId = v),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              TextFormField(
                controller: _noteCtrl,
                decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)',
                  border: OutlineInputBorder(),
                  hintText: 'Например: первая часть, наличными',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(null),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _submitting
              ? null
              : () {
                  if (!_formKey.currentState!.validate()) return;
                  // Account picker не FormField — валидируем явно. Если
                  // в payoutAccounts вообще ничего нет, RPC сам ругнётся,
                  // но для UX это редкий кейс (значит у филиала вообще нет
                  // счетов в нужной валюте — нужно сначала их создать).
                  if (widget.payoutAccounts.isNotEmpty &&
                      (_accountId == null || _accountId!.isEmpty)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Выберите счёт, с которого выдаёте (карта или касса)'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }
                  setState(() => _submitting = true);
                  final amount = double.parse(
                      _amountCtrl.text.replaceAll(',', '.').trim());
                  final note = _noteCtrl.text.trim();
                  Navigator.of(context).pop(_PartialIssueResult(
                    amount,
                    note.isEmpty ? null : note,
                    _accountId,
                  ));
                },
          style: FilledButton.styleFrom(backgroundColor: Colors.teal),
          icon: const Icon(AppIcons.check, size: 18),
          label: const Text('Выдать'),
        ),
      ],
    );
  }
}

/// Профессиональный picker счёта-источника при выдаче перевода.
///
/// Зачем не Dropdown: оператор-кассир должен с одного взгляда видеть тип
/// счёта (наличные/карта/резерв), его валюту и текущий баланс — иначе
/// он легко выберет, например, валютную карту вместо рублёвой кассы и
/// получит ошибку валюты, или попробует выдать там, где денег нет.
///
/// Поведение:
///  * Подсвечивает выбранный счёт.
///  * Метит красным «недостаточно средств», если введённая сумма больше
///    баланса (если баланс известен — `Map<accountId, balance>`).
///  * Метит серым счета не той валюты — их трогать нельзя, RPC отклонит.
///  * Полностью клавиатурно-доступен (RadioListTile внутри).
class _PayoutAccountPicker extends StatelessWidget {
  const _PayoutAccountPicker({
    required this.accounts,
    required this.balances,
    required this.expectedCurrency,
    required this.amount,
    required this.selectedId,
    required this.onChanged,
  });

  final List<BranchAccount> accounts;
  final Map<String, double> balances;
  final String expectedCurrency;
  final double amount;
  final String? selectedId;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Сортируем: сначала своя валюта, потом наличные/карта/резерв/транзит,
    // чтобы кассир сразу увидел подходящие варианты.
    final sorted = [...accounts]..sort((a, b) {
        int curRank(BranchAccount x) => x.currency == expectedCurrency ? 0 : 1;
        int typeRank(BranchAccount x) {
          switch (x.type) {
            case AccountType.cash:
              return 0;
            case AccountType.card:
              return 1;
            case AccountType.reserve:
              return 2;
            case AccountType.transit:
              return 3;
          }
        }
        final byCur = curRank(a).compareTo(curRank(b));
        if (byCur != 0) return byCur;
        final byType = typeRank(a).compareTo(typeRank(b));
        if (byType != 0) return byType;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            'Откуда выдаём *',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final a in sorted)
                  _PayoutAccountTile(
                    account: a,
                    balance: balances[a.id],
                    expectedCurrency: expectedCurrency,
                    amount: amount,
                    selected: a.id == selectedId,
                    onTap: onChanged == null
                        ? null
                        : () => onChanged!(a.id),
                  ),
              ],
            ),
          ),
        ),
        if (selectedId == null || selectedId!.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              'Выберите счёт',
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
          ),
      ],
    );
  }
}

class _PayoutAccountTile extends StatelessWidget {
  const _PayoutAccountTile({
    required this.account,
    required this.balance,
    required this.expectedCurrency,
    required this.amount,
    required this.selected,
    required this.onTap,
  });

  final BranchAccount account;
  final double? balance;
  final String expectedCurrency;
  final double amount;
  final bool selected;
  final VoidCallback? onTap;

  IconData get _typeIcon {
    switch (account.type) {
      case AccountType.cash:
        return AppIcons.payments;
      case AccountType.card:
        return AppIcons.credit_card;
      case AccountType.reserve:
        return AppIcons.lock_outline;
      case AccountType.transit:
        return AppIcons.local_shipping;
    }
  }

  Color _typeColor(BuildContext context) {
    switch (account.type) {
      case AccountType.cash:
        return Colors.green;
      case AccountType.card:
        return Colors.blue;
      case AccountType.reserve:
        return Colors.orange;
      case AccountType.transit:
        return Colors.purple;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wrongCurrency = account.currency != expectedCurrency;
    final lowBalance = balance != null && amount > 0 && balance! < amount;
    final disabled = wrongCurrency || onTap == null;
    final tint = _typeColor(context);

    final cardLabel = account.cardLast4 != null && account.cardLast4!.isNotEmpty
        ? '•••${account.cardLast4}'
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? tint.withValues(alpha: 0.10)
            : (disabled
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? tint
                    : scheme.outline.withValues(alpha: 0.20),
                width: selected ? 1.4 : 0.6,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(_typeIcon, size: 18, color: tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.name,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: disabled
                                    ? scheme.onSurfaceVariant
                                    : scheme.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: tint.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              account.type.displayName,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: tint,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            account.currency,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'JetBrains Mono',
                              fontWeight: FontWeight.w700,
                              color: wrongCurrency
                                  ? scheme.error
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          if (cardLabel != null)
                            Text(
                              cardLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'JetBrains Mono',
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          if (balance != null)
                            Text(
                              'Баланс: ${balance!.formatCurrencyNoDecimals()}',
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'JetBrains Mono',
                                color: lowBalance
                                    ? scheme.error
                                    : scheme.onSurfaceVariant,
                                fontWeight: lowBalance
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          if (wrongCurrency)
                            Text(
                              'не та валюта',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (lowBalance && !wrongCurrency)
                            Text(
                              'недостаточно',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IgnorePointer(
                  ignoring: disabled,
                  child: RadioGroup<bool>(
                    groupValue: selected ? true : null,
                    onChanged: (_) => onTap?.call(),
                    child: const Radio<bool>(
                      value: true,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: primary
              ? Colors.teal.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: primary ? Colors.teal : Colors.transparent,
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: primary ? Colors.teal : null,
          ),
        ),
      ),
    );
  }
}

/// Контактный autocomplete + горизонтальный pipeline статусов над таблицей.
///
/// Autocomplete тянет клиентов из БД и подсказывает по совпадению имени
/// или телефона. Выбор клиента ставит client-side фильтр в Trina на 4
/// колонки (отправитель/получатель × имя/телефон) — встроенные per-column
/// фильтры Trina остаются доступны для тонкой настройки.
class _ContactPipelineRow extends StatefulWidget {
  const _ContactPipelineRow({
    required this.onContactSelected,
    required this.statusFilter,
    required this.onStatusSelected,
  });

  final ValueChanged<Client?> onContactSelected;
  final TransferStatus? statusFilter;
  final ValueChanged<TransferStatus?> onStatusSelected;

  @override
  State<_ContactPipelineRow> createState() => _ContactPipelineRowState();
}

class _ContactPipelineRowState extends State<_ContactPipelineRow> {
  Client? _selected;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final isMobile = !context.isDesktop;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StreamBuilder<List<Client>>(
            stream: sl<ClientRemoteDataSource>().watchClients(),
            builder: (ctx, snap) {
              final clients = snap.data ?? const <Client>[];
              return Autocomplete<Client>(
                displayStringForOption: (c) =>
                    c.phone.isNotEmpty ? '${c.name} • ${c.phone}' : c.name,
                optionsBuilder: (TextEditingValue v) {
                  final q = v.text.trim().toLowerCase();
                  if (q.isEmpty) return const Iterable<Client>.empty();
                  final phoneQ = q.replaceAll(RegExp(r'\D'), '');
                  return clients.where((c) {
                    final n = c.name.toLowerCase();
                    final p = c.phone.replaceAll(RegExp(r'\D'), '');
                    return n.contains(q) ||
                        (phoneQ.isNotEmpty && p.contains(phoneQ));
                  }).take(15);
                },
                onSelected: (c) {
                  setState(() => _selected = c);
                  widget.onContactSelected(c);
                },
                fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      hintText: snap.connectionState == ConnectionState.waiting
                          ? 'Загрузка контактов…'
                          : 'Найти клиента — имя или телефон…',
                      prefixIcon: const Icon(AppIcons.search, size: 18),
                      suffixIcon: (controller.text.isEmpty && _selected == null)
                          ? null
                          : IconButton(
                              icon: const Icon(AppIcons.close, size: 18),
                              tooltip: 'Сбросить',
                              onPressed: () {
                                controller.clear();
                                setState(() => _selected = null);
                                widget.onContactSelected(null);
                              },
                            ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      filled: true,
                      fillColor: (isDark ? Colors.white : Colors.black)
                          .withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? AppColors.darkBorder
                              : AppColors.lightBorder,
                          width: 0.5,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? AppColors.darkBorder
                              : AppColors.lightBorder,
                          width: 0.5,
                        ),
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  );
                },
                optionsViewBuilder: (ctx, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 280,
                          maxWidth: 480,
                          minWidth: 280,
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (ctx, i) {
                            final c = options.elementAt(i);
                            return ListTile(
                              dense: true,
                              leading: const Icon(AppIcons.person_outline, size: 18),
                              title: Text(
                                c.name,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                [
                                  if (c.phone.isNotEmpty) c.phone,
                                  if (c.country.isNotEmpty) c.country,
                                ].join(' • '),
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: c.clientCode.isNotEmpty
                                  ? Text(
                                      c.clientCode,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontFamily: 'JetBrains Mono',
                                      ),
                                    )
                                  : null,
                              onTap: () => onSelected(c),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          SizedBox(height: AppSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PipelineChip(
                  label: 'Все',
                  color: AppColors.primary,
                  icon: AppIcons.inbox,
                  selected: widget.statusFilter == null,
                  onTap: () => widget.onStatusSelected(null),
                ),
                const SizedBox(width: 6),
                for (final s in TransferStatus.values) ...[
                  _PipelineStepArrow(),
                  const SizedBox(width: 6),
                  _PipelineChip(
                    label: TransferStatusStyle.of(s).label,
                    color: TransferStatusStyle.of(s).color,
                    icon: TransferStatusStyle.of(s).icon,
                    selected: widget.statusFilter == s,
                    onTap: () => widget.onStatusSelected(
                        widget.statusFilter == s ? null : s),
                  ),
                  const SizedBox(width: 6),
                ],
                if (!isMobile) const SizedBox(width: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PipelineChip extends StatelessWidget {
  const _PipelineChip({
    required this.label,
    required this.color,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final bg = selected
        ? color.withValues(alpha: 0.18)
        : (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04);
    final border = selected
        ? color.withValues(alpha: 0.6)
        : (isDark ? AppColors.darkBorder : AppColors.lightBorder);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? color
                      : (isDark
                          ? AppColors.darkTextSecondary
                          : AppColors.lightTextSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PipelineStepArrow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Icon(
      AppIcons.chevron_right,
      size: 14,
      color: (context.isDark
              ? AppColors.darkTextSecondary
              : AppColors.lightTextSecondary)
          .withValues(alpha: 0.5),
    );
  }
}


/// Лёгкий снимок партнёра (counterparty) для быстрого поиска по id.
/// Грузится один раз в _TransfersPageState — не тащим тяжёлую сущность
/// `_Counterparty` из counterparties_page (она private + содержит saldo).
class _PartnerLite {
  const _PartnerLite({required this.name, this.city});
  final String name;
  final String? city;
}

