import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/presentation/common/widgets/ethno_logo.dart';

/// Первый экран: текстовый wordmark «Финансы».
///
/// Навигация после авторизации отрабатывает в GoRouter redirect'ах,
/// поэтому даже если процесс восстановлен с этого экрана, пользователь
/// не залипает здесь.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _entranceController, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
    );
    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMobile = context.isMobile;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(
                scheme.surfaceContainerLowest,
                scheme.primaryContainer.withValues(alpha: 0.35),
                0.22,
              )!,
              Color.lerp(
                scheme.surface,
                scheme.tertiaryContainer.withValues(alpha: 0.25),
                0.18,
              )!,
            ],
          ),
        ),
        child: AnimatedBuilder(
          animation: _entranceController,
          builder: (context, child) {
            return Stack(
              fit: StackFit.expand,
              children: [
                if (isMobile)
                  Positioned(
                    top: context.screenHeight * 0.18,
                    left: context.screenWidth * 0.08,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: _fade.value * 0.35,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                AppColors.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Opacity(
                      opacity: _fade.value,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BrandWordmark(height: isMobile ? 56 : 64),
                          SizedBox(
                            height: isMobile ? AppSpacing.lg : AppSpacing.md,
                          ),
                          const SizedBox(
                            width: 28,
                            height: 2.5,
                            child: LinearProgressIndicator(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
