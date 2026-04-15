import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/theme/glassmorphism.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/auth/widgets/auth_text_field.dart';
import 'package:ethnocount/presentation/common/animations/fade_slide.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart';

/// Initial system setup page — creates the first Creator account.
/// Only accessible when no users exist in Firestore.
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _onSetup() {
    if (!_formKey.currentState!.validate()) return;

    context.read<AuthBloc>().add(
          AuthSignUpRequested(
            _emailCtrl.text.trim(),
            _passwordCtrl.text,
            _nameCtrl.text.trim(),
            asCreator: true,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state.status == AuthStatus.error) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.errorMessage ?? 'Ошибка создания'),
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
              Positioned(
                top: -100,
                left: -100,
                child: Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -80,
                right: -80,
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.tertiary.withValues(alpha: 0.15),
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
                            const EthnoLogo(height: 64),
                            const SizedBox(height: AppSpacing.lg),
                            Text(
                              'Настройка системы',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'Создайте учётную запись владельца (Creator).\n'
                              'Этот аккаунт будет иметь полный контроль над системой.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.xxl),

                            GlassContainer(
                              padding: const EdgeInsets.all(AppSpacing.xl),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Role badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.shield_rounded,
                                            size: 16, color: AppColors.primary),
                                        SizedBox(width: 6),
                                        Text(
                                          'Creator — Полный доступ',
                                          style: TextStyle(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.lg),

                                  AuthTextField(
                                    controller: _nameCtrl,
                                    label: 'Полное имя',
                                    icon: Icons.person_outline_rounded,
                                    validator: (v) => v != null && v.trim().length >= 2
                                        ? null
                                        : 'Введите имя (мин. 2 символа)',
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  AuthTextField(
                                    controller: _emailCtrl,
                                    label: 'Email',
                                    icon: Icons.email_outlined,
                                    keyboardType: TextInputType.emailAddress,
                                    validator: (v) => v != null && v.contains('@')
                                        ? null
                                        : 'Введите корректный email',
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  AuthTextField(
                                    controller: _passwordCtrl,
                                    label: 'Пароль',
                                    icon: Icons.lock_outline_rounded,
                                    isPassword: true,
                                    validator: (v) => v != null && v.length >= 6
                                        ? null
                                        : 'Минимум 6 символов',
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  AuthTextField(
                                    controller: _confirmCtrl,
                                    label: 'Подтверждение пароля',
                                    icon: Icons.lock_outline_rounded,
                                    isPassword: true,
                                    textInputAction: TextInputAction.done,
                                    validator: (v) =>
                                        v == _passwordCtrl.text
                                            ? null
                                            : 'Пароли не совпадают',
                                  ),
                                  const SizedBox(height: AppSpacing.xl),

                                  FilledButton.icon(
                                    onPressed: isLoading ? null : _onSetup,
                                    icon: isLoading
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(Icons.check_rounded),
                                    label: const Text(
                                      'Создать аккаунт Creator',
                                      style: TextStyle(fontSize: 16),
                                    ),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: AppSpacing.md,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            TextButton(
                              onPressed: () => context.go('/login'),
                              child: const Text('Уже есть аккаунт? Войти'),
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
