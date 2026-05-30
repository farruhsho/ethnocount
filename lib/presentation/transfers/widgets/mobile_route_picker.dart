import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/presentation/transfers/widgets/live_receipt_preview.dart'
    show flagForBranchCountry, shortBranchCode;

/// Compact horizontal from→swap→to route picker matching
/// `transfer-create-mobile`. Tap on a chip opens a bottom-sheet branch
/// picker; tap on the centre circle swaps from/to.
///
/// Picker UI is intentionally compact: 32-px flag tile, accent stripe on
/// the left, short city name + uppercase position label. Bottom sheet is
/// inlined (no `showModalBottomSheet` import surface here) so the entire
/// flow is testable as a single widget tree.
class MobileRoutePicker extends StatelessWidget {
  const MobileRoutePicker({
    super.key,
    required this.fromBranches,
    required this.toBranches,
    required this.selectedFromId,
    required this.selectedToId,
    required this.onFromChanged,
    required this.onToChanged,
    this.fromLocked = false,
  });

  final List<Branch> fromBranches;
  final List<Branch> toBranches;
  final String? selectedFromId;
  final String? selectedToId;
  final ValueChanged<String> onFromChanged;
  final ValueChanged<String> onToChanged;
  final bool fromLocked;

  Branch? _byId(String? id, List<Branch> list) {
    if (id == null) return null;
    for (final b in list) {
      if (b.id == id) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final allFrom = fromBranches;
    final allTo = toBranches.where((b) => b.id != selectedFromId).toList();
    final fromBranch = _byId(selectedFromId, [...allFrom, ...toBranches]);
    final toBranch = _byId(selectedToId, [...toBranches, ...allFrom]);
    final swapEnabled = !fromLocked &&
        selectedFromId != null &&
        selectedToId != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Chip(
              pos: _Pos.from,
              branch: fromBranch,
              accent: AppColors.warning,
              locked: fromLocked,
              onTap: fromLocked
                  ? null
                  : () => _openSheet(
                        context,
                        title: 'Откуда',
                        branches: allFrom,
                        selectedId: selectedFromId,
                        onPicked: onFromChanged,
                      ),
            ),
          ),
          const SizedBox(width: 8),
          _SwapCircle(
            enabled: swapEnabled,
            onTap: () {
              if (!swapEnabled) return;
              final f = selectedFromId!;
              final t = selectedToId!;
              onFromChanged(t);
              onToChanged(f);
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Chip(
              pos: _Pos.to,
              branch: toBranch,
              accent: AppColors.primary,
              onTap: () => _openSheet(
                context,
                title: 'Куда',
                branches: allTo,
                selectedId: selectedToId,
                onPicked: onToChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSheet(
    BuildContext context, {
    required String title,
    required List<Branch> branches,
    required String? selectedId,
    required ValueChanged<String> onPicked,
  }) async {
    if (branches.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkCard,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _BranchSheet(
        title: title,
        branches: branches,
        selectedId: selectedId,
      ),
    );
    if (picked != null) onPicked(picked);
  }
}

enum _Pos { from, to }

class _Chip extends StatelessWidget {
  const _Chip({
    required this.pos,
    required this.branch,
    required this.accent,
    required this.onTap,
    this.locked = false,
  });
  final _Pos pos;
  final Branch? branch;
  final Color accent;
  final VoidCallback? onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            border: Border(
              left: BorderSide(color: accent, width: 3),
              top: const BorderSide(color: AppColors.darkBorder),
              right: const BorderSide(color: AppColors.darkBorder),
              bottom: const BorderSide(color: AppColors.darkBorder),
            ),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.darkCardHover,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  flagForBranchCountry(branch?.address),
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          pos == _Pos.from ? 'ОТКУДА' : 'КУДА',
                          style: GoogleFonts.inter(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: accent,
                          ),
                        ),
                        if (locked) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            AppIcons.lock_outline,
                            size: 10,
                            color: AppColors.darkTextTertiary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      branch?.name ?? 'Выбрать',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: branch == null
                            ? AppColors.darkTextTertiary
                            : AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwapCircle extends StatelessWidget {
  const _SwapCircle({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.darkCardHover,
      shape:
          const CircleBorder(side: BorderSide(color: AppColors.darkBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            AppIcons.swap_horiz,
            size: 16,
            color: enabled ? AppColors.primary : AppColors.darkTextTertiary,
          ),
        ),
      ),
    );
  }
}

class _BranchSheet extends StatefulWidget {
  const _BranchSheet({
    required this.title,
    required this.branches,
    required this.selectedId,
  });
  final String title;
  final List<Branch> branches;
  final String? selectedId;
  @override
  State<_BranchSheet> createState() => _BranchSheetState();
}

class _BranchSheetState extends State<_BranchSheet> {
  final _query = TextEditingController();
  String _q = '';
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final filtered = widget.branches.where((b) {
      if (_q.isEmpty) return true;
      final q = _q.toLowerCase();
      return b.name.toLowerCase().contains(q) ||
          b.code.toLowerCase().contains(q) ||
          (b.address?.toLowerCase().contains(q) ?? false);
    }).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
            minHeight: 300,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.darkBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: AppColors.darkTextPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(AppIcons.close, size: 18),
                      color: AppColors.darkTextTertiary,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: TextField(
                  controller: _query,
                  autofocus: false,
                  onChanged: (v) => setState(() => _q = v),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.darkTextPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Поиск…',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: AppColors.darkTextDisabled,
                    ),
                    prefixIcon: const Icon(AppIcons.search, size: 16),
                    filled: true,
                    fillColor: AppColors.darkSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.darkBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.darkBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.primary),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: filtered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          'Ничего не найдено',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.darkTextTertiary,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (ctx, i) {
                          final b = filtered[i];
                          final active = b.id == widget.selectedId;
                          return Material(
                            color: active
                                ? AppColors.primarySurface
                                : AppColors.darkSurface,
                            borderRadius: BorderRadius.circular(11),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(11),
                              onTap: () => Navigator.of(context).pop(b.id),
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: active
                                        ? AppColors.primary
                                        : AppColors.darkBorder,
                                  ),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: AppColors.darkCardHover,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        flagForBranchCountry(b.address),
                                        style: const TextStyle(fontSize: 20),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            b.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.inter(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  AppColors.darkTextPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${b.address ?? '—'} · ${shortBranchCode(b.name, explicitCode: b.code)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.inter(
                                              fontSize: 11,
                                              color:
                                                  AppColors.darkTextTertiary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (active)
                                      const Icon(
                                        AppIcons.check,
                                        size: 16,
                                        color: AppColors.primary,
                                      ),
                                  ],
                                ),
                              ),
                            ),
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
}
