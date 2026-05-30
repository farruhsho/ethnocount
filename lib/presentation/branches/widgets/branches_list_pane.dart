import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/presentation/branches/widgets/branch_list_row.dart';
import 'package:ethnocount/presentation/transfers/widgets/live_receipt_preview.dart'
    show flagForBranchCountry;

/// Status filter buckets for the list pane. Mirrors the design's chip set:
/// `all` / `active` / `warning` / `archived`. Country filters are derived
/// from branches at runtime.
enum BranchFilter { all, active, warning, archived }

/// Left "list pane" matching `branches-desktop` reference. Title + "Новый
/// филиал" gradient CTA, mini stats (Активных / Стран / USD-экв.), search
/// field, scrollable filter chip strip, and a body of [BranchListRow]s.
/// Adapts to 420 px on wide layouts, shrinks gracefully under that.
class BranchesListPane extends StatefulWidget {
  const BranchesListPane({
    super.key,
    required this.branches,
    required this.selectedId,
    required this.onSelect,
    required this.accountsCount,
    required this.balanceLookup,
    required this.canCreate,
    required this.onCreate,
    required this.staffLookup,
    required this.warningLookup,
    required this.totalUsdEquivalent,
  });

  /// All branches to render (already access-filtered by parent).
  final List<Branch> branches;
  final String? selectedId;
  final ValueChanged<Branch> onSelect;

  /// `id → number of accounts` lookup.
  final int Function(String branchId) accountsCount;

  /// `id → base-currency balance` lookup.
  final double Function(String branchId) balanceLookup;

  /// `id → staff count` lookup. Pass `(_) => 0` if you don't track staff yet.
  final int Function(String branchId) staffLookup;

  /// `id → has warning?` lookup (low reserve, drift, etc.).
  final bool Function(String branchId) warningLookup;

  /// Sum of all branches' balances expressed in USD.
  final double totalUsdEquivalent;

  final bool canCreate;
  final VoidCallback onCreate;

  @override
  State<BranchesListPane> createState() => _BranchesListPaneState();
}

class _BranchesListPaneState extends State<BranchesListPane> {
  final _searchCtrl = TextEditingController();
  String _q = '';
  BranchFilter _filter = BranchFilter.all;
  String? _countryFilter;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Iterable<Branch> get _visible {
    final q = _q.trim().toLowerCase();
    return widget.branches.where((b) {
      switch (_filter) {
        case BranchFilter.active:
          if (!b.isActive) return false;
          break;
        case BranchFilter.archived:
          if (b.isActive) return false;
          break;
        case BranchFilter.warning:
          if (!widget.warningLookup(b.id)) return false;
          break;
        case BranchFilter.all:
          break;
      }
      if (_countryFilter != null &&
          flagForBranchCountry(b.address) != _countryFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return b.name.toLowerCase().contains(q) ||
          b.code.toLowerCase().contains(q) ||
          (b.address?.toLowerCase().contains(q) ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.branches;
    final activeCount = all.where((b) => b.isActive).length;
    final countries =
        all.map((b) => flagForBranchCountry(b.address)).toSet().toList()
          ..sort();
    final warningCount =
        all.where((b) => widget.warningLookup(b.id)).length;
    final archivedCount = all.length - activeCount;

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
            activeCount: activeCount,
            countryCount: countries.length,
            totalUsd: widget.totalUsdEquivalent,
            searchCtrl: _searchCtrl,
            onSearchChanged: (v) => setState(() => _q = v),
            filter: _filter,
            countryFilter: _countryFilter,
            allCount: all.length,
            activeBucketCount: activeCount,
            warningBucketCount: warningCount,
            archivedBucketCount: archivedCount,
            countries: countries,
            countryBuckets: {
              for (final f in countries)
                f: all.where((b) => flagForBranchCountry(b.address) == f).length,
            },
            onFilterChanged: (f) {
              setState(() {
                _filter = f;
                _countryFilter = null;
              });
            },
            onCountryFilter: (f) {
              setState(() {
                _countryFilter = _countryFilter == f ? null : f;
                _filter = BranchFilter.all;
              });
            },
          ),
          Expanded(
            child: _ListBody(
              visible: _visible.toList(),
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
              accountsCount: widget.accountsCount,
              balanceLookup: widget.balanceLookup,
              staffLookup: widget.staffLookup,
              warningLookup: widget.warningLookup,
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
    required this.activeCount,
    required this.countryCount,
    required this.totalUsd,
    required this.searchCtrl,
    required this.onSearchChanged,
    required this.filter,
    required this.countryFilter,
    required this.allCount,
    required this.activeBucketCount,
    required this.warningBucketCount,
    required this.archivedBucketCount,
    required this.countries,
    required this.countryBuckets,
    required this.onFilterChanged,
    required this.onCountryFilter,
  });

  final bool canCreate;
  final VoidCallback onCreate;
  final int activeCount;
  final int countryCount;
  final double totalUsd;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearchChanged;
  final BranchFilter filter;
  final String? countryFilter;
  final int allCount;
  final int activeBucketCount;
  final int warningBucketCount;
  final int archivedBucketCount;
  final List<String> countries;
  final Map<String, int> countryBuckets;
  final ValueChanged<BranchFilter> onFilterChanged;
  final ValueChanged<String> onCountryFilter;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
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
                      'TREASURY',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.darkTextDisabled,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Филиалы',
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canCreate)
                _CreateButton(onTap: onCreate),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: 'АКТИВНЫХ',
                  value: '$activeCount',
                  accent: AppColors.primary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  label: 'СТРАН',
                  value: '$countryCount',
                  accent: AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  label: 'USD-ЭКВ.',
                  value: _fmtCompactUsd(totalUsd),
                  accent: AppColors.secondary,
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
            countryFilter: countryFilter,
            allCount: allCount,
            activeCount: activeBucketCount,
            warningCount: warningBucketCount,
            archivedCount: archivedBucketCount,
            countries: countries,
            countryBuckets: countryBuckets,
            onFilterChanged: onFilterChanged,
            onCountryFilter: onCountryFilter,
          ),
        ],
      ),
    );
  }

  String _fmtCompactUsd(double v) {
    if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }
}

