import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/theme/glassmorphism.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/auth/widgets/auth_text_field.dart';
import 'package:ethnocount/presentation/common/animations/fade_slide.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _emailSent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _onReset() {
    if (_formKey.currentState!.validate()) {
      context.read<AuthBloc>().add(
            AuthResetPasswordRequested(_emailController.text.trim()),
          );
      setState(() {
        _emailSent = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background
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
                    Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.2),
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
                        const EthnoLogo(height: 72),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          'Reset Password',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _emailSent
                              ? 'Check your email for instructions'
                              : 'Enter your email to receive a reset link',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.xxl),

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
                                validator: (val) => val != null && val.contains('@')
                                    ? null
                                    : 'Enter a valid email',
                              ),
                              const SizedBox(height: AppSpacing.xl),
                              FilledButton(
                                onPressed: _emailSent ? null : _onReset,
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: AppSpacing.md,
                                  ),
                                ),
                                child: Text(
                                  _emailSent ? 'Link Sent' : 'Send Reset Link',
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: AppSpacing.xl),
                        TextButton(
                          onPressed: () => context.go('/login'),
                          child: const Text('Back to Sign In'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.md,
            left: AppSpacing.md,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/login'),
            ),
          ),
        ],
      ),
    );
  }
}
