import 'package:intl/intl.dart';

/// Extensions on DateTime for display formatting.
extension DateX on DateTime {
  /// "Mar 4, 2026"
  String get formatted => DateFormat.yMMMd().format(this);

  /// "Mar 4"
  String get shortFormatted => DateFormat.MMMd().format(this);

  /// "14:30"
  String get time => DateFormat.Hm().format(this);

  /// "Mar 4, 2026 14:30"
  String get fullFormatted => DateFormat.yMMMd().add_Hm().format(this);

  /// "04.03.2026 14:30" — дата и время для истории (покупки, переводы, проводки).
  String get historyFormatted => DateFormat('dd.MM.yyyy HH:mm').format(this);

  /// "Today", "Yesterday", or formatted date
  String get relative {
    final now = DateTime.now();
    final diff = now.difference(this);
    if (diff.inDays == 0 && day == now.day) return 'Today';
    if (diff.inDays == 1 || (diff.inDays == 0 && day != now.day)) {
      return 'Yesterday';
    }
    if (diff.inDays < 7) return DateFormat.EEEE().format(this);
    return formatted;
  }

  /// Start of day
  DateTime get startOfDay => DateTime(year, month, day);

  /// End of day
  DateTime get endOfDay => DateTime(year, month, day, 23, 59, 59, 999);

  /// Start of month
  DateTime get startOfMonth => DateTime(year, month, 1);

  /// End of month
  DateTime get endOfMonth => DateTime(year, month + 1, 0, 23, 59, 59, 999);

  /// Is same day
  bool isSameDay(DateTime other) =>
      year == other.year && month == other.month && day == other.day;
}
