import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/presentation/clients/widgets/client_list_row.dart';

/// Status filter buckets matching the design's chip set.
enum ClientFilter { all, active, debts, telegram }

/// Left "clients list" pane matching `clients-desktop`: title + "Добавить"
/// gradient CTA, 3 mini-stats (Всего / USD-экв. / Долги red), search
/// field, filter chips, scrollable [ClientListRow] body.
///
/// Stateless w.r.t. data — owns its search + filter state internally.
class ClientsListPane extends StatefulWidget {
  const ClientsListPane({
    super.key,
    required this.clients,
    required this.balances,
    required this.selectedId,
    required this.onSelect,
    required this.canCreate,
    required this.onCreate,
    this.totalUsdEquivalent = 0,
  });

  final List<Client> clients;

  /// `clientId → ClientBalance` lookup. Use the same map you stream from
  /// ClientBloc; missing entries are treated as "no balance yet".
  final Map<String, ClientBalance> balances;
  final String? selectedId;
  final ValueChanged<Client> onSelect;
  final bool canCreate;
  final VoidCallback onCreate;

  /// Pre-computed sum of all clients' balances expressed in USD. Pass `0`
  /// if you don't have an FX-aware aggregator yet — the tile then renders
  /// "$0" without breaking the layout.
  final double totalUsdEquivalent;

  @override
  State<ClientsListPane> createState() => _ClientsListPaneState();
}

class _ClientsListPaneState extends State<ClientsListPane> {
  final _searchCtrl = TextEditingController();
  String _q = '';
  ClientFilter _filter = ClientFilter.all;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isDebtor(Client c) {
    final b = widget.balances[c.id];
    if (b == null) return false;
    if (b.balance < 0) return true;
    for (final v in b.balancesByCurrency.values) {
      if (v < 0) return true;
    }
    return false;
  }

  bool _hasTelegram(Client c) =>
      c.telegramChatId != null && c.telegramChatId!.isNotEmpty;

