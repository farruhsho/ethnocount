import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_durations.dart';

/// Fade + slide entrance animation for page content.
class FadeSlideTransition extends StatefulWidget {
  const FadeSlideTransition({
    super.key,
    required this.child,
    this.offset = const Offset(0, 20),
    this.delay = Duration.zero,
    this.duration,
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final Offset offset;
  final Duration delay;
  final Duration? duration;
  final Curve curve;

  @override
  State<FadeSlideTransition> createState() => _FadeSlideTransitionState();
}

class _FadeSlideTransitionState extends State<FadeSlideTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration ?? AppDurations.normal,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    );
    _slideAnimation = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ));

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: AnimatedBuilder(
        animation: _slideAnimation,
        builder: (context, child) {
          return Transform.translate(
            offset: _slideAnimation.value,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Staggered list animation — each child animates in with a delay.
class StaggeredList extends StatelessWidget {
  const StaggeredList({
    super.key,
    required this.children,
    this.staggerDelay = const Duration(milliseconds: 50),
  });

  final List<Widget> children;
  final Duration staggerDelay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(children.length, (index) {
        return FadeSlideTransition(
          delay: staggerDelay * index,
          child: children[index],
        );
      }),
    );
  }
}
