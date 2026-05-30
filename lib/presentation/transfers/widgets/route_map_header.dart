import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/presentation/transfers/widgets/live_receipt_preview.dart'
    show flagForBranchCountry, shortBranchCode;

/// Visual from→to branch picker matching the `transfer-create-desktop` route
/// header. Two flag-pinned cards with a swap button between, tapping either
/// card opens a search-able branch picker sheet.
///
/// Pure presentational — owns no state. Reads `selectedFromId/selectedToId`,
/// reports changes via callbacks so the parent BLoC-tied form stays
/// authoritative.
class RouteMapHeader extends StatelessWidget {
  const RouteMapHeader({
    super.key,
    required this.fromBranches,
    required this.toBranches,
    required this.selectedFromId,
    required this.selectedToId,
    required this.onFromChanged,
    required this.onToChanged,
    this.fromLocked = false,
  });

  /// Branches the operator is allowed to send FROM.
  final List<Branch> fromBranches;

  /// Branches that may be the receiver (usually all minus the active "from").
  final List<Branch> toBranches;

  final String? selectedFromId;
  final String? selectedToId;
  final ValueChanged<String> onFromChanged;
  final ValueChanged<String> onToChanged;

  /// When true the FROM card is non-tappable (accountant is pinned).
  final bool fromLocked;

  Branch? _byId(List<Branch> list, String? id) {
    if (id == null) return null;
    for (final b in list) {
      if (b.id == id) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Receiver list always excludes the currently selected sender to avoid
    // self-transfers; if `toBranches` is already pre-filtered upstream we
    // still run the guard cheaply.
    final allFrom = fromBranches;
    final allTo = toBranches.where((b) => b.id != selectedFromId).toList();
    final fromBranch = _byId(allFrom, selectedFromId) ??
        _byId([...allFrom, ...allTo], selectedFromId);
    final toBranch = _byId(allTo, selectedToId) ??
        _byId([...allFrom, ...allTo], selectedToId);

    // LayoutBuilder was removed: on Flutter web a LayoutBuilder that wraps
    // many InkWell/MouseRegion children re-creates those regions on layout
    // pass, racing with mouse_tracker.updateAllDevices and tripping the
    // `_debugDuringDeviceUpdate` assertion. RouteMapHeader is used only on
    // the desktop hero path where width is always > 560 px, so the wide
    // row layout is always correct here.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _BranchCard(
            pos: _RoutePos.from,
            branch: fromBranch,
            accent: AppColors.warning,
            locked: fromLocked,
            onTap: fromLocked
                ? null
                : () => _openPicker(
                      context,
                      title: 'Откуда',
                      branches: allFrom,
                      selectedId: selectedFromId,
                      onPicked: onFromChanged,
                    ),
          ),
        ),
        const _DashedConnector(),
        _SwapButton(
          enabled: !fromLocked &&
              selectedFromId != null &&
              selectedToId != null,
          onTap: () {
            if (selectedFromId == null || selectedToId == null) return;
            final f = selectedFromId!;
            final t = selectedToId!;
            onFromChanged(t);
            onToChanged(f);
          },
        ),
        const _DashedConnector(),
        Expanded(
          child: _BranchCard(
            pos: _RoutePos.to,
            branch: toBranch,
            accent: AppColors.primary,
            onTap: () => _openPicker(
              context,
              title: 'Куда',
              branches: allTo,
              selectedId: selectedToId,
              onPicked: onToChanged,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openPicker(
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _BranchPickerSheet(
        title: title,
        branches: branches,
        selectedId: selectedId,
      ),
    );
    if (picked != null) onPicked(picked);
  }
}

enum _RoutePos { from, to }

class _BranchCard extends StatelessWidget {
  const _BranchCard({
    required this.pos,
    required this.branch,
    required this.accent,
    required this.onTap,
    this.locked = false,
  });
  final _RoutePos pos;
  final Branch? branch;
  final Color accent;
  final VoidCallback? onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final label = pos == _RoutePos.from ? 'ОТКУДА' : 'КУДА';
    final code = branch != null
        ? shortBranchCode(branch!.name, explicitCode: branch!.code)
        : '—';
    final flag = flagForBranchCountry(branch?.address);
    final country = _country(branch?.address);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 14, 16),
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.darkBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 54,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: AppColors.darkCardHover,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(flag, style: const TextStyle(fontSize: 28)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          label,
                          style: GoogleFonts.inter(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.darkSurface,
                            border: Border.all(color: AppColors.darkBorder),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            code,
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: AppColors.darkTextSecondary,
                            ),
                          ),
                        ),
                        if (locked) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            AppIcons.lock_outline,
                            size: 11,
                            color: AppColors.darkTextTertiary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      branch?.name ?? 'Выбрать филиал',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: branch == null
                            ? AppColors.darkTextTertiary
                            : AppColors.darkTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      country,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: AppColors.darkTextTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: AppColors.darkTextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _country(String? address) {
    if (address == null || address.isEmpty) return '—';
    // Address is free-form; try to surface the first comma-separated chunk
    // (usually country or city).
    final firstChunk = address.split(',').first.trim();
    if (firstChunk.isNotEmpty) return firstChunk;
    return address.length > 32 ? '${address.substring(0, 32)}…' : address;
  }
}

