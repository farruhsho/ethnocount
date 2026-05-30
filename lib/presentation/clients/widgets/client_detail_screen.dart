import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/presentation/clients/bloc/client_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/clients/widgets/convert_currency_dialog.dart';

import 'package:ethnocount/core/icons/app_icons.dart';
/// Full-screen client detail (mobile). Shows hero balance card, per-currency
/// wallets with conversion option, transactions list, and Telegram block.
class ClientDetailScreen extends StatefulWidget {
  const ClientDetailScreen({super.key, required this.clientId});

  final String clientId;

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  /// True = верхняя часть (identity + hero + wallets + actions) развёрнута.
  /// False = свёрнута, видна compact-полоска с балансом, а операции
  /// получают почти весь экран. Меняется кнопкой в AppBar.
  bool _topExpanded = true;

  @override
  void initState() {
    super.initState();
    // Подгружаем детали (balance + transactions stream).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ClientBloc>().add(ClientDetailRequested(widget.clientId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDark;

    return BlocConsumer<ClientBloc, ClientBlocState>(
      listenWhen: (a, b) =>
          a.status != b.status &&
          (b.status == ClientBlocStatus.success ||
              b.status == ClientBlocStatus.error),
      listener: (ctx, state) {
        final scaffold = ScaffoldMessenger.of(ctx);
        if (state.status == ClientBlocStatus.success &&
            state.successMessage != null) {
          scaffold.showSnackBar(SnackBar(
            content: Text(state.successMessage!),
            behavior: SnackBarBehavior.floating,
          ));
        }
        if (state.status == ClientBlocStatus.error &&
            state.errorMessage != null) {
          scaffold.showSnackBar(SnackBar(
            content: Text(state.errorMessage!),
            backgroundColor: Theme.of(ctx).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
      builder: (context, state) {
        final client = state.selectedClient?.id == widget.clientId
            ? state.selectedClient
            : state.clients
                .where((c) => c.id == widget.clientId)
                .cast<Client?>()
                .firstWhere((_) => true, orElse: () => null);

        if (client == null) {
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(AppIcons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        final balance = state.balancesByClientId[client.id] ??
            state.selectedBalance;
        final txs = state.transactions
            .where((t) => t.clientId == client.id)
            .toList();
        final txItems = _buildTxItems(txs);
        final wallets = _walletsForClient(client, balance);
        final usdEquiv = _usdEquivalent(wallets);
        final hasNegative = wallets.any((w) => w.amount < -0.0049);

        return Scaffold(
          backgroundColor: scheme.surface,
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                elevation: 0,
                scrolledUnderElevation: 0.5,
                backgroundColor: scheme.surface,
                leading: IconButton(
                  icon: const Icon(AppIcons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                actions: [
                  IconButton(
                    tooltip: _topExpanded
                        ? 'Свернуть верх — больше места операциям'
                        : 'Развернуть верх (баланс, кошельки)',
                    icon: Icon(_topExpanded
                        ? AppIcons.expand_less
                        : AppIcons.expand_more),
                    onPressed: () =>
                        setState(() => _topExpanded = !_topExpanded),
                  ),
                ],
              ),

              // Когда верх свёрнут — показываем только compact-strip
              // с балансом и кошельками-чипами (одна строка).
              if (!_topExpanded)
                SliverToBoxAdapter(
                  child: _CompactTopStrip(
                    client: client,
                    wallets: wallets,
                    usdEquiv: usdEquiv,
                  ),
                ),

              // Полный верх раскрыт.
              if (_topExpanded) ...[
                SliverToBoxAdapter(
                  child: _IdentityBlock(client: client),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                      AppSpacing.sm, AppSpacing.md, AppSpacing.md),
                  sliver: SliverToBoxAdapter(
                    child: _HeroBalanceCard(
                      client: client,
                      wallets: wallets,
                      usdEquiv: usdEquiv,
                      isNegative: hasNegative,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  sliver: SliverToBoxAdapter(
                    child: _SectionHeader(
                      title: 'Кошельки',
                      hint:
                          '${wallets.length} ${_pluralCcy(wallets.length)}',
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md),
                      itemCount: wallets.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final w = wallets[i];
                        return _WalletChip(
                          wallet: w,
                          onTap: () => _showWalletActions(
                              context, client, balance, w),
                        );
                      },
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.sm)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _ActionButtons(
                      client: client,
                      balance: balance,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                      AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
                  sliver: SliverToBoxAdapter(
                    child: _InfoCollapsible(client: client),
                  ),
                ),
              ],

              // Transactions — sticky-заголовок + lazy SliverList по строкам.
              // Большие истории (>50 операций) теперь рендерятся виртуально,
              // без перестройки всего Column на каждый скролл.
              SliverPersistentHeader(
                pinned: true,
                delegate: _StickySectionHeader(
                  background: scheme.surface,
                  title: 'Операции',
                  hint: txs.isEmpty
                      ? 'нет операций'
                      : 'последние ${txs.length}',
                ),
              ),
              if (txs.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                    AppSpacing.xl + 24,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _EmptyTxCard(isDark: isDark),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                    AppSpacing.xl + 24,
                  ),
                  sliver: DecoratedSliver(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.18),
                        width: 0.5,
                      ),
                    ),
                    sliver: SliverPadding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14),
                      sliver: SliverList.separated(
                        itemCount: txItems.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: scheme.outline.withValues(alpha: 0.15),
                        ),
                        itemBuilder: (_, i) =>
                            _TransactionRow(data: txItems[i]),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showWalletActions(
    BuildContext context,
    Client client,
    ClientBalance? balance,
    _Wallet wallet,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        wallet.currency,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Кошелёк ${wallet.currency}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${wallet.amount.formatCurrency()} ${wallet.currency}',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                              fontFamily: 'JetBrains Mono',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(AppIcons.add_circle_outline,
                    color: Colors.green),
                title: const Text('Пополнить'),
                subtitle: Text('Зачислить средства на ${wallet.currency}'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showOperationDialog(
                    context,
                    client: client,
                    isDeposit: true,
                    initialCurrency: wallet.currency,
                  );
                },
              ),
              ListTile(
                leading: const Icon(AppIcons.remove_circle_outline,
                    color: Colors.red),
                title: const Text('Списать'),
                subtitle: Text('Снять средства с ${wallet.currency}'),
                enabled: wallet.amount > 0.0049,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showOperationDialog(
                    context,
                    client: client,
                    isDeposit: false,
                    initialCurrency: wallet.currency,
                  );
                },
              ),
              ListTile(
                leading: Icon(AppIcons.swap_horiz,
                    color: scheme.primary),
                title: const Text('Конвертировать'),
                subtitle:
                    const Text('Перевести в другую валюту по своему курсу'),
                enabled: wallet.amount > 0.0049,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  showConvertCurrencyDialog(
                    context: context,
                    client: client,
                    balance: balance,
                    initialFrom: wallet.currency,
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
    );
  }

  void _showOperationDialog(
    BuildContext context, {
    required Client client,
    required bool isDeposit,
    required String initialCurrency,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<ClientBloc>(),
        child: _SimpleOperationDialog(
          client: client,
          isDeposit: isDeposit,
          initialCurrency: initialCurrency,
        ),
      ),
    );
  }
}

class _SimpleOperationDialog extends StatefulWidget {
  const _SimpleOperationDialog({
    required this.client,
    required this.isDeposit,
    required this.initialCurrency,
  });

  final Client client;
  final bool isDeposit;
  final String initialCurrency;

  @override
  State<_SimpleOperationDialog> createState() => _SimpleOperationDialogState();
}

class _SimpleOperationDialogState extends State<_SimpleOperationDialog> {
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _amountError;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      setState(() => _amountError = 'Введите сумму > 0');
      return;
    }
    final desc = _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim();
    final bloc = context.read<ClientBloc>();
    if (widget.isDeposit) {
      bloc.add(ClientDepositRequested(
        clientId: widget.client.id,
        amount: amount,
        description: desc,
        currency: widget.initialCurrency,
      ));
    } else {
      bloc.add(ClientDebitRequested(
        clientId: widget.client.id,
        amount: amount,
        description: desc,
        currency: widget.initialCurrency,
      ));
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isDeposit ? Colors.green : Colors.red;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.isDeposit
                ? AppIcons.add_circle_outline
                : AppIcons.remove_circle_outline,
            color: color,
          ),
          const SizedBox(width: 8),
          Text(widget.isDeposit
              ? 'Пополнить ${widget.initialCurrency}'
              : 'Списать ${widget.initialCurrency}'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.client.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _amountCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Сумма',
              suffixText: widget.initialCurrency,
              border: const OutlineInputBorder(),
              errorText: _amountError,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _amountError = null),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(
              labelText: 'Комментарий',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: color),
          child: Text(widget.isDeposit ? 'Пополнить' : 'Списать'),
        ),
      ],
    );
  }
}

// ─── Helpers ───

class _Wallet {
  final String currency;
  final double amount;
  final bool isPrimary;
  const _Wallet(this.currency, this.amount, this.isPrimary);
}

List<_Wallet> _walletsForClient(Client client, ClientBalance? balance) {
  final result = <_Wallet>[];
  final seen = <String>{};
  // Сначала основная валюта.
  final main = client.currency;
  result.add(_Wallet(
      main, balance?.balancesByCurrency[main] ?? balance?.balance ?? 0, true));
  seen.add(main);
  // Затем доп. кошельки клиента.
  for (final c in client.walletCurrencies) {
    if (!seen.add(c)) continue;
    result.add(_Wallet(c, balance?.balancesByCurrency[c] ?? 0, false));
  }
  // Любые валюты с балансом, которых нет в wallet.
  if (balance != null) {
    for (final e in balance.balancesByCurrency.entries) {
      if (!seen.add(e.key)) continue;
      result.add(_Wallet(e.key, e.value, false));
    }
  }
  return result;
}

double _usdEquivalent(List<_Wallet> wallets) {
  // Без курсов из CurrencyUtils — берём как есть, если валюта USD.
  // Для остальных валют отдельной таблицы нет — оставляем сумму как сумму
  // (используется только как индикатор «что-то лежит»).
  double total = 0;
  for (final w in wallets) {
    if (w.currency == 'USD') total += w.amount;
  }
  return total;
}

String _pluralCcy(int n) {
  if (n == 1) return 'валюта';
  if (n < 5) return 'валюты';
  return 'валют';
}

// ─── Identity Block ───

/// Компактная полоска с балансом + scrollable wallet-chips. Отображается
/// в режиме «свёрнутого верха» (когда пользователь нажал на ⌃ в AppBar).
/// Освобождает экран для длинной истории операций.
class _CompactTopStrip extends StatelessWidget {
  const _CompactTopStrip({
    required this.client,
    required this.wallets,
    required this.usdEquiv,
  });
  final Client client;
  final List<_Wallet> wallets;
  final double usdEquiv;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outline.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Аватар-инициалы.
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
            child: Text(
              client.name.isEmpty
                  ? '?'
                  : client.name.characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Имя.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  client.name.isEmpty ? '—' : client.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                // Все кошельки в одну строку chip-row, scroll если нужно.
                SizedBox(
                  height: 22,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: wallets.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (_, i) {
                      final w = wallets[i];
                      final positive = w.amount > 0;
                      final color = positive
                          ? Colors.green.shade600
                          : (w.amount < 0
                              ? Colors.red.shade600
                              : scheme.onSurfaceVariant);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${w.amount.formatCurrency()} ${w.currency}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: color,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                          ),
                        ),
                      );
                    },
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

class _IdentityBlock extends StatelessWidget {
  const _IdentityBlock({required this.client});
  final Client client;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = scheme.onSurfaceVariant;
    final initial = client.name.isNotEmpty
        ? client.name.trim().split(' ').take(2).map((s) {
            return s.isNotEmpty ? s[0].toUpperCase() : '';
          }).join()
        : '?';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.primary,
                    AppColors.secondary,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              client.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(100),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    client.counterpartyId,
                    style: TextStyle(
                      fontSize: 11,
                      color: secondary,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: client.isActive
                          ? AppColors.primary
                          : secondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    client.isActive ? 'Активен' : 'Заблокирован',
                    style: TextStyle(
                      fontSize: 10.5,
                      color:
                          client.isActive ? AppColors.primary : secondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero balance card ───

class _HeroBalanceCard extends StatelessWidget {
  const _HeroBalanceCard({
    required this.client,
    required this.wallets,
    required this.usdEquiv,
    required this.isNegative,
  });

  final Client client;
  final List<_Wallet> wallets;
  final double usdEquiv;
  final bool isNegative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final mainWallet = wallets.firstWhere(
      (w) => w.isPrimary,
      orElse: () => wallets.isNotEmpty
          ? wallets.first
          : _Wallet(client.currency, 0, true),
    );

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.16),
                  AppColors.secondary.withValues(alpha: 0.06),
                  scheme.surface,
                ],
                stops: const [0, 0.6, 1],
              ),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.18),
                width: 0.6,
              ),
            ),
          ),
        ),
        Positioned(
          top: -50,
          right: -50,
          width: 180,
          height: 180,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.22),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Основной баланс',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: secondary,
                ),
              ),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      mainWallet.amount.formatCurrency(),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        height: 1,
                        color: isNegative
                            ? AppColors.error
                            : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      mainWallet.currency,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${wallets.length} ${_pluralCcy(wallets.length)} · обновлено только что',
                style: TextStyle(fontSize: 11.5, color: secondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Action buttons (deposit / debit / convert) ───

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({required this.client, required this.balance});
  final Client client;
  final ClientBalance? balance;

  @override
  Widget build(BuildContext context) {
    const compactPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 8);
    const compactTextStyle =
        TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => _open(context, isDeposit: true),
            style: FilledButton.styleFrom(
              padding: compactPadding,
              backgroundColor: AppColors.primary,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
            icon: const Icon(AppIcons.arrow_downward, size: 16),
            label: const Text('Пополнить'),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _open(context, isDeposit: false),
            style: OutlinedButton.styleFrom(
              padding: compactPadding,
              foregroundColor: AppColors.warning,
              side: BorderSide(
                color: AppColors.warning.withValues(alpha: 0.4),
              ),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
            icon: const Icon(AppIcons.arrow_upward, size: 16),
            label: const Text('Списать'),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              showConvertCurrencyDialog(
                context: context,
                client: client,
                balance: balance,
                initialFrom: client.currency,
              );
            },
            style: OutlinedButton.styleFrom(
              padding: compactPadding,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: compactTextStyle,
            ),
            icon: const Icon(AppIcons.swap_horiz, size: 16),
            label: const Text('Обмен'),
          ),
        ),
      ],
    );
  }

  void _open(BuildContext context, {required bool isDeposit}) {
    showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<ClientBloc>(),
        child: _SimpleOperationDialog(
          client: client,
          isDeposit: isDeposit,
          initialCurrency: client.currency,
        ),
      ),
    );
  }
}

