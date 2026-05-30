import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_tier.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/settings/bloc/user_prefs_cubit.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/transfers/widgets/account_picker_grid.dart';
import 'package:ethnocount/presentation/transfers/widgets/contact_autocomplete_field.dart';
import 'package:ethnocount/presentation/transfers/widgets/hero_amount_section.dart';
import 'package:ethnocount/presentation/transfers/widgets/live_receipt_preview.dart';
import 'package:ethnocount/presentation/transfers/widgets/mobile_hero_amount.dart';
import 'package:ethnocount/presentation/transfers/widgets/mobile_route_picker.dart';
import 'package:ethnocount/presentation/transfers/widgets/mobile_step_indicator.dart';
import 'package:ethnocount/presentation/transfers/widgets/route_map_header.dart';
import 'package:ethnocount/presentation/transfers/widgets/transfer_top_chrome.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ethnocount/core/icons/app_icons.dart';
class CreateTransferPage extends StatefulWidget {
  const CreateTransferPage({super.key});

  @override
  State<CreateTransferPage> createState() => _CreateTransferPageState();
}

class _CreateTransferPageState extends State<CreateTransferPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _commissionValueController = TextEditingController(text: '0');
  final _exchangeRateController = TextEditingController(text: '1.0');
  final _senderNameCtrl = TextEditingController();
  final _senderPhoneCtrl = TextEditingController();
  final _senderInfoCtrl = TextEditingController();
  final _receiverNameCtrl = TextEditingController();
  final _receiverPhoneCtrl = TextEditingController();
  final _receiverInfoCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();

  /// Clears "0" / "0.0" placeholder when field receives focus.
  void _smartClear(TextEditingController ctrl) {
    final t = ctrl.text.trim();
    if (t == '0' || t == '0.0' || t == '0.00' || t == '1.0') {
      ctrl.clear();
    }
  }

  void _restoreDefault(TextEditingController ctrl, String def) {
    if (ctrl.text.trim().isEmpty) ctrl.text = def;
  }

  /// Tier-based котировки вынесены в [CurrencyTier]. Локальные обёртки
  /// сохранены для краткости вызовов внутри этого файла.
  (String, String)? _quotePair(String from, String to) =>
      CurrencyTier.quotePair(from, to);

  double _multiplierFromInput(double input, String from, String to) =>
      CurrencyTier.multiplierFromInput(input, from, to);

  String _rateLabel(String from, String to) =>
      CurrencyTier.rateLabel(from, to);

  String _rateHint(String from, String to) {
    final pair = CurrencyTier.quotePair(from, to);
    if (pair == null) return '1.0';
    final (strong, weak) = pair;
    // Подсказки по типичным актуальным курсам (обновлять не критично —
    // оператор вводит фактический).
    final key = '$strong/$weak';
    return const {
      'USD/UZS': '12780',
      'USD/RUB': '92',
      'USD/KZT': '522',
      'USD/KGS': '88',
      'USD/TJS': '11',
      'USD/TRY': '34',
      'USD/CNY': '7.2',
      'USD/AED': '3.67',
      'EUR/USD': '1.085',
      'EUR/UZS': '13800',
      'EUR/RUB': '100',
      'GBP/USD': '1.27',
      'CNY/UZS': '1770',
      'CNY/RUB': '12.7',
      'RUB/UZS': '138',      // «1 RUB = 138 UZS» — частая пара
      'RUB/KGS': '0.96',
      'RUB/KZT': '5.7',
      'KZT/UZS': '25.5',
      'KZT/KGS': '0.17',
      'KGS/UZS': '143',
      'TRY/UZS': '375',
    }[key] ??
        '1.0';
  }

  /// Сбрасывает поле курса при смене валюты, чтобы пользователь не оставил
  /// устаревшее число от предыдущей пары.
  void _resetRateInput() {
    if (_toCurrency == _transferCurrency) {
      _exchangeRateController.text = '1.0';
    } else {
      _exchangeRateController.text = '';
    }
    _exchangeRateError = null;
  }
  CommissionType _commissionType = CommissionType.fixed;
  CommissionMode _commissionMode = CommissionMode.fromTransfer;
  String _transferCurrency = 'USD';
  String _toCurrency = 'USD';
  String _commissionCurrency = 'USD';

  String? _fromBranchId;
  String? _toBranchId;
  String? _fromAccountId;
  String? _commissionAccountId;

  // Dealer mode (опц.): buy/sell rate для расчёта spread profit.
  bool _dealerMode = false;
  String _baseCurrency = 'USD';
  final _buyRateCtrl = TextEditingController();
  final _sellRateCtrl = TextEditingController();

  /// Step index for the mobile+dark stepped flow (0 = amount, 1 = parties,
  /// 2 = review). Ignored in legacy / desktop layouts.
  int _mobileStep = 0;
  static const _mobileStepNames = ['Сумма и маршрут', 'Стороны', 'Проверка'];

  /// Ошибка недостатка средств — подсвечиваем поле суммы красным.
  String? _balanceError;

  String? _exchangeRateError;
  String? _commissionError;

  /// Филиалы, к которым у пользователя есть доступ (для выбора отправителя).
  List<Branch> _branches = [];
  /// Все филиалы (для выбора получателя — бухгалтеры видят все).
  List<Branch> _allBranches = [];
  List<BranchAccount> _fromAccounts = [];

  StreamSubscription<List<Branch>>? _branchesSub;
  StreamSubscription<List<BranchAccount>>? _accountsSub;

  @override
  void initState() {
    super.initState();
    // After first frame: [context.read<AuthBloc>] is reliable; stream alone can
    // emit before UI and leave dropdowns disabled (empty items).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _branchesSub?.cancel();
      _branchesSub = sl<BranchRepository>().watchBranches().listen((branches) {
        if (!mounted) return;
        final user = context.read<AuthBloc>().state.user;
        setState(() {
          _allBranches = branches;
          _branches = filterBranchesByAccess(branches, user);
          // Бухгалтер всегда закреплён за своим филиалом —
          // автоматически выставляем первый из его assigned.
          if (user != null &&
              !user.role.isAdminOrCreator &&
              _branches.isNotEmpty &&
              _fromBranchId == null) {
            _fromBranchId = _branches.first.id;
            _loadAccountsFor(_fromBranchId!);
          }
        });
      });
    });
  }

  void _loadAccountsFor(String branchId) {
    _accountsSub?.cancel();
    _accountsSub = sl<BranchRepository>().watchBranchAccounts(branchId).listen(
      (accounts) {
        if (!mounted) return;
        setState(() {
          _fromAccounts = accounts;
          if (_fromAccountId != null) {
            final match = accounts.where((a) => a.id == _fromAccountId);
            if (match.isNotEmpty) {
              _transferCurrency = match.first.currency;
              _toCurrency = match.first.currency;
              _commissionCurrency = match.first.currency;
            }
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _branchesSub?.cancel();
    _accountsSub?.cancel();
    _amountController.dispose();
    _commissionValueController.dispose();
    _exchangeRateController.dispose();
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _senderInfoCtrl.dispose();
    _receiverNameCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverInfoCtrl.dispose();
    _descriptionCtrl.dispose();
    _buyRateCtrl.dispose();
    _sellRateCtrl.dispose();
    super.dispose();
  }

  /// Подставляет валюту, выбранную из найденного контакта.
  ///
  /// Защиты:
  ///  • если уже выбран from-account — НЕ трогаем _transferCurrency
  ///    (валюта счёта авторитетнее, иначе создадим перевод в валюте, не
  ///    совпадающей со счётом — сервер откажет либо появится несоответствие).
  ///  • если валюта не в списке доступных — молча игнорируем.
  void _applyContactCurrency(String currency) {
    if (!_availableCurrencies().contains(currency)) return;
    if (_fromAccountId != null) return; // счёт уже авторитетен
    setState(() {
      _transferCurrency = currency;
      _toCurrency = currency;
      if (_commissionMode != CommissionMode.fromAccount) {
        _commissionCurrency = currency;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TransferBloc, TransferBlocState>(
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage ?? 'Перевод создан'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          context.go('/transfers');
        }
        if (state.status == TransferBlocStatus.error) {
          final msg = state.errorMessage ?? 'Ошибка';
          final displayMsg = _formatInsufficientFundsError(msg);
          setState(() {
            if (msg.toLowerCase().contains('insufficient') || msg.contains('недостаточно')) {
              _balanceError = displayMsg;
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                displayMsg,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      },
      builder: (context, state) {
        final isCreating = state.status == TransferBlocStatus.creating;
        final isMobile = !context.isDesktop;
        // Desktop hero is temporarily disabled on Flutter web: the
        // Row(Expanded+SCSV) layout combined with multiple BlocBuilders
        // listening to DashboardBloc causes `_debugDuringDeviceUpdate`
        // mouse_tracker races during hover, which prevents layout from
        // completing and leaves the page blank / un-hit-testable.
        // Legacy `_buildDesktopForm` works fine until we redesign the
        // hero with a single tight BlocBuilder + no nested SCSV+Row.
        // Mobile hero stays on — it's single-column and stable.
        final useHero =
            context.isDesktop && context.isDark && !kIsWeb;
        final useMobileHero = isMobile && context.isDark;
        if (useHero) {
          final user = context.read<AuthBloc>().state.user;
          final fromBranch = _allBranches
              .where((b) => b.id == _fromBranchId)
              .cast<Branch?>()
              .firstWhere((_) => true, orElse: () => null);
          return Scaffold(
            backgroundColor: AppColors.darkBg,
            appBar: TransferTopChrome(
              operatorName: user?.displayName ?? '',
              operatorBranchCode: fromBranch?.code ?? '',
              onCancel: () => context.go('/transfers'),
            ),
            // SizedBox.expand + Material force a fully-bounded constraint
            // chain. Without it the Form>Row was occasionally laying out
            // to zero height on full-screen Flutter web (the page rendered
            // blank until the window was resized). Material(transparency)
            // makes nested InkWells find their parent and avoids the
            // `_debugDuringDeviceUpdate` mouse_tracker assertion that fires
            // when InkWells inside a Form get re-parented mid-hover.
            body: SizedBox.expand(
              child: Material(
                type: MaterialType.transparency,
                child: Form(
                  key: _formKey,
                  child: _buildHeroDesktopBody(context, state),
                ),
              ),
            ),
          );
        }
        if (useMobileHero) {
          return _buildMobileHeroScaffold(context, state, isCreating);
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Новый перевод'),
            leading: IconButton(
              icon: const Icon(AppIcons.arrow_back),
              onPressed: () => context.go('/transfers'),
            ),
            actions: [
              if (isMobile)
                IconButton(
                  tooltip: isCreating ? 'Обработка…' : 'Сохранить перевод',
                  onPressed: isCreating ? null : () => _submit(context),
                  icon: isCreating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(AppIcons.check),
                ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    isMobile ? 96 : AppSpacing.lg,
                  ),
                  children: [
                    if (context.isDesktop)
                      _buildDesktopForm(context, state)
                    else
                      _buildMobileForm(context, state),
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: isMobile
              ? SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.md,
                    ),
                    child: SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: isCreating ? null : () => _submit(context),
                        icon: isCreating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(AppIcons.send),
                        label: Text(
                            isCreating ? 'Обработка…' : 'Создать перевод'),
                      ),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildDesktopForm(BuildContext context, TransferBlocState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildSenderSection()),
            const SizedBox(width: AppSpacing.sectionGap),
            Expanded(child: _buildReceiverSection()),
          ],
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildDetailsSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildPreview(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildSubmitButton(context, state),
      ],
    );
  }

  Widget _buildMobileForm(BuildContext context, TransferBlocState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSenderSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildReceiverSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildDetailsSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildPreview(),
        // На мобильной версии кнопка «Создать перевод» вынесена в
        // bottomNavigationBar и в действие AppBar, поэтому встроенная
        // кнопка тут не нужна.
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // Hero desktop layout (design-spec from transfer-create-desktop.jsx)
  // ═══════════════════════════════════════════════════════════════

  Widget _buildHeroDesktopBody(
      BuildContext context, TransferBlocState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeroRouteMap(),
                const SizedBox(height: 22),
                _buildHeroAmount(),
                const SizedBox(height: 28),
                _HeroSectionHeading(
                  title: 'Счёт списания',
                  subtitle: _fromBranchId == null
                      ? 'Сначала выберите филиал отправителя'
                      : 'Какая касса платит',
                  icon: AppIcons.account_balance_wallet,
                ),
                const SizedBox(height: 12),
                _buildHeroAccountGrid(),
                const SizedBox(height: 28),
                _HeroSectionHeading(
                  title: 'Параметры перевода',
                  subtitle: 'Курс, комиссия и режим списания',
                  icon: AppIcons.tune,
                ),
                const SizedBox(height: 12),
                _buildHeroCommissionAndDealer(),
                const SizedBox(height: 28),
                _HeroSectionHeading(
                  title: 'Стороны',
                  subtitle:
                      'Для квитанции, аудита и поиска по истории операций',
                  icon: AppIcons.person_outline,
                ),
                const SizedBox(height: 12),
                _buildHeroPartiesGrid(),
                const SizedBox(height: 14),
                _buildHeroDescription(),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
        Container(
          width: 480,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.20),
            border: const Border(
              left: BorderSide(color: AppColors.darkBorder, width: 0.5),
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPreview(),
                const SizedBox(height: 16),
                _buildHeroSubmitStack(context, state),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroRouteMap() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (a, b) => a.branches != b.branches,
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final allFrom = _branches.isNotEmpty
            ? _branches
            : filterBranchesByAccess(dash.branches, user);
        final allTo = _allBranches.isNotEmpty ? _allBranches : dash.branches;
        final isAccountant = user != null && !user.role.isAdminOrCreator;
        return RouteMapHeader(
          fromBranches: allFrom,
          toBranches: allTo,
          selectedFromId: _fromBranchId,
          selectedToId: _toBranchId,
          fromLocked: isAccountant,
          onFromChanged: (id) {
            setState(() {
              _fromBranchId = id;
              _fromAccountId = null;
              _fromAccounts = [];
            });
            _loadAccountsFor(id);
          },
          onToChanged: (id) => setState(() => _toBranchId = id),
        );
      },
    );
  }

  Widget _buildHeroAmount() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      builder: (context, dash) {
        final balance = dash.accountBalances[_fromAccountId] ?? 0;
        final fromBranch = _allBranches
            .where((b) => b.id == _fromBranchId)
            .cast<Branch?>()
            .firstWhere((_) => true, orElse: () => null);
        final toBranch = _allBranches
            .where((b) => b.id == _toBranchId)
            .cast<Branch?>()
            .firstWhere((_) => true, orElse: () => null);
        final amount = double.tryParse(_amountController.text) ?? 0;
        final commissionValue =
            double.tryParse(_commissionValueController.text) ?? 0;
        final commission = _commissionType == CommissionType.percentage
            ? amount * commissionValue / 100
            : commissionValue;
        final rate = _toCurrency == _transferCurrency
            ? 1.0
            : _multiplierFromInput(
                double.tryParse(_exchangeRateController.text) ?? 1.0,
                _transferCurrency,
                _toCurrency,
              );
        final received = (amount - commission).clamp(0, double.infinity) * rate;
        final totalDebit = _commissionMode == CommissionMode.fromSender
            ? amount + commission
            : amount;
        final insufficient =
            _fromAccountId != null && amount > 0 && totalDebit > balance;
        final receiverBranch = toBranch;
        final receiverCurrencies = receiverBranch?.supportedCurrencies != null &&
                receiverBranch!.supportedCurrencies!.isNotEmpty
            ? List<String>.from(receiverBranch.supportedCurrencies!)
            : CurrencyUtils.supported;
        if (!receiverCurrencies.contains(_toCurrency) &&
            _toCurrency.isNotEmpty) {
          receiverCurrencies.insert(0, _toCurrency);
        }

        final commLabel = _commissionType == CommissionType.percentage
            ? 'Комиссия (${_commissionValueController.text.isEmpty ? '0' : _commissionValueController.text}%)'
            : 'Комиссия';

        return HeroAmountSection(
          amountController: _amountController,
          fromCurrency:
              _transferCurrency.isEmpty ? 'USD' : _transferCurrency,
          toCurrency: _toCurrency.isEmpty ? _transferCurrency : _toCurrency,
          fromBranchCode: fromBranch?.code ?? '',
          toBranchCode: toBranch?.code ?? '',
          received: received.toDouble(),
          balance: balance.toDouble(),
          insufficient: insufficient,
          rate: rate,
          commissionLabel: commLabel,
          commission: commission,
          commissionCurrency:
              _commissionCurrency.isEmpty ? _transferCurrency : _commissionCurrency,
          totalDebit: totalDebit,
          onAmountChanged: (_) => setState(() => _balanceError = null),
          onChangeToCurrency: (v) => setState(() {
            _toCurrency = v;
            _resetRateInput();
          }),
          toCurrencyOptions: receiverCurrencies,
        );
      },
    );
  }

  Widget _buildHeroAccountGrid() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      builder: (context, dash) {
        return AccountPickerGrid(
          accounts: _fromAccounts,
          selectedId: _fromAccountId,
          onSelected: (id) {
            setState(() {
              _fromAccountId = id;
              _balanceError = null;
              final m = _fromAccounts.where((a) => a.id == id);
              if (m.isNotEmpty) {
                _transferCurrency = m.first.currency;
                _toCurrency = m.first.currency;
                if (_commissionMode != CommissionMode.fromAccount) {
                  _commissionCurrency = m.first.currency;
                }
                _resetRateInput();
              }
            });
          },
          balanceLookup: (id) =>
              (dash.accountBalances[id] ?? 0).toDouble(),
        );
      },
    );
  }

  Widget _buildHeroCommissionAndDealer() {
    final fromBranch = _allBranches
        .where((b) => b.id == _fromBranchId)
        .cast<Branch?>()
        .firstWhere((_) => true, orElse: () => null);
    final senderCurrencies = _availableCurrencies(branch: fromBranch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CommissionBlock(
          type: _commissionType,
          onTypeChanged: (t) => setState(() => _commissionType = t),
          valueController: _commissionValueController,
          onValueTap: () => _smartClear(_commissionValueController),
          onValueChange: () => setState(() => _commissionError = null),
          onValueBlur: () => _restoreDefault(_commissionValueController, '0'),
          currency: _commissionCurrency,
          currencies: senderCurrencies,
          onCurrencyChanged: (v) =>
              setState(() => _commissionCurrency = v),
          transferCurrency: _transferCurrency,
          errorText: _commissionError,
          isFromAccountMode: _commissionMode == CommissionMode.fromAccount,
        ),
        const SizedBox(height: 10),
        _CommissionModePicker(
          mode: _commissionMode,
          onChanged: (m) {
            setState(() {
              _commissionMode = m;
              if (m != CommissionMode.fromAccount) {
                _commissionAccountId = null;
              }
            });
          },
        ),
        const SizedBox(height: 12),
        _DealerModeBlock(
          enabled: _dealerMode,
          onToggle: (v) => setState(() {
            _dealerMode = v;
            if (!v) {
              _buyRateCtrl.clear();
              _sellRateCtrl.clear();
            }
          }),
          baseCurrency: _baseCurrency,
          sourceCurrency: _transferCurrency,
          onBaseChanged: (v) => setState(() => _baseCurrency = v),
          buyCtrl: _buyRateCtrl,
          sellCtrl: _sellRateCtrl,
          onRateChanged: () => setState(() {}),
          spreadPreview: _dealerSpreadPreview,
        ),
      ],
    );
  }

  Widget _buildHeroPartiesGrid() {
    // LayoutBuilder removed (web mouse_tracker compatibility). Mobile path
    // routes through `_buildMobileHeroScaffold` and stacks parties one per
    // step, so this method only runs on desktop hero where the column is
    // always > 620 px → always two-column.
    final sender = _PartyCard(
      role: 'Отправитель',
      accent: AppColors.warning,
      isSender: true,
      nameCtrl: _senderNameCtrl,
      phoneCtrl: _senderPhoneCtrl,
      infoCtrl: _senderInfoCtrl,
      onCurrencyPicked: _applyContactCurrency,
    );
    final receiver = _PartyCard(
      role: 'Получатель',
      accent: AppColors.primary,
      isSender: false,
      nameCtrl: _receiverNameCtrl,
      phoneCtrl: _receiverPhoneCtrl,
      infoCtrl: _receiverInfoCtrl,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: sender),
        const SizedBox(width: 14),
        Expanded(child: receiver),
      ],
    );
  }

  Widget _buildHeroDescription() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'НАЗНАЧЕНИЕ / КОММЕНТАРИЙ',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _descriptionCtrl,
            maxLines: 2,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.darkTextPrimary,
            ),
            decoration: const InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: 'Контракт, инвойс, причина перевода…',
              hintStyle: TextStyle(color: AppColors.darkTextDisabled),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSubmitStack(BuildContext context, TransferBlocState state) {
    final isCreating = state.status == TransferBlocStatus.creating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GradientPrimaryButton(
          label: isCreating ? 'Обработка…' : 'Создать перевод',
          icon: AppIcons.send,
          enabled: !isCreating,
          loading: isCreating,
          onPressed: () => _submit(context),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed:
                    isCreating ? null : () => context.go('/transfers'),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.darkBorder),
                  foregroundColor: AppColors.darkTextSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                child: const Text(
                  'Отменить',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // Mobile hero layout (design-spec from transfer-create-mobile.jsx)
  // ═══════════════════════════════════════════════════════════════

  Widget _buildMobileHeroScaffold(
      BuildContext context, TransferBlocState state, bool isCreating) {
    final stepName = _mobileStepNames[_mobileStep];
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(AppIcons.arrow_back, size: 20),
          color: AppColors.darkTextPrimary,
          onPressed: () {
            if (_mobileStep == 0) {
              context.go('/transfers');
            } else {
              setState(() => _mobileStep -= 1);
            }
          },
        ),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'НОВЫЙ ПЕРЕВОД',
              style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              stepName,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.darkTextPrimary,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(AppIcons.close, size: 18),
            color: AppColors.darkTextSecondary,
            onPressed: () => context.go('/transfers'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: MobileStepIndicator(
                current: _mobileStep,
                total: 3,
                showLabel: false,
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                child: _buildMobileHeroStepBody(context, state),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: _buildMobileStepCta(context, state, isCreating),
        ),
      ),
    );
  }

  Widget _buildMobileHeroStepBody(
      BuildContext context, TransferBlocState state) {
    switch (_mobileStep) {
      case 0:
        return _buildMobileStepAmount(context);
      case 1:
        return _buildMobileStepParties(context);
      case 2:
      default:
        return _buildMobileStepReview(context);
    }
  }

  Widget _buildMobileStepAmount(BuildContext context) {
    return BlocBuilder<DashboardBloc, DashboardState>(
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final allFrom = _branches.isNotEmpty
            ? _branches
            : filterBranchesByAccess(dash.branches, user);
        final allTo = _allBranches.isNotEmpty ? _allBranches : dash.branches;
        final isAccountant =
            user != null && !user.role.isAdminOrCreator;
        final balance = dash.accountBalances[_fromAccountId] ?? 0;
        final amount = double.tryParse(_amountController.text) ?? 0;
        final commissionValue =
            double.tryParse(_commissionValueController.text) ?? 0;
        final commission = _commissionType == CommissionType.percentage
            ? amount * commissionValue / 100
            : commissionValue;
        final rate = _toCurrency == _transferCurrency
            ? 1.0
            : _multiplierFromInput(
                double.tryParse(_exchangeRateController.text) ?? 1.0,
                _transferCurrency,
                _toCurrency,
              );
        final received =
            (amount - commission).clamp(0, double.infinity) * rate;
        final totalDebit = _commissionMode == CommissionMode.fromSender
            ? amount + commission
            : amount;
        final insufficient =
            _fromAccountId != null && amount > 0 && totalDebit > balance;
        final fromBranch = _allBranches
            .where((b) => b.id == _fromBranchId)
            .cast<Branch?>()
            .firstWhere((_) => true, orElse: () => null);
        final receiverCurrencies = _availableCurrencies(
                branch: _allBranches
                    .where((b) => b.id == _toBranchId)
                    .cast<Branch?>()
                    .firstWhere((_) => true, orElse: () => null))
            .toList();
        if (!receiverCurrencies.contains(_toCurrency) &&
            _toCurrency.isNotEmpty) {
          receiverCurrencies.insert(0, _toCurrency);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileRoutePicker(
              fromBranches: allFrom,
              toBranches: allTo,
              selectedFromId: _fromBranchId,
              selectedToId: _toBranchId,
              fromLocked: isAccountant,
              onFromChanged: (id) {
                setState(() {
                  _fromBranchId = id;
                  _fromAccountId = null;
                  _fromAccounts = [];
                });
                _loadAccountsFor(id);
              },
              onToChanged: (id) => setState(() => _toBranchId = id),
            ),
            const SizedBox(height: 14),
            MobileHeroAmount(
              amountController: _amountController,
              fromCurrency: _transferCurrency.isEmpty ? 'USD' : _transferCurrency,
              toCurrency: _toCurrency.isEmpty ? _transferCurrency : _toCurrency,
              balance: balance.toDouble(),
              received: received.toDouble(),
              insufficient: insufficient,
              rate: rate,
              accountSelected: _fromAccountId != null,
              onAmountChanged: (_) => setState(() => _balanceError = null),
              onAccountTap: () => _openMobileAccountSheet(context, fromBranch),
              onCurrencyTap: () =>
                  _openMobileCurrencySheet(context, receiverCurrencies),
              onQuickPick: (v) {
                setState(() {
                  _amountController.text = v.toStringAsFixed(0);
                  _balanceError = null;
                });
              },
              onMaxPick: () {
                setState(() {
                  _amountController.text = balance.toStringAsFixed(0);
                  _balanceError = null;
                });
              },
            ),
            const SizedBox(height: 18),
            _HeroSectionHeading(
              title: 'Комиссия',
              subtitle: 'Тип, размер и кто платит',
              icon: AppIcons.tune,
            ),
            const SizedBox(height: 10),
            _buildHeroCommissionAndDealer(),
          ],
        );
      },
    );
  }

  Widget _buildMobileStepParties(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PartyCard(
          role: 'Отправитель',
          accent: AppColors.warning,
          isSender: true,
          nameCtrl: _senderNameCtrl,
          phoneCtrl: _senderPhoneCtrl,
          infoCtrl: _senderInfoCtrl,
          onCurrencyPicked: _applyContactCurrency,
        ),
        const SizedBox(height: 14),
        _PartyCard(
          role: 'Получатель',
          accent: AppColors.primary,
          isSender: false,
          nameCtrl: _receiverNameCtrl,
          phoneCtrl: _receiverPhoneCtrl,
          infoCtrl: _receiverInfoCtrl,
        ),
        const SizedBox(height: 14),
        _buildHeroDescription(),
      ],
    );
  }

  Widget _buildMobileStepReview(BuildContext context) {
    return BlocBuilder<DashboardBloc, DashboardState>(
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final fromBranch = _allBranches
            .where((b) => b.id == _fromBranchId)
            .cast<Branch?>()
            .firstWhere((_) => true, orElse: () => null);
        final toBranch = _allBranches
            .where((b) => b.id == _toBranchId)
            .cast<Branch?>()
            .firstWhere((_) => true, orElse: () => null);
        final balance = dash.accountBalances[_fromAccountId] ?? 0;
        final amount = double.tryParse(_amountController.text) ?? 0;
        final commissionValue =
            double.tryParse(_commissionValueController.text) ?? 0;
        final commission = _commissionType == CommissionType.percentage
            ? amount * commissionValue / 100
            : commissionValue;
        final rate = _toCurrency == _transferCurrency
            ? 1.0
            : _multiplierFromInput(
                double.tryParse(_exchangeRateController.text) ?? 1.0,
                _transferCurrency,
                _toCurrency,
              );
        final received =
            (amount - commission).clamp(0, double.infinity) * rate;
        final totalDebit = _commissionMode == CommissionMode.fromSender
            ? amount + commission
            : amount;
        final insufficient =
            _fromAccountId != null && amount > 0 && totalDebit > balance;
        final commLabel = _commissionType == CommissionType.percentage
            ? 'Комиссия (${_commissionValueController.text.isEmpty ? '0' : _commissionValueController.text}%)'
            : 'Комиссия';
        final commPayer = _commissionMode == CommissionMode.fromTransfer
            ? 'удерживается из перевода'
            : (_commissionMode == CommissionMode.fromAccount
                ? 'на отдельный счёт'
                : (_commissionMode == CommissionMode.fromSender
                    ? 'отправитель'
                    : 'получатель'));
        return LiveReceiptPreview(
          fromBranchName: fromBranch?.name ?? '—',
          fromBranchCode: fromBranch != null
              ? shortBranchCode(fromBranch.name, explicitCode: fromBranch.code)
              : '—',
          fromCountryFlag: flagForBranchCountry(fromBranch?.address),
          toBranchName: toBranch?.name ?? '—',
          toBranchCode: toBranch != null
              ? shortBranchCode(toBranch.name, explicitCode: toBranch.code)
              : '—',
          toCountryFlag: flagForBranchCountry(toBranch?.address),
          fromCurrency: _transferCurrency,
          toCurrency: _toCurrency,
          amount: amount,
          received: received.toDouble(),
          rate: rate,
          commissionLabel: commLabel,
          commission: commission,
          commissionCurrency: _commissionCurrency,
          commissionPayer: commPayer,
          totalDebit: totalDebit,
          senderName: _senderNameCtrl.text.trim(),
          senderPhone: _senderPhoneCtrl.text.trim(),
          receiverName: _receiverNameCtrl.text.trim(),
          receiverPhone: _receiverPhoneCtrl.text.trim(),
          description: _descriptionCtrl.text.trim(),
          operatorName: user?.displayName ?? '—',
          operatorBranchCode: fromBranch?.code ?? '',
          draftId:
              'TR-DRAFT-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
          insufficient: insufficient,
          compact: true,
        );
      },
    );
  }

  Widget _buildMobileStepCta(
      BuildContext context, TransferBlocState state, bool isCreating) {
    bool step0Ready() {
      final amount = double.tryParse(_amountController.text) ?? 0;
      final balance = context
              .read<DashboardBloc>()
              .state
              .accountBalances[_fromAccountId] ??
          0;
      final commissionValue =
          double.tryParse(_commissionValueController.text) ?? 0;
      final commission = _commissionType == CommissionType.percentage
          ? amount * commissionValue / 100
          : commissionValue;
      final totalDebit = _commissionMode == CommissionMode.fromSender
          ? amount + commission
          : amount;
      return _fromBranchId != null &&
          _toBranchId != null &&
          _fromBranchId != _toBranchId &&
          _fromAccountId != null &&
          amount > 0 &&
          totalDebit <= balance;
    }

    bool step1Ready() =>
        _senderNameCtrl.text.trim().isNotEmpty &&
        _receiverNameCtrl.text.trim().isNotEmpty;

    final label = switch (_mobileStep) {
      0 => 'Далее · стороны',
      1 => 'Далее · проверка',
      _ => isCreating ? 'Обработка…' : 'Создать перевод',
    };
    final icon = _mobileStep == 2 ? AppIcons.send : AppIcons.arrow_forward;
    final ready = switch (_mobileStep) {
      0 => step0Ready(),
      1 => step1Ready(),
      _ => !isCreating,
    };
    return _GradientPrimaryButton(
      label: label,
      icon: icon,
      enabled: ready,
      loading: _mobileStep == 2 && isCreating,
      onPressed: () {
        if (_mobileStep < 2) {
          setState(() => _mobileStep += 1);
        } else {
          _submit(context);
        }
      },
    );
  }

  /// Bottom sheet with cash accounts of the active sender branch.
  Future<void> _openMobileAccountSheet(
      BuildContext context, Branch? branch) async {
    if (_fromBranchId == null || _fromAccounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сначала выберите филиал отправителя'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final dash = context.read<DashboardBloc>().state;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkCard,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final viewInsets = MediaQuery.viewInsetsOf(ctx);
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.darkBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Касса · ${branch?.name ?? '—'}',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.darkTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  AccountPickerGrid(
                    accounts: _fromAccounts,
                    selectedId: _fromAccountId,
                    onSelected: (id) => Navigator.of(ctx).pop(id),
                    balanceLookup: (id) =>
                        (dash.accountBalances[id] ?? 0).toDouble(),
                    columns: 1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _fromAccountId = picked;
        _balanceError = null;
        final m = _fromAccounts.where((a) => a.id == picked);
        if (m.isNotEmpty) {
          _transferCurrency = m.first.currency;
          _toCurrency = m.first.currency;
          if (_commissionMode != CommissionMode.fromAccount) {
            _commissionCurrency = m.first.currency;
          }
          _resetRateInput();
        }
      });
    }
  }

  /// Bottom sheet with a 3-column grid of `toCurrency` options.
  Future<void> _openMobileCurrencySheet(
      BuildContext context, List<String> options) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkCard,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.darkBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Валюта получателя',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkTextPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.6,
                  children: [
                    for (final c in options)
                      Material(
                        color: c == _toCurrency
                            ? AppColors.primarySurface
                            : AppColors.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(ctx).pop(c),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: c == _toCurrency
                                    ? AppColors.primary
                                    : AppColors.darkBorder,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              c,
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: c == _toCurrency
                                    ? AppColors.primary
                                    : AppColors.darkTextPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _toCurrency = picked;
        _resetRateInput();
      });
    }
  }

  Widget _buildSenderSection() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (prev, curr) => prev.branches != curr.branches,
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final senderBranches = _branches.isNotEmpty
            ? _branches
            : filterBranchesByAccess(dash.branches, user);

        // Бухгалтер ВСЕГДА закреплён за своим филиалом — никакого
        // dropdown'а, даже если он по какой-то причине видит несколько
        // (миграция 025 это запрещает на БД-уровне, тут страховка).
        // Берём первый из его assigned — RPC всё равно отобьёт чужой.
        final isAccountant =
            user != null && !user.role.isAdminOrCreator;
        final pinnedBranch = (isAccountant && senderBranches.isNotEmpty)
            ? senderBranches.first
            : null;

        return _FormSection(
          title: 'Отправитель',
          icon: AppIcons.arrow_upward,
          children: [
            if (pinnedBranch != null)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Филиал отправителя',
                  helperText: 'привязан к вашему профилю',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.lock_outline, size: 18),
                ),
                child: Text(
                  pinnedBranch.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'from-branch-${senderBranches.length}-$_fromBranchId',
                ),
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Филиал отправителя',
                  border: OutlineInputBorder(),
                ),
                initialValue: _fromBranchId != null &&
                        senderBranches.any((b) => b.id == _fromBranchId)
                    ? _fromBranchId
                    : null,
                hint: senderBranches.isEmpty
                    ? const Text('Нет доступных филиалов')
                    : const Text('Выберите филиал'),
                items: senderBranches
                    .map((b) =>
                        DropdownMenuItem(value: b.id, child: Text(b.name)))
                    .toList(),
                onChanged: senderBranches.isEmpty
                    ? null
                    : (v) {
                        setState(() {
                          _fromBranchId = v;
                          _fromAccountId = null;
                          _fromAccounts = [];
                        });
                        if (v != null) _loadAccountsFor(v);
                      },
                validator: (v) => v == null ? 'Выберите филиал' : null,
              ),
            if (senderBranches.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: 4),
                child: Text(
                  'Обратитесь к администратору для назначения филиалов.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.formFieldGap),
            DropdownButtonFormField<String>(
              key: ValueKey('from-acc-$_fromAccountId-${_fromAccounts.length}'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Счёт отправителя',
                border: OutlineInputBorder(),
              ),
              initialValue: _fromAccountId != null &&
                      _fromAccounts.any((a) => a.id == _fromAccountId)
                  ? _fromAccountId
                  : null,
              items: _fromAccounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        '${CurrencyUtils.flag(a.currency)} ${a.name} (${a.currency})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _fromAccountId = v;
                  _balanceError = null;
                  if (v != null) {
                    final match = _fromAccounts.where((a) => a.id == v);
                    if (match.isNotEmpty) {
                      final newCurrency = match.first.currency;
                      // Валюта перевода жёстко = валюта счёта. Получение и
                      // комиссия тоже сбрасываются на эту валюту — это
                      // ожидаемое поведение по умолчанию (выбрал сума-счёт —
                      // перевод в сумах). Хочешь cross-currency — поменяй
                      // «Валюта получения» уже ПОСЛЕ выбора счёта.
                      _transferCurrency = newCurrency;
                      _toCurrency = newCurrency;
                      // В режиме fromAccount комиссия привязана к своему
                      // счёту — не трогаем. В остальных режимах подгоняем.
                      if (_commissionMode != CommissionMode.fromAccount) {
                        _commissionCurrency = newCurrency;
                      }
                      _resetRateInput();
                    }
                  }
                });
              },
              validator: (v) => v == null ? 'Выберите счёт' : null,
            ),
        if (_fromAccountId != null)
          BlocBuilder<DashboardBloc, DashboardState>(
            builder: (context, dashState) {
              final balance = dashState.accountBalances[_fromAccountId] ?? 0;
              final isNegative = balance < 0;
              // Берём валюту ПРЯМО из выбранного счёта, а не из
              // `_transferCurrency` — последний обновляется через setState и
              // может застрять на старом значении, если поток счетов пришёл
              // после рендера (race). Авторитет — сам счёт.
              final accountCurrency = _fromAccounts
                  .where((a) => a.id == _fromAccountId)
                  .map((a) => a.currency)
                  .cast<String?>()
                  .firstWhere((_) => true, orElse: () => _transferCurrency) ??
                  _transferCurrency;
              if (isNegative) {
                // Защита от расхождения кэша balances с ledger_entries.
                // Если на счёте отрицательное значение, это почти всегда
                // не реальный овердрафт, а сбившийся кэш. Предупреждаем
                // creator-а сразу — запустить миграцию 031 + audit.
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withValues(alpha: 0.35),
                        width: 0.6,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(AppIcons.error_outline,
                            size: 16,
                            color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Баланс: ${balance.formatCurrencyNoDecimals()} $accountCurrency',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Отрицательный баланс — кэш разошёлся с журналом операций. '
                                'Попроси администратора запустить пересчёт балансов (миграция 031).',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
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
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Доступно: ${balance.formatCurrencyNoDecimals()} $accountCurrency',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _senderNameCtrl,
          decoration: const InputDecoration(
            labelText: 'ФИО отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(AppIcons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        ContactAutocompleteField(
          side: 'sender',
          phoneController: _senderPhoneCtrl,
          nameController: _senderNameCtrl,
          infoController: _senderInfoCtrl,
          label: 'Телефон отправителя',
          hintText: '+7 900 123 45 67',
          onCurrencyPicked: _applyContactCurrency,
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _senderInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(AppIcons.info_outline, size: 20),
            isDense: true,
          ),
        ),
          ],
        );
      },
    );
  }

  Widget _buildReceiverSection() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (prev, curr) => prev.branches != curr.branches,
      builder: (context, dash) {
        final allBranches = _allBranches.isNotEmpty
            ? _allBranches
            : dash.branches;
        final receiverItems = allBranches
            .where((b) => b.id != _fromBranchId)
            .toList();

        return _FormSection(
          title: 'Получатель',
          icon: AppIcons.arrow_downward,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(
                'to-branch-${receiverItems.length}-$_toBranchId-$_fromBranchId',
              ),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Филиал получателя',
                border: OutlineInputBorder(),
              ),
              initialValue: _toBranchId != null &&
                      receiverItems.any((b) => b.id == _toBranchId)
                  ? _toBranchId
                  : null,
              hint: receiverItems.isEmpty
                  ? const Text('Нет других филиалов')
                  : const Text('Выберите филиал'),
              items: receiverItems
                  .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                  .toList(),
              onChanged: receiverItems.isEmpty
                  ? null
                  : (v) => setState(() => _toBranchId = v),
              validator: (v) => v == null ? 'Выберите филиал' : null,
            ),
        const SizedBox(height: AppSpacing.sm),
        TextFormField(
          controller: _descriptionCtrl,
          decoration: const InputDecoration(
            labelText: 'Назначение платежа',
            hintText: 'Оплата по договору, аванс, возврат...',
            border: OutlineInputBorder(),
            prefixIcon: Icon(AppIcons.description, size: 20),
            isDense: true,
          ),
          maxLines: 2,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Счёт получателя укажет бухгалтер филиала при подтверждении',
          style: TextStyle(
            fontSize: 12,
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _receiverNameCtrl,
          decoration: const InputDecoration(
            labelText: 'ФИО получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(AppIcons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        ContactAutocompleteField(
          side: 'receiver',
          phoneController: _receiverPhoneCtrl,
          nameController: _receiverNameCtrl,
          infoController: _receiverInfoCtrl,
          label: 'Телефон получателя',
          hintText: '+998 90 123 45 67',
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _receiverInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(AppIcons.info_outline, size: 20),
            isDense: true,
          ),
        ),
          ],
        );
      },
    );
  }

  /// Возвращает список валют, доступных для выбранного отправляющего филиала.
  /// Если в настройках филиала задан `supportedCurrencies` — используем его,
  /// иначе — глобальный список (для обратной совместимости).
  List<String> _availableCurrencies({Branch? branch}) {
    final supported = branch?.supportedCurrencies;
    if (supported != null && supported.isNotEmpty) {
      return List<String>.from(supported);
    }
    return CurrencyUtils.supported;
  }

  Widget _buildDetailsSection() {
    final fromBranch = _branches
        .where((b) => b.id == _fromBranchId)
        .cast<Branch?>()
        .firstWhere((_) => true, orElse: () => null);
    final senderCurrencies = _availableCurrencies(branch: fromBranch);

    return _FormSection(
      title: 'Параметры перевода',
      icon: AppIcons.tune,
      children: [
        // ── Сумма + валюта отправителя в одной строке ──
        // Валюта перевода жёстко привязана к валюте выбранного счёта.
        // Хочешь сменить — выбери другой счёт.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _amountController,
                decoration: InputDecoration(
                  labelText: 'Сумма к списанию',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(AppIcons.payments),
                  hintText: '0',
                  errorText: _balanceError,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [DecimalInputFormatter()],
                onChanged: (_) => setState(() => _balanceError = null),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Введите сумму';
                  final amount = double.tryParse(v);
                  if (amount == null || amount <= 0) {
                    return 'Сумма должна быть > 0';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: _LockedCurrencyField(
                label: 'Валюта',
                currency: _fromAccountId != null ? _transferCurrency : null,
                helperText: _fromAccountId != null
                    ? 'из счёта'
                    : 'Выберите счёт',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        // ── Валюта получателя ──
        // Если в настройках выключен флаг «использовать курсы валют»,
        // блок полностью скрыт и валюта получения принудительно
        // приравнивается к валюте отправителя.
        BlocBuilder<UserPrefsCubit, UserPrefs>(
          buildWhen: (a, b) => a.useExchangeRates != b.useExchangeRates,
          builder: (context, prefs) {
            if (!prefs.useExchangeRates) {
              if (_toCurrency != _transferCurrency) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  setState(() {
                    _toCurrency = _transferCurrency;
                    _resetRateInput();
                  });
                });
              }
              return const SizedBox.shrink();
            }
            final receiverBranch = _allBranches
                .where((b) => b.id == _toBranchId)
                .cast<Branch?>()
                .firstWhere((_) => true, orElse: () => null);
            final receiverCurrencies =
                _availableCurrencies(branch: receiverBranch);
            final isSame = _toCurrency == _transferCurrency;
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildCurrencyDropdown(
                      label: 'Валюта получения',
                      value: _toCurrency,
                      options: receiverCurrencies,
                      helperText: isSame
                          ? 'Совпадает с валютой отправителя — конвертация не нужна'
                          : null,
                      onChanged: (v) {
                        setState(() {
                          _toCurrency = v;
                          _resetRateInput();
                        });
                      },
                    ),
                  ),
                  if (!isSame) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: Focus(
                        onFocusChange: (f) {
                          if (!f) _restoreDefault(_exchangeRateController, '1.0');
                        },
                        child: TextFormField(
                          controller: _exchangeRateController,
                          decoration: InputDecoration(
                            labelText: _rateLabel(_transferCurrency, _toCurrency),
                            hintText: _rateHint(_transferCurrency, _toCurrency),
                            border: const OutlineInputBorder(),
                            errorText: _exchangeRateError,
                            suffixText:
                                _quotePair(_transferCurrency, _toCurrency)?.$2,
                            prefixIcon: const Icon(AppIcons.swap_horiz),
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          inputFormatters: [DecimalInputFormatter()],
                          onTap: () => _smartClear(_exchangeRateController),
                          onChanged: (_) =>
                              setState(() => _exchangeRateError = null),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),

        // ── Комиссия (отдельный визуальный блок) ──
        _CommissionBlock(
          type: _commissionType,
          onTypeChanged: (t) => setState(() => _commissionType = t),
          valueController: _commissionValueController,
          onValueTap: () => _smartClear(_commissionValueController),
          onValueChange: () => setState(() => _commissionError = null),
          onValueBlur: () => _restoreDefault(_commissionValueController, '0'),
          currency: _commissionCurrency,
          currencies: senderCurrencies,
          onCurrencyChanged: (v) =>
              setState(() => _commissionCurrency = v),
          transferCurrency: _transferCurrency,
          errorText: _commissionError,
          isFromAccountMode: _commissionMode == CommissionMode.fromAccount,
        ),
        const SizedBox(height: AppSpacing.sm),
        _CommissionModePicker(
          mode: _commissionMode,
          onChanged: (m) {
            setState(() {
              _commissionMode = m;
              if (m != CommissionMode.fromAccount) {
                _commissionAccountId = null;
              }
            });
          },
        ),
        if (_commissionMode == CommissionMode.fromAccount) ...[
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            key: ValueKey('commission-acc-$_commissionAccountId-${_fromAccounts.length}'),
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Счёт для зачисления комиссии',
              helperText: 'Комиссия будет добавлена на этот счёт как доход',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
              prefixIcon: Icon(AppIcons.account_balance, size: 18),
              isDense: true,
            ),
            initialValue: _commissionAccountId != null &&
                    _fromAccounts.any((a) => a.id == _commissionAccountId)
                ? _commissionAccountId
                : null,
            items: _fromAccounts
                .map((a) => DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        '${CurrencyUtils.flag(a.currency)} ${a.name} (${a.currency})',
                      ),
                    ))
                .toList(),
            onChanged: (v) {
              setState(() {
                _commissionAccountId = v;
                if (v != null) {
                  final m = _fromAccounts.where((a) => a.id == v);
                  if (m.isNotEmpty) {
                    _commissionCurrency = m.first.currency;
                  }
                }
              });
            },
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // ── Дилерская модель (buy/sell rate + spread profit) ────
        _DealerModeBlock(
          enabled: _dealerMode,
          onToggle: (v) => setState(() {
            _dealerMode = v;
            if (!v) {
              _buyRateCtrl.clear();
              _sellRateCtrl.clear();
            }
          }),
          baseCurrency: _baseCurrency,
          sourceCurrency: _transferCurrency,
          onBaseChanged: (v) => setState(() => _baseCurrency = v),
          buyCtrl: _buyRateCtrl,
          sellCtrl: _sellRateCtrl,
          onRateChanged: () => setState(() {}),
          spreadPreview: _dealerSpreadPreview,
        ),
      ],
    );
  }

  Widget _buildCurrencyDropdown({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onChanged,
    String? helperText,
  }) {
    final opts = List<String>.from(options);
    if (value.isNotEmpty && !opts.contains(value)) opts.insert(0, value);
    final effectiveValue =
        opts.contains(value) ? value : (opts.isNotEmpty ? opts.first : 'USD');
    return DropdownButtonFormField<String>(
      key: ValueKey('curr-dd-$label-$effectiveValue'),
      initialValue: effectiveValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
      items: opts
          .map(
            (c) => DropdownMenuItem(
              value: c,
              child: Row(
                children: [
                  Text(CurrencyUtils.flag(c)),
                  const SizedBox(width: 8),
                  Text(c),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _buildPreview() {
    final amount = double.tryParse(_amountController.text) ?? 0;
    final commissionValue =
        double.tryParse(_commissionValueController.text) ?? 0;
    final commission = _commissionType == CommissionType.percentage
        ? amount * commissionValue / 100
        : commissionValue;
    final rate = _toCurrency == _transferCurrency
        ? 1.0
        : _multiplierFromInput(
            double.tryParse(_exchangeRateController.text) ?? 1.0,
            _transferCurrency,
            _toCurrency,
          );
    // For fixed commission in different currency: fetch exchange rate. Percentage is already in transfer currency.
    final needsCommissionRate = _commissionType == CommissionType.fixed &&
        commission > 0 &&
        _commissionCurrency.isNotEmpty &&
        _commissionCurrency != _transferCurrency;
    final isDark = context.isDark;

    if (amount <= 0) return const SizedBox.shrink();

    // Desktop+dark: rich tilted "thermal-printer" receipt preview
    // (matches transfer-create-desktop reference). Mobile and light theme
    // keep the simpler breakdown card below.
    if (context.isDesktop && isDark) {
      return _buildDesktopReceipt(
        amount: amount,
        commission: commission,
        rate: rate,
        needsCommissionRate: needsCommissionRate,
      );
    }

    Widget previewContent;
    if (needsCommissionRate) {
      previewContent = FutureBuilder(
        future: sl<ExchangeRateRepository>()
            .getLatestRate(_commissionCurrency, _transferCurrency)
            .then((r) => r.fold((_) => null, (v) => v)),
        builder: (ctx, snap) {
          final commissionRate = snap.data?.rate ?? 0.0;
          final commissionInTransferCur = commissionRate > 0
              ? commission * commissionRate
              : commission;
          final receiverGets = (amount - commissionInTransferCur) * rate;
          final totalDebit = amount;
          if (commissionRate <= 0) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Text(
                'Курс $_commissionCurrency → $_transferCurrency не найден. '
                'Установите в настройках курсов валют.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            );
          }
          return _buildPreviewContent(
            amount: amount,
            commission: commission,
            commissionInTransferCur: commissionInTransferCur,
            totalDebit: totalDebit,
            receiverGets: receiverGets,
            isDark: isDark,
            showCommissionRateNote: true,
          );
        },
      );
    } else {
      final commissionInTransferCur = commission;
      final receiverGets = (amount - commissionInTransferCur) * rate;
      final totalDebit = amount;
      previewContent = _buildPreviewContent(
        amount: amount,
        commission: commission,
        commissionInTransferCur: commissionInTransferCur,
        totalDebit: totalDebit,
        receiverGets: receiverGets,
        isDark: isDark,
        showCommissionRateNote: false,
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: isDark ? 0.10 : 0.06),
            AppColors.primary.withValues(alpha: isDark ? 0.04 : 0.02),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: previewContent,
    );
  }

  Widget _buildDesktopReceipt({
    required double amount,
    required double commission,
    required double rate,
    required bool needsCommissionRate,
  }) {
    final fromBranch = _allBranches
        .where((b) => b.id == _fromBranchId)
        .cast<Branch?>()
        .firstWhere((_) => true, orElse: () => null);
    final toBranch = _allBranches
        .where((b) => b.id == _toBranchId)
        .cast<Branch?>()
        .firstWhere((_) => true, orElse: () => null);
    final user = context.read<AuthBloc>().state.user;
    final balance = context
            .read<DashboardBloc>()
            .state
            .accountBalances[_fromAccountId] ??
        0;

    final commLabel = _commissionType == CommissionType.percentage
        ? 'Комиссия (${_commissionValueController.text.isEmpty ? '0' : _commissionValueController.text}%)'
        : 'Комиссия';
    final commPayer = _commissionMode == CommissionMode.fromTransfer
        ? 'удерживается из перевода'
        : (_commissionMode == CommissionMode.fromAccount
            ? 'на отдельный счёт'
            : (_commissionMode == CommissionMode.fromSender
                ? 'отправитель'
                : 'получатель'));

    // Async branch: fetch commission FX if needed; otherwise compute synchronously.
    Widget receiptOf({
      required double commissionInTransferCur,
      required double receiverGets,
      required double totalDebit,
    }) =>
        LiveReceiptPreview(
          fromBranchName: fromBranch?.name ?? '—',
          fromBranchCode: fromBranch != null
              ? shortBranchCode(fromBranch.name,
                  explicitCode: fromBranch.code)
              : '—',
          fromCountryFlag:
              flagForBranchCountry(fromBranch?.address),
          toBranchName: toBranch?.name ?? '—',
          toBranchCode: toBranch != null
              ? shortBranchCode(toBranch.name, explicitCode: toBranch.code)
              : '—',
          toCountryFlag: flagForBranchCountry(toBranch?.address),
          fromCurrency: _transferCurrency,
          toCurrency: _toCurrency,
          amount: amount,
          received: receiverGets,
          rate: rate,
          commissionLabel: commLabel,
          commission: commission,
          commissionCurrency: _commissionCurrency,
          commissionPayer: commPayer,
          totalDebit: totalDebit,
          senderName: _senderNameCtrl.text.trim(),
          senderPhone: _senderPhoneCtrl.text.trim(),
          receiverName: _receiverNameCtrl.text.trim(),
          receiverPhone: _receiverPhoneCtrl.text.trim(),
          description: _descriptionCtrl.text.trim(),
          operatorName: user?.displayName ?? '—',
          operatorBranchCode: fromBranch?.code ?? '',
          draftId:
              'TR-DRAFT-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
          insufficient: (_commissionMode == CommissionMode.fromSender
                  ? amount + commission
                  : amount) >
              balance,
        );

    Widget centered(Widget child) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: child,
          ),
        );

    if (needsCommissionRate) {
      return centered(
        FutureBuilder(
          future: sl<ExchangeRateRepository>()
              .getLatestRate(_commissionCurrency, _transferCurrency)
              .then((r) => r.fold((_) => null, (v) => v)),
          builder: (ctx, snap) {
            final commissionRate = snap.data?.rate ?? 0.0;
            final commissionInTransferCur =
                commissionRate > 0 ? commission * commissionRate : commission;
            final receiverGets = (amount - commissionInTransferCur) * rate;
            return receiptOf(
              commissionInTransferCur: commissionInTransferCur,
              receiverGets: receiverGets,
              totalDebit: amount,
            );
          },
        ),
      );
    }
    final receiverGets = (amount - commission) * rate;
    return centered(
      receiptOf(
        commissionInTransferCur: commission,
        receiverGets: receiverGets,
        totalDebit: amount,
      ),
    );
  }

  Widget _buildPreviewContent({
    required double amount,
    required double commission,
    required double commissionInTransferCur,
    required double totalDebit,
    required double receiverGets,
    required bool isDark,
    bool showCommissionRateNote = false,
  }) {
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Заголовок + сумма к получению (главный показатель)
        Row(
          children: [
            Icon(AppIcons.calculate,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(
              'Предварительный расчёт',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: secondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Получатель получит',
          style: TextStyle(fontSize: 12, color: secondary),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                receiverGets.formatCurrencyNoDecimals(),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'JetBrains Mono',
                  letterSpacing: -0.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _toCurrency,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Divider(
          height: 1,
          color: AppColors.primary.withValues(alpha: 0.15),
        ),
        const SizedBox(height: AppSpacing.md),

        // Разбивка
        _BreakdownRow(
          label: 'Списание с отправителя',
          value: totalDebit,
          currency: _transferCurrency,
          icon: AppIcons.arrow_upward,
          iconColor: Colors.red.shade400,
        ),
        const SizedBox(height: 6),
        _BreakdownRow(
          label: _commissionType == CommissionType.percentage
              ? 'Комиссия (${_commissionValueController.text.isEmpty ? '0' : _commissionValueController.text}%)'
              : 'Комиссия',
          value: commission,
          currency: _commissionCurrency,
          icon: AppIcons.account_balance,
          iconColor: Colors.orange.shade400,
          extra: _commissionCurrency != _transferCurrency && commissionInTransferCur > 0
              ? '≈ ${commissionInTransferCur.formatCurrencyNoDecimals()} $_transferCurrency'
              : null,
        ),
        if (_toCurrency != _transferCurrency) ...[
          const SizedBox(height: 6),
          _BreakdownRow(
            label: 'Курс конвертации',
            value: null,
            currency: '',
            icon: AppIcons.swap_horiz,
            iconColor: AppColors.primary,
            customRight: _rateSummary(),
          ),
        ],
        if (showCommissionRateNote) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(AppIcons.info_outline, size: 12, color: secondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Курс комиссии в $_transferCurrency взят из настроек',
                  style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: secondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _rateSummary() {
    final input = double.tryParse(_exchangeRateController.text) ?? 0;
    if (input <= 0) return '—';
    final pair = _quotePair(_transferCurrency, _toCurrency);
    if (pair != null) {
      final (strong, weak) = pair;
      return '1 $strong = ${input.formatCurrency()} $weak';
    }
    return '1 $_transferCurrency = ${input.formatCurrency()} $_toCurrency';
  }

  Widget _buildSubmitButton(BuildContext context, TransferBlocState state) {
    final isCreating = state.status == TransferBlocStatus.creating;

    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: isCreating ? null : () => _submit(context),
        icon: isCreating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(AppIcons.send),
        label: Text(isCreating ? 'Обработка...' : 'Создать перевод'),
      ),
    );
  }

  Future<void> _submit(BuildContext context) async {
    if (!_formKey.currentState!.validate()) return;

    final amount = double.parse(_amountController.text);
    if (_fromAccountId == null) return;

    final balance = context.read<DashboardBloc>().state.accountBalances[_fromAccountId] ?? 0;
    // Pre-flight баланса: учитываем выбранный режим комиссии. Для
    // fromTransfer / fromAccount списание = amount; для fromSender —
    // amount + commission. Для toReceiver — amount (но он в UI скрыт).
    final commissionValueForCheck =
        double.tryParse(_commissionValueController.text) ?? 0;
    final commissionForCheck = _commissionType == CommissionType.percentage
        ? amount * commissionValueForCheck / 100
        : commissionValueForCheck;
    final totalDebit = _commissionMode == CommissionMode.fromSender
        ? amount + commissionForCheck
        : amount;
    if (totalDebit > balance) {
      setState(() {
        _balanceError = 'Недостаточно средств. Доступно: ${balance.formatCurrencyNoDecimals()}, требуется: ${totalDebit.formatCurrencyNoDecimals()} $_transferCurrency';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Недостаточно средств. Доступно: ${balance.formatCurrencyNoDecimals()} $_transferCurrency. '
            'Пополните счёт через «Пополнение филиала» (вкладка «Без источника»).',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    final commissionValue =
        double.tryParse(_commissionValueController.text) ?? 0;
    final rateInput = double.tryParse(_exchangeRateController.text) ?? 1.0;
    final exchangeRate = _toCurrency == _transferCurrency
        ? 1.0
        : _multiplierFromInput(rateInput, _transferCurrency, _toCurrency);
    if (_toCurrency != _transferCurrency && (rateInput <= 0 || exchangeRate <= 0)) {
      setState(() {
        _exchangeRateError = 'Укажите положительный курс для разных валют';
      });
      return;
    }
    final commission = _commissionType == CommissionType.percentage
        ? amount * commissionValue / 100
        : commissionValue;
    if (commission >= amount) {
      setState(() {
        _commissionError =
            'Комиссия должна быть меньше суммы перевода (режим: списание с отправителя)';
      });
      return;
    }
    final currency =
        _transferCurrency.isNotEmpty ? _transferCurrency : 'USD';
    final toCur = _toCurrency.isNotEmpty ? _toCurrency : currency;

    // Pre-flight: серверный private.fx_rate бросит исключение, если для пары
    // commission_currency → transfer_currency нет курса (ни прямого, ни
    // обратного).  Проверяем заранее и показываем понятную подсказку с
    // переходом в раздел «Курсы валют», иначе пользователь видит RAISE
    // EXCEPTION и думает, что что-то сломалось (см. жалобу: «курс в
    // настройках не настроена»).  Процентная комиссия и совпадающая валюта
    // в pre-flight не нуждаются — fx_rate их не запрашивает.
    if (_commissionType == CommissionType.fixed &&
        commission > 0 &&
        _commissionCurrency.isNotEmpty &&
        _commissionCurrency != currency) {
      // Захватываем все context-зависимые объекты ДО await, чтобы потом
      // не было use_build_context_synchronously — линтер не доверяет
      // mounted-check после async gap, а через локальные ссылки можно
      // безопасно дёргать messenger/theme/errorColor.
      final messenger = ScaffoldMessenger.of(context);
      final errorColor = Theme.of(context).colorScheme.error;
      void goToRates() => context.go('/exchange-rates');
      final direct = await sl<ExchangeRateRepository>()
          .getLatestRate(_commissionCurrency, currency)
          .then((r) => r.fold((_) => null, (v) => v));
      final inverse = direct == null
          ? await sl<ExchangeRateRepository>()
              .getLatestRate(currency, _commissionCurrency)
              .then((r) => r.fold((_) => null, (v) => v))
          : null;
      final hasRate =
          (direct?.rate ?? 0) > 0 || (inverse?.rate ?? 0) > 0;
      if (!hasRate) {
        if (!mounted) return;
        setState(() {
          _commissionError = 'Курс $_commissionCurrency → $currency не задан. '
              'Откройте «Курсы валют» и добавьте пару, либо установите валюту '
              'комиссии равной валюте перевода ($currency).';
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Не задан курс $_commissionCurrency → $currency для пересчёта комиссии. '
              'Перейдите в «Курсы валют» и добавьте пару.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: errorColor,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Открыть',
              textColor: Colors.white,
              onPressed: () {
                if (mounted) goToRates();
              },
            ),
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    if (_commissionMode == CommissionMode.fromAccount &&
        _commissionAccountId == null) {
      setState(() {
        _commissionError = 'Выберите счёт для зачисления комиссии';
      });
      return;
    }

    // F4 (AML/KYC) — НЕблокирующий предполётный скрин субъекта. Любая
    // ошибка скрина не мешает создать перевод; при срабатывании порога
    // оператор подтверждает вручную и флаг пишется в журнал.
    if (!context.mounted) return;
    final amlOk =
        await _amlPreflight(context, amount: amount, currency: currency);
    if (!amlOk) return;

    if (!context.mounted) return;
    context.read<TransferBloc>().add(TransferCreateRequested(
          fromBranchId: _fromBranchId!,
          toBranchId: _toBranchId!,
          fromAccountId: _fromAccountId!,
          toAccountId: null,
          toCurrency: toCur != currency ? toCur : null,
          amount: amount,
          currency: currency,
          exchangeRate: exchangeRate,
          commissionType: _commissionType.name,
          commissionValue: commissionValue,
          commissionCurrency: _commissionCurrency,
          commissionMode: _commissionMode.name,
          commissionAccountId: _commissionMode == CommissionMode.fromAccount
              ? _commissionAccountId
              : null,
          idempotencyKey: const Uuid().v4(),
          description: _descriptionCtrl.text.trim().isNotEmpty ? _descriptionCtrl.text.trim() : null,
          senderName: _senderNameCtrl.text.trim().isNotEmpty ? _senderNameCtrl.text.trim() : null,
          senderPhone: _senderPhoneCtrl.text.trim().isNotEmpty ? _senderPhoneCtrl.text.trim() : null,
          senderInfo: _senderInfoCtrl.text.trim().isNotEmpty ? _senderInfoCtrl.text.trim() : null,
          receiverName: _receiverNameCtrl.text.trim().isNotEmpty ? _receiverNameCtrl.text.trim() : null,
          receiverPhone: _receiverPhoneCtrl.text.trim().isNotEmpty ? _receiverPhoneCtrl.text.trim() : null,
          receiverInfo: _receiverInfoCtrl.text.trim().isNotEmpty ? _receiverInfoCtrl.text.trim() : null,
          // Dealer mode — только если toggle включён и оба курса валидны.
          buyRate: _dealerBuyValue > 0 && _dealerSellValue > 0 ? _dealerBuyValue : null,
          sellRate: _dealerBuyValue > 0 && _dealerSellValue > 0 ? _dealerSellValue : null,
          baseCurrency:
              _dealerBuyValue > 0 && _dealerSellValue > 0 ? _baseCurrency : null,
        ));
  }

  /// F4 (AML/KYC) — НЕблокирующий скрин субъекта перевода по телефону.
  /// Возвращает true, если можно продолжать. Любая ошибка/недоступность
  /// скрина => true: AML не должен мешать рабочему денежному потоку.
  /// При срабатывании порога показываем предупреждение; если оператор
  /// подтверждает — фиксируем флаг в журнале (best-effort) и продолжаем.
  Future<bool> _amlPreflight(
    BuildContext context, {
    required double amount,
    required String currency,
  }) async {
    final senderPhone = _senderPhoneCtrl.text.trim();
    final receiverPhone = _receiverPhoneCtrl.text.trim();
    final phone = senderPhone.isNotEmpty ? senderPhone : receiverPhone;
    if (phone.isEmpty) return true;
    final subjectName = senderPhone.isNotEmpty
        ? _senderNameCtrl.text.trim()
        : _receiverNameCtrl.text.trim();

    Map<String, dynamic> res;
    try {
      final raw = await Supabase.instance.client.rpc('aml_screen', params: {
        'p_subject_phone': phone,
        'p_amount': amount,
        'p_currency': currency,
        'p_has_id': false,
      }).timeout(const Duration(seconds: 8));
      if (raw is! Map) return true;
      res = Map<String, dynamic>.from(raw);
    } catch (_) {
      return true;
    }

    if (res['flagged'] != true) return true;
    final warnings = <String>[];
    final w = res['warnings'];
    if (w is List) {
      for (final x in w) {
        warnings.add(x.toString());
      }
    }
    if (warnings.isEmpty) return true;

    if (!context.mounted) return true;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(AppIcons.shield, color: AppColors.warning),
        title: const Text('Предупреждение AML / KYC'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Скрин субъекта выявил срабатывания. Это не блокирует '
              'операцию — решение за вами:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            for (final wn in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(AppIcons.error_outline,
                          size: 14, color: AppColors.warning),
                    ),
                    Expanded(
                      child:
                          Text(wn, style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Создать и отметить'),
          ),
        ],
      ),
    );

    if (proceed != true) return false;

    // Best-effort фиксация флага. transfer_id ещё нет (перевод не
    // создан) — журнал свяжет по телефону/сумме/времени.
    try {
      final high = res['overDaily'] == true || res['overMonthly'] == true;
      await Supabase.instance.client.rpc('aml_record_flag', params: {
        'p_flag_type': 'screening',
        'p_subject_phone': phone,
        if (subjectName.isNotEmpty) 'p_subject_name': subjectName,
        'p_currency': currency,
        'p_amount': amount,
        'p_severity': high ? 'high' : 'medium',
        'p_details': {'warnings': warnings, 'source': 'create_transfer'},
      }).timeout(const Duration(seconds: 8));
    } catch (_) {
      // Журналирование не критично — не мешаем созданию перевода.
    }
    return true;
  }

  double get _dealerBuyValue {
    if (!_dealerMode) return 0;
    return double.tryParse(_buyRateCtrl.text.replaceAll(',', '.')) ?? 0;
  }

  double get _dealerSellValue {
    if (!_dealerMode) return 0;
    return double.tryParse(_sellRateCtrl.text.replaceAll(',', '.')) ?? 0;
  }

  /// Spread profit preview (= amount − (amount/buy)*sell) в валюте перевода.
  double get _dealerSpreadPreview {
    if (!_dealerMode) return 0;
    final amt = double.tryParse(_amountController.text.replaceAll(',', '.')) ?? 0;
    if (amt <= 0 || _dealerBuyValue <= 0 || _dealerSellValue <= 0) return 0;
    if (_baseCurrency == _transferCurrency) return 0;
    return amt - (amt / _dealerBuyValue) * _dealerSellValue;
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ...children,
      ],
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.currency,
    required this.icon,
    required this.iconColor,
    this.extra,
    this.customRight,
  });

  final String label;
  final double? value;
  final String currency;
  final IconData icon;
  final Color iconColor;
  final String? extra;
  final String? customRight;

  @override
  Widget build(BuildContext context) {
    final secondary = context.isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Row(
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: secondary),
          ),
        ),
        if (customRight != null)
          Text(
            customRight!,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'JetBrains Mono',
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${value!.formatCurrencyNoDecimals()} $currency',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              if (extra != null)
                Text(
                  extra!,
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: secondary,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _CommissionBlock extends StatelessWidget {
  const _CommissionBlock({
    required this.type,
    required this.onTypeChanged,
    required this.valueController,
    required this.onValueTap,
    required this.onValueChange,
    required this.onValueBlur,
    required this.currency,
    required this.currencies,
    required this.onCurrencyChanged,
    required this.transferCurrency,
    required this.errorText,
    this.isFromAccountMode = false,
  });

  final CommissionType type;
  final ValueChanged<CommissionType> onTypeChanged;
  final TextEditingController valueController;
  final VoidCallback onValueTap;
  final VoidCallback onValueChange;
  final VoidCallback onValueBlur;
  final String currency;
  final List<String> currencies;
  final ValueChanged<String> onCurrencyChanged;
  final String transferCurrency;
  final String? errorText;

  /// Когда true — валюта блокируется и берётся из выбранного счёта.
  final bool isFromAccountMode;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final isPercent = type == CommissionType.percentage;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: isDark ? 0.4 : 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.account_balance,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'Комиссия',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              SegmentedButton<CommissionType>(
                segments: CommissionType.values
                    .map((t) => ButtonSegment<CommissionType>(
                          value: t,
                          label: Text(
                            t == CommissionType.percentage ? '%' : 'Фикс',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ))
                    .toList(),
                selected: {type},
                onSelectionChanged: (v) => onTypeChanged(v.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Focus(
                  onFocusChange: (f) {
                    if (!f) onValueBlur();
                  },
                  child: TextFormField(
                    controller: valueController,
                    decoration: InputDecoration(
                      labelText: isPercent ? 'Процент' : 'Сумма',
                      border: const OutlineInputBorder(),
                      suffixText: isPercent ? '%' : currency,
                      hintText: isPercent ? '1.5' : '100',
                      errorText: errorText,
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [DecimalInputFormatter()],
                    onTap: onValueTap,
                    onChanged: (_) => onValueChange(),
                  ),
                ),
              ),
              if (!isPercent) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: isFromAccountMode
                      ? InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Валюта',
                            helperText: 'из счёта',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(AppIcons.lock_outline, size: 16),
                            isDense: true,
                          ),
                          child: Text(
                            currency,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: currencies.contains(currency)
                              ? currency
                              : transferCurrency,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Валюта',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: currencies
                              .map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Row(
                                      children: [
                                        Text(CurrencyUtils.flag(c)),
                                        const SizedBox(width: 6),
                                        Text(c),
                                      ],
                                    ),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) onCurrencyChanged(v);
                          },
                        ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Переключатель режима списания комиссии.
///
/// В UI оставлены только два режима — этого хватает для всей бухгалтерии:
///   • [CommissionMode.fromTransfer] — комиссия удерживается из суммы перевода.
///   • [CommissionMode.fromAccount]  — комиссия списывается с отдельного счёта
///     филиала (валюта берётся из этого счёта автоматически).
///
/// Режимы [CommissionMode.fromSender] / [CommissionMode.toReceiver] остаются
/// в enum (исторические переводы и серверные RPC), но в форме создания не
/// показываются — это путало операторов.
class _CommissionModePicker extends StatelessWidget {
  const _CommissionModePicker({
    required this.mode,
    required this.onChanged,
  });

  final CommissionMode mode;
  final ValueChanged<CommissionMode> onChanged;

  static const _visibleModes = [
    CommissionMode.fromTransfer,
    CommissionMode.fromAccount,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _visibleModes.contains(mode) ? mode : CommissionMode.fromTransfer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Режим комиссии',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        SegmentedButton<CommissionMode>(
          segments: _visibleModes
              .map((m) => ButtonSegment<CommissionMode>(
                    value: m,
                    label: Text(
                      m == CommissionMode.fromTransfer
                          ? 'Внутри перевода'
                          : 'На отдельный счёт',
                      style: const TextStyle(fontSize: 12),
                    ),
                    icon: Icon(
                      m == CommissionMode.fromTransfer
                          ? Icons.call_merge
                          : Icons.account_balance_wallet_outlined,
                      size: 16,
                    ),
                  ))
              .toList(),
          selected: {selected},
          onSelectionChanged: (v) => onChanged(v.first),
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: WidgetStateProperty.all(
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          selected.description,
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Read-only визуальное поле для валюты перевода. Берётся из выбранного
/// from-account и не редактируется отдельно от него.
class _LockedCurrencyField extends StatelessWidget {
  const _LockedCurrencyField({
    required this.label,
    required this.currency,
    required this.helperText,
  });

  final String label;
  final String? currency;
  final String helperText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        helperText: helperText,
        helperMaxLines: 2,
        prefixIcon: const Icon(AppIcons.lock_outline, size: 18),
      ),
      child: Row(
        children: [
          if (currency != null) ...[
            Text(CurrencyUtils.flag(currency!)),
            const SizedBox(width: 8),
            Text(
              currency!,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ] else
            Text(
              '—',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}

String _formatInsufficientFundsError(String msg) {
  final match = RegExp(r'Available:\s*([\d.]+),\s*required:\s*([\d.]+)', caseSensitive: false).firstMatch(msg);
  if (match != null) {
    final avail = double.tryParse(match.group(1) ?? '0') ?? 0;
    final req = double.tryParse(match.group(2) ?? '0') ?? 0;
    return 'Недостаточно средств. Доступно: ${avail.toStringAsFixed(0)}, требуется: ${req.toStringAsFixed(0)}';
  }
  if (msg.toLowerCase().contains('insufficient')) {
    return 'Недостаточно средств на счёте';
  }
  return msg;
}

/// Дилерская модель: toggle + поля buy/sell rate + base + live preview
/// spread. Идентичен по UX с partner_transfer_dialog._DealerModeToggle.
class _DealerModeBlock extends StatelessWidget {
  const _DealerModeBlock({
    required this.enabled,
    required this.onToggle,
    required this.baseCurrency,
    required this.sourceCurrency,
    required this.onBaseChanged,
    required this.buyCtrl,
    required this.sellCtrl,
    required this.onRateChanged,
    required this.spreadPreview,
  });
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final String baseCurrency;
  final String sourceCurrency;
  final ValueChanged<String> onBaseChanged;
  final TextEditingController buyCtrl;
  final TextEditingController sellCtrl;
  final VoidCallback onRateChanged;
  final double spreadPreview;

  static const _bases = ['USD', 'EUR', 'RUB', 'UZS', 'KZT'];

  /// Тянет последний рыночный курс из exchange_rates: base → sourceCurrency.
  /// Если пара есть напрямую → подставляет в buyCtrl. Если только обратная
  /// (sourceCurrency → base) → инвертирует.
  Future<void> _fillMarketRate(BuildContext context) async {
    if (baseCurrency == sourceCurrency) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final direct = await sl<ExchangeRateRepository>()
          .getLatestRate(baseCurrency, sourceCurrency)
          .then((r) => r.fold((_) => null, (v) => v));
      double? rate = (direct?.rate ?? 0) > 0 ? direct!.rate : null;
      if (rate == null) {
        final inverse = await sl<ExchangeRateRepository>()
            .getLatestRate(sourceCurrency, baseCurrency)
            .then((r) => r.fold((_) => null, (v) => v));
        if ((inverse?.rate ?? 0) > 0) rate = 1 / inverse!.rate;
      }
      if (rate == null || rate <= 0) {
        messenger.showSnackBar(SnackBar(
          content: Text(
              'Нет курса $baseCurrency → $sourceCurrency. Добавь в «Курсы валют».'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      buyCtrl.text =
          rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();
      // Sell обычно ниже buy на маржу — оставляем пустым чтобы оператор
      // ввёл вручную (или подставил такой же если без spread).
      onRateChanged();
      messenger.showSnackBar(SnackBar(
        content: Text('Buy подставлен: 1 $baseCurrency = $rate $sourceCurrency'),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Не удалось получить курс: $e'),
        backgroundColor: AppColors.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: enabled
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: enabled
              ? scheme.primary.withValues(alpha: 0.25)
              : scheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Switch(
                value: enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Дилерская модель (учёт курсовой прибыли)',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: enabled ? scheme.primary : null,
                      ),
                    ),
                    Text(
                      enabled
                          ? 'Buy rate (что говорим клиенту) / Sell rate (внутренний) → spread profit'
                          : 'Включи если у тебя есть внутренний курс отличный от клиентского',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _bases.contains(baseCurrency) ? baseCurrency : 'USD',
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Base',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: _bases
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c,
                                  style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) onBaseChanged(v);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: buyCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [DecimalInputFormatter()],
                    onChanged: (_) => onRateChanged(),
                    decoration: InputDecoration(
                      labelText: 'Buy rate',
                      helperText: '1 $baseCurrency = X $sourceCurrency',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: sellCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [DecimalInputFormatter()],
                    onChanged: (_) => onRateChanged(),
                    decoration: InputDecoration(
                      labelText: 'Sell rate',
                      helperText: '1 $baseCurrency = Y $sourceCurrency',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: baseCurrency == sourceCurrency
                    ? null
                    : () => _fillMarketRate(context),
                icon: const Icon(AppIcons.refresh, size: 14),
                label: const Text('Подставить рыночный курс',
                    style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 0),
                ),
              ),
            ),
            if (spreadPreview.abs() > 0.005) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 6),
                decoration: BoxDecoration(
                  color: spreadPreview > 0
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(
                      spreadPreview > 0
                          ? Icons.trending_up
                          : Icons.trending_down,
                      size: 16,
                      color: spreadPreview > 0
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        spreadPreview > 0
                            ? 'Прибыль с курса: +${spreadPreview.toStringAsFixed(0)} $sourceCurrency'
                            : 'Убыток с курса: ${spreadPreview.toStringAsFixed(0)} $sourceCurrency',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: spreadPreview > 0
                              ? Colors.green.shade800
                              : Colors.red.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ─── Hero-layout helper widgets ──────────────────────────────────

class _HeroSectionHeading extends StatelessWidget {
  const _HeroSectionHeading({
    required this.title,
    required this.icon,
    this.subtitle,
  });
  final String title;
  final IconData icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 14, color: AppColors.darkTextSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: AppColors.darkTextPrimary,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.darkTextTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PartyCard extends StatelessWidget {
  const _PartyCard({
    required this.role,
    required this.accent,
    required this.isSender,
    required this.nameCtrl,
    required this.phoneCtrl,
    required this.infoCtrl,
    this.onCurrencyPicked,
  });
  final String role;
  final Color accent;
  final bool isSender;
  final TextEditingController nameCtrl;
  final TextEditingController phoneCtrl;
  final TextEditingController infoCtrl;
  final ValueChanged<String>? onCurrencyPicked;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isSender ? AppIcons.arrow_upward : AppIcons.arrow_downward,
                  size: 12,
                  color: accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                role.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: accent,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(
                height: 1, thickness: 0.6, color: AppColors.darkDivider),
          ),
          _HeroIconField(
            controller: nameCtrl,
            icon: AppIcons.person_outline,
            hint: 'ФИО или организация',
          ),
          const SizedBox(height: 9),
          ContactAutocompleteField(
            side: isSender ? 'sender' : 'receiver',
            phoneController: phoneCtrl,
            nameController: nameCtrl,
            infoController: infoCtrl,
            label: 'Телефон',
            hintText: isSender ? '+7 900 123 45 67' : '+998 90 123 45 67',
            onCurrencyPicked: onCurrencyPicked,
          ),
          const SizedBox(height: 9),
          _HeroIconField(
            controller: infoCtrl,
            icon: AppIcons.info_outline,
            hint: 'Документ (опционально)',
            mono: true,
          ),
        ],
      ),
    );
  }
}

class _HeroIconField extends StatelessWidget {
  const _HeroIconField({
    required this.controller,
    required this.icon,
    required this.hint,
    this.mono = false,
  });
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool mono;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: mono
          ? const TextStyle(
              fontSize: 13,
              fontFamily: 'JetBrains Mono',
              color: AppColors.darkTextPrimary,
            )
          : const TextStyle(
              fontSize: 13,
              color: AppColors.darkTextPrimary,
            ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontSize: 13,
          color: AppColors.darkTextDisabled,
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Icon(icon, size: 14, color: AppColors.darkTextTertiary),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 0),
        isDense: true,
        filled: true,
        fillColor: AppColors.darkSurface,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
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
          borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
        ),
      ),
    );
  }
}

class _GradientPrimaryButton extends StatelessWidget {
  const _GradientPrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.loading = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: enabled ? AppColors.primaryGradient : null,
            color: enabled ? null : AppColors.darkCardHover,
            borderRadius: BorderRadius.circular(10),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.5),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled ? onPressed : null,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppColors.darkBg),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 16,
                          color: enabled
                              ? AppColors.darkBg
                              : AppColors.darkTextTertiary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: enabled
                                ? AppColors.darkBg
                                : AppColors.darkTextTertiary,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

