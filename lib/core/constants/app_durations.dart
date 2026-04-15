/// Animation duration tokens for consistent timing.
class AppDurations {
  AppDurations._();

  /// 100ms — Micro-interactions (ripples, opacity)
  static const Duration instant = Duration(milliseconds: 100);

  /// 200ms — Quick state changes (toggles, selection)
  static const Duration fast = Duration(milliseconds: 200);

  /// 300ms — Standard animations (page transitions, modals)
  static const Duration normal = Duration(milliseconds: 300);

  /// 400ms — Emphasized animations (expand/collapse)
  static const Duration slow = Duration(milliseconds: 400);

  /// 600ms — Dramatic animations (onboarding, hero numbers)
  static const Duration dramatic = Duration(milliseconds: 600);

  /// 1000ms — Stagger base (list item entrance)
  static const Duration stagger = Duration(milliseconds: 1000);

  /// 50ms — Stagger delay between list items
  static const Duration staggerInterval = Duration(milliseconds: 50);
}