// ─── Section header ───

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.hint});
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 6),
            Text(
              '· $hint',
              style: TextStyle(
                fontSize: 11,
                color: scheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Info card ───

/// Свёрнутая по умолчанию «Информация»: ExpansionTile c той же [_InfoCard]
/// внутри. До раскрытия — компактная одна строка («Информация · телефон,
/// страна»), даёт операциям больше места на экране.
class _InfoCollapsible extends StatelessWidget {
  const _InfoCollapsible({required this.client});
  final Client client;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.18),
            width: 0.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.only(bottom: 4),
          collapsedShape: const RoundedRectangleBorder(),
          shape: const RoundedRectangleBorder(),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(AppIcons.info_outline,
                size: 16, color: AppColors.primary),
          ),
          title: const Text(
            'Информация',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            client.phone.isEmpty
                ? client.country.toUpperCase()
                : '${client.phone} · ${client.country.toUpperCase()}',
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          children: [
            _InfoCard(client: client),
          ],
        ),
      ),
    );
  }
}

/// Компактный «чип» кошелька для горизонтальной карусели: валюта,
/// сумма моно-шрифтом, негативный — красный. По тапу — то же
/// меню действий, что у [_WalletTile].
class _WalletChip extends StatelessWidget {
  const _WalletChip({required this.wallet, required this.onTap});
  final _Wallet wallet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNeg = wallet.amount < -0.0049;
    final accent = isNeg ? AppColors.error : AppColors.primary;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: accent.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 140,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    CurrencyUtils.flag(wallet.currency),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    wallet.currency,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: accent,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  wallet.amount.formatCurrencyNoDecimals(),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: isNeg ? AppColors.error : scheme.onSurface,
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.client});
  final Client client;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Column(
        children: [
          _InfoRow(
            icon: AppIcons.phone,
            label: 'Телефон',
            value: client.phone,
            color: AppColors.secondary,
          ),
          _Divider(),
          _InfoRow(
            icon: AppIcons.flag,
            label: 'Страна',
            value: client.country.toUpperCase(),
            color: AppColors.warning,
          ),
          _Divider(),
          BlocBuilder<DashboardBloc, DashboardState>(
            buildWhen: (a, b) => a.branches != b.branches,
            builder: (ctx, dash) {
              final branchName = _branchNameFromList(client.branchId, dash.branches);
              return _InfoRow(
                icon: AppIcons.account_balance,
                label: 'Филиал',
                value: branchName,
                color: AppColors.primary,
              );
            },
          ),
          _Divider(),
          _InfoRow(
            icon: AppIcons.account_balance_wallet,
            label: 'Валюты кошелька',
            value: client.walletCurrencies.isEmpty
                ? client.currency
                : client.walletCurrencies.join(' · '),
            color: AppColors.info,
            mono: true,
          ),
          if (client.telegramChatId != null &&
              client.telegramChatId!.isNotEmpty) ...[
            _Divider(),
            _InfoRow(
              icon: AppIcons.send,
              label: 'Telegram',
              value: 'Подключён · ${client.telegramChatId}',
              color: const Color(0xFF229ED9),
              mono: true,
              valueColor: const Color(0xFF229ED9),
            ),
          ],
        ],
      ),
    );
  }

  String _branchNameFromList(String? branchId, List<Branch> branches) {
    if (branchId == null || branchId.isEmpty) return '—';
    for (final b in branches) {
      if (b.id == branchId) return b.name;
    }
    return branchId;
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Container(
        height: 0.5,
        color: scheme.outline.withValues(alpha: 0.18),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.mono = false,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: color, size: 14),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: secondary,
                    letterSpacing: 0.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: valueColor,
                    fontFamily: mono ? 'JetBrains Mono' : null,
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Transactions ───

/// Группирует конвертации по conversionId и возвращает уже отсортированный
/// (по убыванию даты) список row-моделей. Вынесено из _TransactionsCard,
/// чтобы CustomScrollView мог итерироваться по списку лениво (SliverList.builder),
/// а не строить весь Column сразу.
List<_TxRowData> _buildTxItems(List<ClientTransaction> transactions) {
  final groups = <String, List<ClientTransaction>>{};
  final standalone = <ClientTransaction>[];
  for (final t in transactions) {
    if (t.conversionId == null) {
      standalone.add(t);
    } else {
      groups.putIfAbsent(t.conversionId!, () => []).add(t);
    }
  }
  final items = <_TxRowData>[];
  items.addAll(standalone.map(_TxRowData.simple));
  items.addAll(groups.entries.map((e) => _TxRowData.conversion(e.value)));
  items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return items;
}

/// Sticky-header для секции «Операции». Прилипает к верху при скролле —
/// делает навигацию по длинной истории удобнее (видно где ты в списке).
class _StickySectionHeader extends SliverPersistentHeaderDelegate {
  _StickySectionHeader({
    required this.background,
    required this.title,
    required this.hint,
  });
  final Color background;
  final String title;
  final String hint;

  @override
  double get minExtent => 44;
  @override
  double get maxExtent => 44;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
      alignment: Alignment.bottomLeft,
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            hint,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickySectionHeader old) =>
      old.title != title || old.hint != hint || old.background != background;
}