class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.onTap});
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
                  'Новый филиал',
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
        hintText: 'Название, код, город…',
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
    required this.countryFilter,
    required this.allCount,
    required this.activeCount,
    required this.warningCount,
    required this.archivedCount,
    required this.countries,
    required this.countryBuckets,
    required this.onFilterChanged,
    required this.onCountryFilter,
  });
  final BranchFilter filter;
  final String? countryFilter;
  final int allCount;
  final int activeCount;
  final int warningCount;
  final int archivedCount;
  final List<String> countries;
  final Map<String, int> countryBuckets;
  final ValueChanged<BranchFilter> onFilterChanged;
  final ValueChanged<String> onCountryFilter;

  @override
  Widget build(BuildContext context) {
    final buckets = <_BucketSpec>[
      _BucketSpec(
        active: filter == BranchFilter.all && countryFilter == null,
        label: 'Все',
        count: allCount,
        color: AppColors.darkTextSecondary,
        onTap: () => onFilterChanged(BranchFilter.all),
      ),
      _BucketSpec(
        active: filter == BranchFilter.active && countryFilter == null,
        label: 'Активные',
        count: activeCount,
        color: AppColors.primary,
        onTap: () => onFilterChanged(BranchFilter.active),
      ),
      _BucketSpec(
        active: filter == BranchFilter.warning && countryFilter == null,
        label: 'Внимание',
        count: warningCount,
        color: AppColors.warning,
        onTap: () => onFilterChanged(BranchFilter.warning),
      ),
      _BucketSpec(
        active: filter == BranchFilter.archived && countryFilter == null,
        label: 'Архив',
        count: archivedCount,
        color: AppColors.darkTextDisabled,
        onTap: () => onFilterChanged(BranchFilter.archived),
      ),
      for (final f in countries)
        _BucketSpec(
          active: countryFilter == f,
          label: f,
          count: countryBuckets[f] ?? 0,
          color: AppColors.darkTextSecondary,
          onTap: () => onCountryFilter(f),
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
    final color = spec.active ? AppColors.primary : spec.color;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: spec.onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: spec.active
                ? AppColors.primarySurface
                : Colors.transparent,
            border: Border.all(
              color: spec.active ? AppColors.primary : AppColors.darkBorder,
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
    required this.accountsCount,
    required this.balanceLookup,
    required this.staffLookup,
    required this.warningLookup,
  });
  final List<Branch> visible;
  final String? selectedId;
  final ValueChanged<Branch> onSelect;
  final int Function(String) accountsCount;
  final double Function(String) balanceLookup;
  final int Function(String) staffLookup;
  final bool Function(String) warningLookup;

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
        final b = visible[i];
        return BranchListRow(
          branch: b,
          selected: b.id == selectedId,
          onTap: () => onSelect(b),
          accountsCount: accountsCount(b.id),
          staffCount: staffLookup(b.id),
          baseBalance: balanceLookup(b.id),
          hasWarning: warningLookup(b.id),
        );
      },
    );
  }
}