class _DashedConnector extends StatelessWidget {
  const _DashedConnector();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      child: CustomPaint(
        size: const Size(36, 20),
        painter: _DashPainter(),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.darkBorder
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 4.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(0, size.width), y), p);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _SwapButton extends StatelessWidget {
  const _SwapButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    // Tooltip was removed: on Flutter web a Tooltip whose message changes
    // when [enabled] flips can trigger the `_debugDuringDeviceUpdate`
    // assertion (mouse_tracker.dart:199) — the InkWell already gives a
    // clear hover affordance, so the tooltip was redundant.
    final color =
        enabled ? AppColors.primary : AppColors.darkTextTertiary;
    return Material(
      color: AppColors.darkCardHover,
      shape: const CircleBorder(side: BorderSide(color: AppColors.darkBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(AppIcons.swap_horiz, size: 20, color: color),
        ),
      ),
    );
  }
}

class _BranchPickerSheet extends StatefulWidget {
  const _BranchPickerSheet({
    required this.title,
    required this.branches,
    required this.selectedId,
  });
  final String title;
  final List<Branch> branches;
  final String? selectedId;

  @override
  State<_BranchPickerSheet> createState() => _BranchPickerSheetState();
}

class _BranchPickerSheetState extends State<_BranchPickerSheet> {
  late final TextEditingController _query = TextEditingController();
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
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            minHeight: 320,
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
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Text(
                      widget.title,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(AppIcons.close, size: 18),
                      color: AppColors.darkTextTertiary,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: (v) => setState(() => _q = v),
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: AppColors.darkTextPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Поиск по названию, коду или адресу…',
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
                        padding: const EdgeInsets.all(AppSpacing.xl),
                        child: Text(
                          'Ничего не найдено',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.darkTextTertiary,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (ctx, i) {
                          final b = filtered[i];
                          final active = b.id == widget.selectedId;
                          return Material(
                            color: active
                                ? AppColors.primarySurface
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => Navigator.of(context).pop(b.id),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    10, 9, 10, 9),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: AppColors.darkSurface,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        flagForBranchCountry(b.address),
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ),
                                    const SizedBox(width: 11),
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
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  AppColors.darkTextPrimary,
                                            ),
                                          ),
                                          if (b.address != null &&
                                              b.address!.isNotEmpty)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 1),
                                              child: Text(
                                                b.address!,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: GoogleFonts.inter(
                                                  fontSize: 11,
                                                  color: AppColors
                                                      .darkTextTertiary,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.darkSurface,
                                        border: Border.all(
                                            color: AppColors.darkBorder),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        shortBranchCode(b.name,
                                            explicitCode: b.code),
                                        style: GoogleFonts.jetBrainsMono(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.darkTextSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