class _TxRowData {
  final bool isConversion;
  final ClientTransaction? primary;
  final List<ClientTransaction> legs;
  final DateTime timestamp;

  _TxRowData.simple(ClientTransaction t)
      : isConversion = false,
        primary = t,
        legs = const [],
        timestamp = t.createdAt;

  _TxRowData.conversion(List<ClientTransaction> ts)
      : isConversion = true,
        primary = null,
        legs = ts,
        timestamp = ts.isNotEmpty ? ts.first.createdAt : DateTime.now();
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.data});
  final _TxRowData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = scheme.onSurfaceVariant;

    if (data.isConversion) {
      return _buildConversion(context, secondary);
    }

    final t = data.primary!;
    final isDeposit = t.isDeposit;
    final color = isDeposit ? AppColors.primary : AppColors.warning;
    final icon = isDeposit
        ? AppIcons.arrow_downward
        : AppIcons.arrow_upward;
    final sign = isDeposit ? '+' : '−';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 14),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.description ?? (isDeposit ? 'Пополнение' : 'Списание'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDate(t.createdAt) +
                      (t.createdByName != null ? ' · ${t.createdByName}' : ''),
                  style: TextStyle(fontSize: 10.5, color: secondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$sign${t.amount.formatCurrency()} ${t.currency}',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversion(BuildContext context, Color secondaryColor) {
    final secondary = secondaryColor;
    // Берём debit как «from» и deposit как «to».
    ClientTransaction? debit;
    ClientTransaction? deposit;
    for (final t in data.legs) {
      if (t.type == 'debit') debit = t;
      if (t.type == 'deposit') deposit = t;
    }
    if (debit == null || deposit == null) {
      return const SizedBox.shrink();
    }
    final meta = debit.conversionMeta ?? deposit.conversionMeta;
    final rate = (meta?['rate'] as num?)?.toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withValues(alpha: 0.18),
                  AppColors.secondary.withValues(alpha: 0.16),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              AppIcons.swap_horiz,
              color: Colors.white,
              size: 14,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Конвертация ${debit.currency} → ${deposit.currency}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatDate(debit.createdAt)}${rate != null ? ' · 1 ${debit.currency} = ${rate.toStringAsFixed(rate < 10 ? 4 : 2)} ${deposit.currency}' : ''}',
                  style: TextStyle(fontSize: 10.5, color: secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '−${debit.amount.formatCurrency()} ${debit.currency}',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '+${deposit.amount.formatCurrency()} ${deposit.currency}',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} · $hh:$mm';
  }
}

class _EmptyTxCard extends StatelessWidget {
  const _EmptyTxCard({required this.isDark});
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Column(
        children: [
          Icon(AppIcons.receipt_long,
              size: 28, color: scheme.outline),
          const SizedBox(height: 8),
          Text(
            'Пока нет операций',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
