import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ethnocount/core/constants/app_colors.dart';

/// Ethno brand logo ([assets/icons/ethno.svg]).
///
/// On light UI (white + deep navy text) uses brand [AppColors.primary] so the
/// mark is distinct from body copy. On dark UI uses the same accent for consistency.
class EthnoLogo extends StatelessWidget {
  const EthnoLogo({super.key, this.height});

  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.brightness == Brightness.light
        ? AppColors.primary
        : AppColors.primaryLight;
    return SvgPicture.asset(
      'assets/icons/ethno.svg',
      height: height,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
