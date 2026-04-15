import 'package:flutter/services.dart';

/// Max digits for E.164 international phone numbers.
const int kPhoneMaxDigits = 15;

/// Max length of formatted phone string (+ and spaces).
const int kPhoneMaxFormattedLength = 20;

/// Returns digit indices after which to insert a space.
/// Russia +7: +7 XXX XXX XX XX → spaces after 1, 4, 7, 9
/// Uzbekistan +998: +998 XX XXX XX XX → spaces after 3, 5, 8, 10
/// Default: +XXX XXX XX XX XX → spaces after 3, 6, 8, 10
Set<int> _getSpacePositions(String digits) {
  if (digits.startsWith('7') && digits.length >= 2) {
    // Russia, Kazakhstan: +7 920 988 38 76
    return {1, 4, 7, 9};
  }
  if (digits.startsWith('998')) {
    // Uzbekistan: +998 90 123 45 67
    return {3, 5, 8, 10};
  }
  if (digits.startsWith('90') && digits.length >= 3) {
    // Turkey: +90 532 123 45 67
    return {2, 5, 8, 10};
  }
  if (digits.startsWith('971')) {
    // UAE: +971 50 123 45 67
    return {3, 5, 8, 10};
  }
  if (digits.startsWith('86')) {
    // China: +86 138 1234 5678
    return {2, 5, 9};
  }
  if (digits.startsWith('996') || digits.startsWith('992')) {
    // KG, TJ: +996 XXX XXX XXX
    return {3, 6, 9};
  }
  // Default: +XXX XXX XX XX XX
  return {3, 6, 8, 10};
}

/// Formats phone input with automatic spaces.
/// Russia/KZ +7: +7 XXX XXX XX XX
/// Uzbekistan +998: +998 XX XXX XX XX
/// Turkey +90, UAE +971, etc: +XXX XXX XXX XX XX
/// Limits to 15 digits (E.164 standard).
class PhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;

    final digits = text.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return const TextEditingValue();

    // Limit to E.164 max (15 digits)
    final limited = digits.length > kPhoneMaxDigits
        ? digits.substring(0, kPhoneMaxDigits)
        : digits;

    // Country-aware spacing
    final buffer = StringBuffer('+');
    final spacePositions = _getSpacePositions(limited);
    for (var i = 0; i < limited.length; i++) {
      if (spacePositions.contains(i)) buffer.write(' ');
      buffer.write(limited[i]);
    }
    final formatted = buffer.toString();

    // Preserve cursor by digit count: place cursor after same number of digits
    final oldCursor = newValue.selection.baseOffset.clamp(0, newValue.text.length);
    final digitsBeforeCursor = newValue.text
        .substring(0, oldCursor)
        .replaceAll(RegExp(r'[^\d]'), '')
        .length;

    int cursor = 0;
    int digitCount = 0;
    for (var i = 0; i < formatted.length; i++) {
      if (RegExp(r'\d').hasMatch(formatted[i])) {
        digitCount++;
        if (digitCount >= digitsBeforeCursor) {
          cursor = i + 1;
          break;
        }
      }
    }
    if (digitCount < digitsBeforeCursor) cursor = formatted.length;
    cursor = cursor.clamp(0, formatted.length);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}
