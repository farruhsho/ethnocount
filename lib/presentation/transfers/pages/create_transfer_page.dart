import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:flutter/services.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/core/utils/phone_input_formatter.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:uuid/uuid.dart';

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

  // ── Phone-based contact lookup ──
  // Когда оператор вводит номер, который уже встречался в истории,
  // подтягиваем имя/доп.инфо/валюту из самого свежего перевода. Поля
  // остаются редактируемыми. Чтобы не клабить уже введённые оператором
  // данные, перезаписываем только пустые поля. После автозаполнения
  // показываем хинт под полем, чтобы было видно «откуда взялось».
  Timer? _senderLookupDebounce;
  Timer? _receiverLookupDebounce;
  String? _senderAutofillHint;
  String? _receiverAutofillHint;
  String _lastSenderLookup = '';
  String _lastReceiverLookup = '';

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

  /// «Сильные» валюты — те, у которых обычно мало единиц на 1 USD.
  /// Курс между «сильной» и «слабой» котируется как «1 [сильная] = X [слабая]».
  static const _strongCurrencies = {'USD', 'USDT', 'EUR', 'GBP'};

  /// Возвращает (strong, weak) если в паре есть «сильная»; иначе null.
  (String, String)? _quotePair(String from, String to) {
    final fromStrong = _strongCurrencies.contains(from);
    final toStrong = _strongCurrencies.contains(to);
    if (fromStrong && !toStrong) return (from, to);
    if (!fromStrong && toStrong) return (to, from);
    return null; // обе сильные или обе слабые — котируем напрямую multiplier'ом
  }

  /// Конвертирует значение из поля курса в multiplier from→to.
  /// Если пара котируется как «1 strong = X weak», то:
  ///   - strong → weak: multiplier = X
  ///   - weak → strong: multiplier = 1 / X
  /// Иначе значение в поле — это уже multiplier from→to.
  double _multiplierFromInput(double input, String from, String to) {
    final pair = _quotePair(from, to);
    if (pair == null) return input;
    final (strong, _) = pair;
    return from == strong ? input : (input == 0 ? 0 : 1 / input);
  }

  String _rateLabel(String from, String to) {
    final pair = _quotePair(from, to);
    if (pair == null) return 'Курс $from → $to';
    final (strong, weak) = pair;
    return '1 $strong = ? $weak';
  }

  String _rateHint(String from, String to) {
    final pair = _quotePair(from, to);
    if (pair == null) return '1.0';
    final (strong, weak) = pair;
    // Пара-подсказка по типичной валюте.
    if (strong == 'USD' && weak == 'UZS') return '12780';
    if (strong == 'USD' && weak == 'RUB') return '92';
    if (strong == 'USD' && weak == 'KZT') return '522';
    if (strong == 'EUR' && weak == 'USD') return '1.085';
    return '1.0';
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
  String _transferCurrency = 'USD';
  String _toCurrency = 'USD';
  String _commissionCurrency = 'USD';

  String? _fromBranchId;
  String? _toBranchId;
  String? _fromAccountId;

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
    _senderLookupDebounce?.cancel();
    _receiverLookupDebounce?.cancel();
    super.dispose();
  }

  /// Дебаунс-обёртка над `findContactByPhone` для одной из сторон ('sender'
  /// либо 'receiver'). Срабатывает через 600 мс после последней правки поля.
  /// Не запрашивает повторно один и тот же номер. Заполняет только пустые
  /// поля, чтобы не перезатереть введённое оператором.
  void _scheduleContactLookup({required String side}) {
    final isSender = side == 'sender';
    final phoneCtrl = isSender ? _senderPhoneCtrl : _receiverPhoneCtrl;
    if (isSender) {
      _senderLookupDebounce?.cancel();
    } else {
      _receiverLookupDebounce?.cancel();
    }
    final phone = phoneCtrl.text.trim();
    if (phone.length < 4) {
      // Слишком короткий номер — снимаем подсказку, если была.
      if (mounted) {
        setState(() {
          if (isSender) {
            _senderAutofillHint = null;
          } else {
            _receiverAutofillHint = null;
          }
        });
      }
      return;
    }
    final timer = Timer(const Duration(milliseconds: 600), () async {
      // Проверяем, что значение не изменилось пока мы спали.
      if (phoneCtrl.text.trim() != phone) return;
      // И что мы не дёргали тот же номер только что.
      if (isSender && _lastSenderLookup == phone) return;
      if (!isSender && _lastReceiverLookup == phone) return;
      try {
        final snap = await sl<TransferRemoteDataSource>()
            .findContactByPhone(phone: phone, side: side);
        if (!mounted) return;
        if (isSender) {
          _lastSenderLookup = phone;
        } else {
          _lastReceiverLookup = phone;
        }
        if (snap == null) {
          setState(() {
            if (isSender) {
              _senderAutofillHint = null;
            } else {
              _receiverAutofillHint = null;
            }
          });
          return;
        }
        final nameCtrl = isSender ? _senderNameCtrl : _receiverNameCtrl;
        final infoCtrl = isSender ? _senderInfoCtrl : _receiverInfoCtrl;
        final filled = <String>[];
        if ((snap.name ?? '').trim().isNotEmpty &&
            nameCtrl.text.trim().isEmpty) {
          nameCtrl.text = snap.name!.trim();
          filled.add('имя');
        }
        if ((snap.info ?? '').trim().isNotEmpty &&
            infoCtrl.text.trim().isEmpty) {
          infoCtrl.text = snap.info!.trim();
          filled.add('доп. инфо');
        }
        // Валюту трогаем только для «отправителя» (валюта перевода логически
        // привязана к источнику). И только если оператор не успел поменять
        // её вручную — иначе оставляем как есть.
        if (isSender &&
            (snap.currency ?? '').isNotEmpty &&
            snap.currency != _transferCurrency &&
            _availableCurrencies().contains(snap.currency)) {
          setState(() => _transferCurrency = snap.currency!);
          filled.add('валюту ${snap.currency}');
        }
        setState(() {
          final hint = filled.isEmpty
              ? 'Найдено в истории — данные совпадают'
              : 'Подставлено из истории: ${filled.join(', ')} (можно изменить)';
          if (isSender) {
            _senderAutofillHint = hint;
          } else {
            _receiverAutofillHint = hint;
          }
        });
      } catch (_) {
        // Ошибки поиска не должны мешать оператору. Просто молча скрываем хинт.
        if (mounted) {
          setState(() {
            if (isSender) {
              _senderAutofillHint = null;
            } else {
              _receiverAutofillHint = null;
            }
          });
        }
      }
    });
    if (isSender) {
      _senderLookupDebounce = timer;
    } else {
      _receiverLookupDebounce = timer;
    }
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('Новый перевод'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
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
                      : const Icon(Icons.check_rounded),
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
                            : const Icon(Icons.send_rounded),
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

  Widget _buildSenderSection() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (prev, curr) => prev.branches != curr.branches,
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final senderBranches = _branches.isNotEmpty
            ? _branches
            : filterBranchesByAccess(dash.branches, user);

        return _FormSection(
          title: 'Отправитель',
          icon: Icons.arrow_upward_rounded,
          children: [
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
                  .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
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
                      _transferCurrency = match.first.currency;
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
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Доступно: ${balance.formatCurrencyNoDecimals()} $_transferCurrency',
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
            prefixIcon: Icon(Icons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _senderPhoneCtrl,
          decoration: InputDecoration(
            labelText: 'Телефон отправителя',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.phone_outlined, size: 20),
            isDense: true,
            hintText: '+7 900 123 45 67',
            helperText: _senderAutofillHint,
            helperMaxLines: 2,
            helperStyle: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            PhoneInputFormatter(),
            LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
          ],
          onChanged: (_) => _scheduleContactLookup(side: 'sender'),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _senderInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.info_outline, size: 20),
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
          icon: Icons.arrow_downward_rounded,
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
            prefixIcon: Icon(Icons.description_outlined, size: 20),
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
            prefixIcon: Icon(Icons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _receiverPhoneCtrl,
          decoration: InputDecoration(
            labelText: 'Телефон получателя',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.phone_outlined, size: 20),
            isDense: true,
            hintText: '+998 90 123 45 67',
            helperText: _receiverAutofillHint,
            helperMaxLines: 2,
            helperStyle: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            PhoneInputFormatter(),
            LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
          ],
          onChanged: (_) => _scheduleContactLookup(side: 'receiver'),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _receiverInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.info_outline, size: 20),
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
      icon: Icons.tune_rounded,
      children: [
        // ── Сумма + валюта отправителя в одной строке ──
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
                  prefixIcon: const Icon(Icons.payments_outlined),
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
              child: _buildCurrencyDropdown(
                label: 'Валюта',
                value: _transferCurrency,
                options: senderCurrencies,
                onChanged: (v) {
                  setState(() {
                    _transferCurrency = v;
                    if (_toCurrency == _transferCurrency ||
                        !_availableCurrencies().contains(_toCurrency)) {
                      _toCurrency = _transferCurrency;
                    }
                    if (!_availableCurrencies().contains(_commissionCurrency)) {
                      _commissionCurrency = _transferCurrency;
                    }
                    _resetRateInput();
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        // ── Валюта получателя ──
        Builder(builder: (_) {
          final receiverBranch = _allBranches
              .where((b) => b.id == _toBranchId)
              .cast<Branch?>()
              .firstWhere((_) => true, orElse: () => null);
          final receiverCurrencies =
              _availableCurrencies(branch: receiverBranch);
          final isSame = _toCurrency == _transferCurrency;
          return Row(
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
                        prefixIcon: const Icon(Icons.swap_horiz_rounded),
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
          );
        }),
        const SizedBox(height: AppSpacing.lg),

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
            Icon(Icons.calculate_outlined,
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
          icon: Icons.arrow_upward_rounded,
          iconColor: Colors.red.shade400,
        ),
        const SizedBox(height: 6),
        _BreakdownRow(
          label: _commissionType == CommissionType.percentage
              ? 'Комиссия (${_commissionValueController.text.isEmpty ? '0' : _commissionValueController.text}%)'
              : 'Комиссия',
          value: commission,
          currency: _commissionCurrency,
          icon: Icons.account_balance_outlined,
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
            icon: Icons.swap_horiz_rounded,
            iconColor: AppColors.primary,
            customRight: _rateSummary(),
          ),
        ],
        if (showCommissionRateNote) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(Icons.info_outline, size: 12, color: secondary),
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
            : const Icon(Icons.send_rounded),
        label: Text(isCreating ? 'Обработка...' : 'Создать перевод'),
      ),
    );
  }

  Future<void> _submit(BuildContext context) async {
    if (!_formKey.currentState!.validate()) return;

    final amount = double.parse(_amountController.text);
    if (_fromAccountId == null) return;

    final balance = context.read<DashboardBloc>().state.accountBalances[_fromAccountId] ?? 0;
    final totalDebit = amount; // CommissionMode.fromTransfer — списание = сумма
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не задан курс $_commissionCurrency → $currency для пересчёта комиссии. '
              'Перейдите в «Курсы валют» и добавьте пару.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Открыть',
              textColor: Colors.white,
              onPressed: () => context.go('/exchange-rates'),
            ),
          ),
        );
        return;
      }
    }

    if (!mounted) return;
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
          commissionMode: CommissionMode.fromTransfer.name,
          idempotencyKey: const Uuid().v4(),
          description: _descriptionCtrl.text.trim().isNotEmpty ? _descriptionCtrl.text.trim() : null,
          senderName: _senderNameCtrl.text.trim().isNotEmpty ? _senderNameCtrl.text.trim() : null,
          senderPhone: _senderPhoneCtrl.text.trim().isNotEmpty ? _senderPhoneCtrl.text.trim() : null,
          senderInfo: _senderInfoCtrl.text.trim().isNotEmpty ? _senderInfoCtrl.text.trim() : null,
          receiverName: _receiverNameCtrl.text.trim().isNotEmpty ? _receiverNameCtrl.text.trim() : null,
          receiverPhone: _receiverPhoneCtrl.text.trim().isNotEmpty ? _receiverPhoneCtrl.text.trim() : null,
          receiverInfo: _receiverInfoCtrl.text.trim().isNotEmpty ? _receiverInfoCtrl.text.trim() : null,
        ));
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
              Icon(Icons.account_balance_outlined,
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
                  child: DropdownButtonFormField<String>(
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
          const SizedBox(height: 6),
          Text(
            CommissionMode.fromTransfer.description,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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

