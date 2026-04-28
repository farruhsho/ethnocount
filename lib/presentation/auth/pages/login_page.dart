import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/services/credential_storage_service.dart';
import 'package:ethnocount/core/theme/glassmorphism.dart';
import 'package:ethnocount/domain/repositories/auth_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/auth/widgets/auth_text_field.dart';
import 'package:ethnocount/presentation/common/animations/fade_slide.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool? _systemInitialized;
  bool _rememberMe = false;

  @override
  void initState() {
    super.initState();
    _checkSystemInit();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final creds = await sl<CredentialStorageService>().loadCredentials();
      if (mounted) {
        setState(() {
          _rememberMe = creds.rememberMe;
          if (creds.email != null) {
            _emailController.text = creds.email!;
            _passwordController.text = creds.password ?? '';
          }
        });
      }
    } catch (_) {}
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
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onLogin() {
    if (_formKey.currentState!.validate()) {
      context.read<AuthBloc>().add(
            AuthSignInRequested(
              _emailController.text.trim(),
              _passwordController.text,
              rememberMe: _rememberMe,
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state.status == AuthStatus.error) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.errorMessage ?? 'Authentication failed'),
                backgroundColor: AppColors.error,
              ),
            );
          } else if (state.status == AuthStatus.authenticated) {
            context.go('/');
          }
        },
        builder: (context, state) {
          final isLoading = state.status == AuthStatus.loading;

          return Stack(
            children: [
              // Abstract background gradient
              Positioned(
                top: -100,
                right: -100,
                child: Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    gradient: RadialGradient(
                      colors: [
                        Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -50,
                left: -50,
                child: Container(
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15),
                    gradient: RadialGradient(
                      colors: [
                        Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: FadeSlideTransition(
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Logo area
                            const EthnoLogo(height: 72),
                            const SizedBox(height: AppSpacing.lg),
                            Text(
                              'Вход в систему',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'Внутренняя казначейская платформа Ethno Logistics',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.xxl),

                            // Glass form
                            GlassContainer(
                              padding: const EdgeInsets.all(AppSpacing.xl),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  AuthTextField(
                                    controller: _emailController,
                                    label: 'Email',
                                    icon: Icons.email_outlined,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    validator: (val) => val != null && val.contains('@')
                                        ? null
                                        : 'Enter a valid email',
                                  ),
                                  const SizedBox(height: AppSpacing.lg),
                                  AuthTextField(
                                    controller: _passwordController,
                                    label: 'Password',
                                    icon: Icons.lock_outline_rounded,
                                    isPassword: true,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _onLogin(),
                                    validator: (val) => val != null && val.length >= 6
                                        ? null
                                        : 'Password must be at least 6 characters',
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  CheckboxListTile(
                                    value: _rememberMe,
                                    onChanged: (v) async {
                                      final val = v ?? false;
                                      setState(() => _rememberMe = val);
                                      await sl<CredentialStorageService>()
                                          .saveRememberMePreference(val);
                                    },
                                    title: const Text('Запомнить логин и пароль'),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () => context.push('/forgot-password'),
                                      child: const Text('Забыли пароль?'),
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.lg),
                                  FilledButton(
                                    onPressed: isLoading ? null : _onLogin,
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: AppSpacing.md,
                                      ),
                                    ),
                                    child: isLoading
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text(
                                            'Войти',
                                            style: TextStyle(fontSize: 16),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),
                            if (_systemInitialized == false) ...[
                              OutlinedButton.icon(
                                onPressed: () => context.go('/register'),
                                icon: const Icon(Icons.rocket_launch_rounded),
                                label: const Text('Первый запуск — Настроить систему'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            Text(
                              _systemInitialized == false
                                  ? 'Система не настроена. Создайте аккаунт Creator для начала работы.'
                                  : 'Доступ предоставляется администратором компании.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            TextButton.icon(
                              onPressed: () => context.go('/register'),
                              icon: const Icon(Icons.admin_panel_settings_outlined),
                              label: const Text('Временная кнопка регистрации (Creator)'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
