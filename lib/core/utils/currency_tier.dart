/// Tier-based котировки валют: «1 strong = X weak».
///
/// Пара выбирается так: при сравнении двух валют меньший номер tier =
/// «сильнее» (она становится базой котировки). Пример:
///   • UZS → RUB: tier(UZS)=50, tier(RUB)=40 → база RUB, «1 RUB = X UZS»
///   • USD → UZS: «1 USD = X UZS»
///   • USDT → USD: одинаковый tier 20 → пара не определена (1:1)
///
/// Оператор всегда вводит число «сколько слабой валюты за 1 сильной» —
/// программа сама пересчитывает в нужном направлении. Это избавляет от
/// классической ошибки «забыл, в какую сторону курс».
///
/// Используется в:
///   • create_transfer_page.dart (форма создания обычного перевода)
///   • partner_transfer_dialog.dart (создание партнёрского перевода)
class CurrencyTier {
  CurrencyTier._();

  static const Map<String, int> _tier = <String, int>{
    'EUR': 10, 'GBP': 11,
    'USD': 20, 'USDT': 21,
    'CNY': 30, 'TRY': 31, 'AED': 32,
    'RUB': 40, 'KZT': 41,
    'UZS': 50, 'KGS': 51, 'TJS': 52,
  };

  /// Пара (strong, weak) для котировки `1 strong = X weak`. `null`, если
  /// пара не определена (одинаковый tier, неизвестная валюта или from==to).
  static (String, String)? quotePair(String from, String to) {
    if (from == to) return null;
    final f = _tier[from];
    final t = _tier[to];
    if (f == null || t == null) return null;
    if (f == t) return null;
    return f < t ? (from, to) : (to, from);
  }

  /// Если оператор ввёл `input` как «1 strong = input weak», возвращает
  /// настоящий множитель для пересчёта `from → to`. Если from — слабая
  /// сторона, возвращается `1 / input`.
  static double multiplierFromInput(double input, String from, String to) {
    if (from == to) return 1;
    final pair = quotePair(from, to);
    if (pair == null) return input;
    final (strong, _) = pair;
    return from == strong ? input : (input == 0 ? 0 : 1 / input);
  }

  /// Текст для labelText поля курса: «1 USD = ? UZS».
  static String rateLabel(String from, String to) {
    if (from == to) return 'Курс';
    final pair = quotePair(from, to);
    if (pair == null) return 'Курс $from → $to';
    final (strong, weak) = pair;
    return '1 $strong = ? $weak';
  }
}
