import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Звук + вибрация при появлении нового in-app уведомления.
///
/// Используем встроенные Flutter API, чтобы не тащить лишних пакетов:
///   • `SystemSound.play(SystemSoundType.alert)` — короткий системный сигнал
///     уведомления (на iOS — стандартный alert, на Android — короткий beep).
///   • `HapticFeedback.heavyImpact()` — сильная тактильная отдача
///     (на телефонах с моторчиком — ощутимая вибрация).
///
/// Никакой инициализации не требуется, ничего не блокирует UI.
class NotificationFxService {
  /// Чтобы не "стрелять" одно и то же на каждое перерисовывание стрима.
  /// Стрим присылает полный список — мы запоминаем id уже виденных и
  /// "тригерим" эффект только на новые непрочитанные.
  final Set<String> _seenIds = <String>{};
  bool _primed = false;

  /// Регистрирует id текущих уведомлений как уже виденные, **без** воспроизведения
  /// эффектов. Вызывается на самой первой загрузке после логина — иначе
  /// пользователь получил бы вибрацию на каждое старое непрочитанное.
  void prime(Iterable<String> ids) {
    _seenIds
      ..clear()
      ..addAll(ids);
    _primed = true;
  }

  /// Сравнивает свежий список уведомлений с предыдущим состоянием. Если
  /// появились новые непрочитанные — играет звук и вибрирует.
  ///
  /// [unreadIds] — id всех непрочитанных уведомлений сейчас.
  /// Возвращает `true`, если эффект сработал.
  bool checkAndPlay(Iterable<String> unreadIds) {
    final list = unreadIds.toList();
    if (!_primed) {
      // Первый вызов после логина → запоминаем "стартовое" состояние молча.
      prime(list);
      return false;
    }
    final fresh = list.where((id) => !_seenIds.contains(id)).toList();
    _seenIds.addAll(list);
    if (fresh.isEmpty) return false;
    _playFx();
    return true;
  }

  /// Сбрасывает состояние (например, при смене пользователя).
  void reset() {
    _seenIds.clear();
    _primed = false;
  }

  void _playFx() {
    // Намеренно fire-and-forget — UI не должен ждать звука.
    try {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('NotificationFxService: эффект не сработал — $e');
      }
    }
  }
}