  Iterable<Client> get _visible {
    final q = _q.trim().toLowerCase();
    return widget.clients.where((c) {
      switch (_filter) {
        case ClientFilter.active:
          if (!c.isActive) return false;
          break;
        case ClientFilter.debts:
          if (!_isDebtor(c)) return false;
          break;
        case ClientFilter.telegram:
          if (!_hasTelegram(c)) return false;
          break;
        case ClientFilter.all:
          break;
      }
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.clientCode.toLowerCase().contains(q) ||
          c.phone.contains(q);
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.clients;
    final activeCount = all.where((c) => c.isActive).length;
    final debtsCount = all.where(_isDebtor).length;
    final tgCount = all.where(_hasTelegram).length;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xCC121829),
        border: Border(
          right: BorderSide(color: AppColors.darkBorder, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            canCreate: widget.canCreate,
            onCreate: widget.onCreate,
            allCount: all.length,
            totalUsd: widget.totalUsdEquivalent,
            debtsCount: debtsCount,
            searchCtrl: _searchCtrl,
            onSearchChanged: (v) => setState(() => _q = v),
            filter: _filter,
            activeBucket: activeCount,
            debtsBucket: debtsCount,
            tgBucket: tgCount,
            onFilterChanged: (f) => setState(() => _filter = f),
          ),
          Expanded(
            child: _ListBody(
              visible: _visible.toList(),
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
              balances: widget.balances,
              hasTelegram: _hasTelegram,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.canCreate,
    required this.onCreate,
    required this.allCount,
    required this.totalUsd,
    required this.debtsCount,
    required this.searchCtrl,
    required this.onSearchChanged,
    required this.filter,
    required this.activeBucket,
    required this.debtsBucket,
    required this.tgBucket,
    required this.onFilterChanged,
  });
  final bool canCreate;
  final VoidCallback onCreate;
  final int allCount;
  final double totalUsd;
  final int debtsCount;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearchChanged;
  final ClientFilter filter;
  final int activeBucket;
  final int debtsBucket;
  final int tgBucket;
  final ValueChanged<ClientFilter> onFilterChanged;

  String _fmtCompactUsd(double v) {
    if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.darkDivider, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'КЛИЕНТСКИЕ СЧЕТА',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.darkTextDisabled,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Контрагенты',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canCreate) _AddButton(onTap: onCreate),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: 'ВСЕГО',
                  value: '$allCount',
                  accent: AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  label: 'USD-ЭКВ.',
                  value: _fmtCompactUsd(totalUsd),
                  accent: AppColors.primary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  label: 'ДОЛГИ',
                  value: '$debtsCount',
                  accent: debtsCount > 0
                      ? AppColors.error
                      : AppColors.darkTextSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SearchField(
            controller: searchCtrl,
            onChanged: onSearchChanged,
          ),
          const SizedBox(height: 10),
          _FilterChips(
            filter: filter,
            allCount: allCount,
            activeCount: activeBucket,
            debtsCount: debtsBucket,
            tgCount: tgBucket,
            onChanged: onFilterChanged,
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.4),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(AppIcons.add,
                    size: 13, color: AppColors.darkBg),
                const SizedBox(width: 6),
                Text(
                  'Добавить',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.darkBg,
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

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.accent,
  });
  final String label;
  final String value;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.darkTextDisabled,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: GoogleFonts.inter(
        fontSize: 12.5,
        color: AppColors.darkTextPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Имя, CNT, телефон…',
        hintStyle: GoogleFonts.inter(
          fontSize: 12.5,
          color: AppColors.darkTextDisabled,
        ),
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 10, right: 6),
          child: Icon(AppIcons.search,
              size: 13, color: AppColors.darkTextTertiary),
        ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 32, minHeight: 0),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(AppIcons.close, size: 12),
                color: AppColors.darkTextTertiary,
                splashRadius: 14,
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: AppColors.darkCard,
        contentPadding: const EdgeInsets.symmetric(vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.2),
        ),
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.filter,
    required this.allCount,
    required this.activeCount,
    required this.debtsCount,
    required this.tgCount,
    required this.onChanged,
  });
  final ClientFilter filter;
  final int allCount;
  final int activeCount;
  final int debtsCount;
  final int tgCount;
  final ValueChanged<ClientFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final buckets = <_BucketSpec>[
      _BucketSpec(
        active: filter == ClientFilter.all,
        label: 'Все',
        count: allCount,
        color: AppColors.darkTextSecondary,
        onTap: () => onChanged(ClientFilter.all),
      ),
      _BucketSpec(
        active: filter == ClientFilter.active,
        label: 'Активные',
        count: activeCount,
        color: AppColors.primary,
        onTap: () => onChanged(ClientFilter.active),
      ),
      _BucketSpec(
        active: filter == ClientFilter.debts,
        label: 'Долги',
        count: debtsCount,
        color: AppColors.error,
        onTap: () => onChanged(ClientFilter.debts),
      ),
      _BucketSpec(
        active: filter == ClientFilter.telegram,
        label: 'Telegram',
        count: tgCount,
        color: AppColors.telegram,
        onTap: () => onChanged(ClientFilter.telegram),
      ),
    ];
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: buckets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (ctx, i) => _Chip(spec: buckets[i]),
      ),
    );
  }
}

class _BucketSpec {
  _BucketSpec({
    required this.active,
    required this.label,
    required this.count,
    required this.color,
    required this.onTap,
  });
  final bool active;
  final String label;
  final int count;
  final Color color;
  final VoidCallback onTap;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.spec});
  final _BucketSpec spec;
  @override
  Widget build(BuildContext context) {
    final color = spec.active ? spec.color : AppColors.darkTextSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: spec.onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: spec.active
                ? spec.color.withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: spec.active ? spec.color : AppColors.darkBorder,
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                spec.label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${spec.count}',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListBody extends StatelessWidget {
  const _ListBody({
    required this.visible,
    required this.selectedId,
    required this.onSelect,
    required this.balances,
    required this.hasTelegram,
  });
  final List<Client> visible;
  final String? selectedId;
  final ValueChanged<Client> onSelect;
  final Map<String, ClientBalance> balances;
  final bool Function(Client) hasTelegram;

  @override
  Widget build(BuildContext context) {
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Ничего не найдено',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppColors.darkTextTertiary,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 3),
      itemBuilder: (ctx, i) {
        final c = visible[i];
        return ClientListRow(
          client: c,
          balance: balances[c.id],
          selected: c.id == selectedId,
          onTap: () => onSelect(c),
          hasTelegram: hasTelegram(c),
        );
      },
    );
  }
}
