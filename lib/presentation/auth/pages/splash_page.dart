import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';

/// First screen: branded splash with [assets/icons/ethno.svg].
///
/// Navigation after auth is handled by GoRouter redirects (refresh when auth
/// state changes) so process restore does not leave the user stuck here.
/// SVG is precached in [main].
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<double> _logoFade;
  late final Animation<double> _logoScale;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _logoFade = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _logoScale = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Curves.easeOutCubic,
      ),
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
                        opacity: _logoFade.value * 0.35,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Transform.scale(
                        scale: _logoScale.value,
                        child: Opacity(
                          opacity: _logoFade.value,
                          child: SvgPicture.asset(
                            'assets/icons/ethno.svg',
                            height: isMobile ? 72 : 64,
                            colorFilter: ColorFilter.mode(
                              scheme.brightness == Brightness.light
                                  ? AppColors.primary
                                  : AppColors.primaryLight,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: isMobile ? AppSpacing.xl : AppSpacing.lg,
                      ),
                    ],
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
