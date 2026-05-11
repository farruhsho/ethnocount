import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/services/credential_storage_service.dart';
import 'package:ethnocount/domain/repositories/auth_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _systemInitialized = true;
  bool _rememberMe = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _checkSystemInit();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final creds = await sl<CredentialStorageService>().loadCredentials();
      if (!mounted) return;
      setState(() {
        _rememberMe = creds.rememberMe;
        if (creds.email != null) {
          _emailCtrl.text = creds.email!;
          _passwordCtrl.text = creds.password ?? '';
        }
      });
    } catch (_) {/* keychain недоступен — продолжаем без автозаполнения */}
  }

  Future<void> _checkSystemInit() async {
    try {
      final initialized = await sl<AuthRepository>().isSystemInitialized();
      if (mounted) setState(() => _systemInitialized = initialized);
    } catch (_) {
      if (mounted) setState(() => _systemInitialized = true);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onLogin() {
    if (!_formKey.currentState!.validate()) return;
    TextInput.finishAutofillContext();
    context.read<AuthBloc>().add(AuthSignInRequested(
          _emailCtrl.text.trim(),
          _passwordCtrl.text,
          rememberMe: _rememberMe,
        ));
  }

  Future<void> _onRememberToggled(bool v) async {
    setState(() => _rememberMe = v);
    try {
      await sl<CredentialStorageService>().saveRememberMePreference(v);
    } catch (_) {/* sync best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state.status == AuthStatus.error) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.errorMessage ?? 'Ошибка авторизации'),
                backgroundColor: AppColors.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else if (state.status == AuthStatus.authenticated) {
            context.go('/');
          }
        },
        builder: (context, state) {
          final isLoading = state.status == AuthStatus.loading;
          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 1000;
              if (isWide) {
                return Row(
                  children: [
                    const Expanded(flex: 5, child: _BrandPanel()),
                    Expanded(
                      flex: 6,
                      child: _FormPanel(
                        formKey: _formKey,
                        emailCtrl: _emailCtrl,
                        passwordCtrl: _passwordCtrl,
                        rememberMe: _rememberMe,
                        showPassword: _showPassword,
                        onTogglePassword: () =>
                            setState(() => _showPassword = !_showPassword),
                        onRememberToggle: _onRememberToggled,
                        onLogin: _onLogin,
                        onForgot: () => context.push('/forgot-password'),
                        onSetup: () => context.go('/register'),
                        isLoading: isLoading,
                        showSetupCallout: !_systemInitialized,
                      ),
                    ),
                  ],
                );
              }
              return _MobileLayout(
                formKey: _formKey,
                emailCtrl: _emailCtrl,
                passwordCtrl: _passwordCtrl,
                rememberMe: _rememberMe,
                showPassword: _showPassword,
                onTogglePassword: () =>
                    setState(() => _showPassword = !_showPassword),
                onRememberToggle: _onRememberToggled,
                onLogin: _onLogin,
                onForgot: () => context.push('/forgot-password'),
                onSetup: () => context.go('/register'),
                isLoading: isLoading,
                showSetupCallout: !_systemInitialized,
              );
            },
          );
        },
      ),
    );
  }
}

// ─── Brand Panel (desktop only) ─────────────────────────────────

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    // Чистый «банковский» левый блок: без декоративных glow'ов и
    // градиентов в стиле криптофинтеха — пользователь явно попросил
    // «посерьёзнее». Плотная сетка из заголовка, фактических цифр
    // казначейства и compliance-строк.
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.darkBg,
        border: Border(
          right: BorderSide(color: AppColors.darkBorder, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 48, 56, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _BrandLogoRow(),
            const SizedBox(height: 56),
            _BrandHero(),
            const SizedBox(height: 36),
            const _TrustStrip(),
            const Spacer(),
            const _BrandFooter(),
          ],
        ),
      ),
    );
  }
}

/// Строгий лого-блок: квадратный монограм-знак с тонкой обводкой,
/// без свечения. Сверху наименование, снизу институциональная подпись.
class _BrandLogoRow extends StatelessWidget {
  const _BrandLogoRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.primary, width: 1.2),
          ),
          alignment: Alignment.center,
          child: Text(
            'E',
            style: GoogleFonts.inter(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: AppColors.primary,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ETHNO LOGISTICS',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: AppColors.darkTextPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'INTERNAL TREASURY',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.4,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Сухие «доверительные» атрибуты: SOC-style строки вместо игрушечной
/// сетки флагов. Передаёт ощущение enterprise-системы.
class _TrustStrip extends StatelessWidget {
  const _TrustStrip();

  static const _items = [
    ('AES-256 + RLS', 'Шифрование данных и построчный контроль доступа'),
    ('AUDIT TRAIL', 'Каждое действие фиксируется в неизменяемом журнале'),
    ('TOTP / BIOMETRIC', 'Подтверждение критических операций'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            border: Border.all(color: AppColors.darkBorder, width: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'СИСТЕМА БЕЗОПАСНОСТИ',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 10,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
              color: AppColors.darkTextSecondary,
            ),
          ),
        ),
        const SizedBox(height: 18),
        for (final item in _items) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 6),
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.rectangle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.$1,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.$2,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: AppColors.darkTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _BrandHero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Спокойный заголовок: один вес, без градиентного шейдера —
          // он смотрелся «потребительски». Здесь приоритет — читаемость
          // и серьёзный тон.
          Text(
            'Управление казначейством\nмежду филиалами',
            style: GoogleFonts.inter(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              height: 1.18,
              color: AppColors.darkTextPrimary,
            ),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              'Закрытая система учёта переводов, остатков и комиссий '
              'между филиалами Ethno Logistics. Доступ — только для '
              'авторизованных сотрудников.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.55,
                color: AppColors.darkTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// _CountryGrid removed: исторически показывала эмодзи-флаги стран
// присутствия. Слишком «потребительский» вид для внутренней системы —
// заменено на _TrustStrip (compliance-атрибуты).

class _BrandFooter extends StatelessWidget {
  const _BrandFooter();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.darkDivider, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'End-to-end шифрование · Supabase Auth',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ),
          Text(
            '© 2026 Ethno',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Form Panel (desktop right column / mobile body) ────────────

class _FormPanel extends StatelessWidget {
  const _FormPanel({
    required this.formKey,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.rememberMe,
    required this.showPassword,
    required this.onTogglePassword,
    required this.onRememberToggle,
    required this.onLogin,
    required this.onForgot,
    required this.onSetup,
    required this.isLoading,
    required this.showSetupCallout,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final bool rememberMe;
  final bool showPassword;
  final VoidCallback onTogglePassword;
  final ValueChanged<bool> onRememberToggle;
  final VoidCallback onLogin;
  final VoidCallback onForgot;
  final VoidCallback onSetup;
  final bool isLoading;
  final bool showSetupCallout;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.darkBg,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: 64, vertical: 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: _LoginForm(
                    formKey: formKey,
                    emailCtrl: emailCtrl,
                    passwordCtrl: passwordCtrl,
                    rememberMe: rememberMe,
                    showPassword: showPassword,
                    onTogglePassword: onTogglePassword,
                    onRememberToggle: onRememberToggle,
                    onLogin: onLogin,
                    onForgot: onForgot,
                    onSetup: onSetup,
                    isLoading: isLoading,
                    showSetupCallout: showSetupCallout,
                  ),
                ),
              ),
            ),
          ),
          const _FormFooter(),
        ],
      ),
    );
  }
}

class _FormFooter extends StatelessWidget {
  const _FormFooter();

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(DateTime.now());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.darkDivider, width: 0.5),
        ),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: const [
              _FooterLink('Условия использования'),
              _FooterLink('Политика конфиденциальности'),
              _FooterLink('Поддержка'),
            ],
          ),
          Text(
            'build 2.4 · $dateStr',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11.5,
              color: AppColors.darkTextTertiary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(fontSize: 11.5, color: AppColors.darkTextTertiary),
    );
  }
}

// ─── Mobile layout ──────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.formKey,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.rememberMe,
    required this.showPassword,
    required this.onTogglePassword,
    required this.onRememberToggle,
    required this.onLogin,
    required this.onForgot,
    required this.onSetup,
    required this.isLoading,
    required this.showSetupCallout,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final bool rememberMe;
  final bool showPassword;
  final VoidCallback onTogglePassword;
  final ValueChanged<bool> onRememberToggle;
  final VoidCallback onLogin;
  final VoidCallback onForgot;
  final VoidCallback onSetup;
  final bool isLoading;
  final bool showSetupCallout;

  @override
  Widget build(BuildContext context) {
    // Mobile layout без декоративных glow'ов: серый дарк-фон, флэт-лого,
    // плотная вертикаль формы. Глаз сразу падает на «email/пароль».
    return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Logo
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.darkCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppColors.primary,
                          width: 1.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.transparent,
                            blurRadius: 0,
                            offset: Offset(0, 0),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'E',
                        style: GoogleFonts.inter(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: AppColors.primary,
                          height: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ETHNO LOGISTICS',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                            color: AppColors.darkTextPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'INTERNAL TREASURY',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.4,
                            color: AppColors.darkTextTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                _LoginForm(
                  formKey: formKey,
                  emailCtrl: emailCtrl,
                  passwordCtrl: passwordCtrl,
                  rememberMe: rememberMe,
                  showPassword: showPassword,
                  onTogglePassword: onTogglePassword,
                  onRememberToggle: onRememberToggle,
                  onLogin: onLogin,
                  onForgot: onForgot,
                  onSetup: onSetup,
                  isLoading: isLoading,
                  showSetupCallout: showSetupCallout,
                ),
              ],
            ),
          ),
        );
  }
}

// ─── Shared form body ───────────────────────────────────────────

class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.formKey,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.rememberMe,
    required this.showPassword,
    required this.onTogglePassword,
    required this.onRememberToggle,
    required this.onLogin,
    required this.onForgot,
    required this.onSetup,
    required this.isLoading,
    required this.showSetupCallout,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final bool rememberMe;
  final bool showPassword;
  final VoidCallback onTogglePassword;
  final ValueChanged<bool> onRememberToggle;
  final VoidCallback onLogin;
  final VoidCallback onForgot;
  final VoidCallback onSetup;
  final bool isLoading;
  final bool showSetupCallout;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ChipPill(
              icon: Icons.fingerprint_rounded,
              iconColor: AppColors.primary,
              label: 'Авторизация сотрудника',
              bg: AppColors.darkCard,
              borderColor: AppColors.darkBorder,
              textColor: AppColors.darkTextSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              'Вход в систему',
              style: GoogleFonts.inter(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: AppColors.darkTextPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Используйте корпоративный email. Доступ предоставляется '
              'администратором компании.',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppColors.darkTextSecondary,
              ),
            ),
            const SizedBox(height: 28),
            _AuthField(
              label: 'EMAIL',
              icon: Icons.mail_outline_rounded,
              controller: emailCtrl,
              hint: 'name@ethno-logistics.uz',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email,
              ],
              validator: (v) => v != null && v.contains('@')
                  ? null
                  : 'Введите корректный email',
            ),
            const SizedBox(height: 14),
            _AuthField(
              label: 'ПАРОЛЬ',
              icon: Icons.lock_outline_rounded,
              controller: passwordCtrl,
              hint: 'Минимум 6 символов',
              obscure: !showPassword,
              textInputAction: TextInputAction.done,
              onSubmit: (_) => onLogin(),
              autofillHints: const [AutofillHints.password],
              suffix: IconButton(
                icon: Icon(
                  showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: AppColors.darkTextTertiary,
                ),
                onPressed: onTogglePassword,
                splashRadius: 18,
              ),
              trailingAction: TextButton(
                onPressed: onForgot,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Забыли пароль?',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
              validator: (v) => v != null && v.length >= 6
                  ? null
                  : 'Пароль не короче 6 символов',
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => onRememberToggle(!rememberMe),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    _Checkbox(checked: rememberMe, onTap: () => onRememberToggle(!rememberMe)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Запомнить логин и пароль на этом устройстве',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.darkTextSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            _PrimaryGradientButton(
              onPressed: isLoading ? null : onLogin,
              isLoading: isLoading,
              icon: Icons.arrow_forward_rounded,
              label: 'Войти в систему',
            ),
            if (showSetupCallout) ...[
              const SizedBox(height: 24),
              _SetupCallout(onSetup: onSetup),
            ],
            const SizedBox(height: 18),
            Center(
              child: Text(
                'Войдя, вы соглашаетесь с политикой использования и фиксируете сессию в журнале аудита.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: AppColors.darkTextDisabled,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupCallout extends StatelessWidget {
  const _SetupCallout({required this.onSetup});
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.warning.withValues(alpha: 0.12),
            AppColors.warning.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.rocket_launch_rounded,
                size: 15, color: AppColors.warning),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Первый запуск системы?',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Создайте учётную запись владельца (Creator). '
                  'Этот аккаунт получит полный контроль над системой.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: AppColors.darkTextSecondary,
                  ),
                ),
                const SizedBox(height: 9),
                OutlinedButton.icon(
                  onPressed: onSetup,
                  icon: const Icon(Icons.shield_outlined,
                      size: 14, color: AppColors.warning),
                  label: Text(
                    'Настроить систему',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.warning,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    backgroundColor:
                        AppColors.warning.withValues(alpha: 0.10),
                    side: BorderSide(
                        color: AppColors.warning.withValues(alpha: 0.30)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

// ─── Reusable primitives ───────────────────────────────────────

class _AuthField extends StatelessWidget {
  const _AuthField({
    required this.label,
    required this.icon,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmit,
    this.autofillHints,
    this.suffix,
    this.trailingAction,
    this.validator,
  });

  final String label;
  final IconData icon;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmit;
  final Iterable<String>? autofillHints;
  final Widget? suffix;
  final Widget? trailingAction;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: AppColors.darkTextTertiary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.darkTextTertiary,
                ),
              ),
            ),
            ?trailingAction,
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onFieldSubmitted: onSubmit,
          autofillHints: autofillHints,
          validator: validator,
          style: GoogleFonts.inter(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: AppColors.darkTextPrimary,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w400,
              color: AppColors.darkTextDisabled,
            ),
            filled: true,
            fillColor: AppColors.darkSurface,
            isDense: true,
            contentPadding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            suffixIcon: suffix,
            suffixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 36),
            border: _border(AppColors.darkBorder),
            enabledBorder: _border(AppColors.darkBorder),
            focusedBorder: _border(AppColors.primary, width: 1.5),
            errorBorder: _border(AppColors.error),
            focusedErrorBorder: _border(AppColors.error, width: 1.5),
            errorStyle: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color, width: width),
      );
}

class _PrimaryGradientButton extends StatelessWidget {
  const _PrimaryGradientButton({
    required this.onPressed,
    required this.label,
    required this.icon,
    this.isLoading = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: enabled
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.primary, Color(0xFF00A3FF)],
                  )
                : null,
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
              child: isLoading
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
                        Icon(icon,
                            size: 16,
                            color: enabled
                                ? AppColors.darkBg
                                : AppColors.darkTextTertiary),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: GoogleFonts.inter(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: enabled
                                ? AppColors.darkBg
                                : AppColors.darkTextTertiary,
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

class _ChipPill extends StatelessWidget {
  const _ChipPill({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.bg,
    required this.borderColor,
    required this.textColor,
    this.pulseDot = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final Color bg;
  final Color borderColor;
  final Color textColor;
  final bool pulseDot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: pulseDot ? 12 : 11, vertical: pulseDot ? 5 : 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulseDot)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                color: iconColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: iconColor.withValues(alpha: 0.7),
                    blurRadius: 10,
                  ),
                ],
              ),
            )
          else ...[
            Icon(icon, size: 12, color: iconColor),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: pulseDot ? 11 : 11.5,
              fontWeight: pulseDot ? FontWeight.w700 : FontWeight.w600,
              letterSpacing: pulseDot ? 0.6 : 0,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked, required this.onTap});
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: checked ? AppColors.primary : AppColors.darkSurface,
          border: Border.all(
            color: checked ? AppColors.primary : AppColors.darkBorder,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(5),
        ),
        child: checked
            ? const Icon(Icons.check_rounded, size: 12, color: AppColors.darkBg)
            : null,
      ),
    );
  }
}

// _Glow removed: ambient свечения убраны при переводе экрана в более
// строгий «банковский» стиль.
