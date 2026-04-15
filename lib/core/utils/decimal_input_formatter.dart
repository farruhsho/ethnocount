import 'package:flutter/services.dart';

/// Allows only digits and at most one decimal point (e.g. for amount, commission, rate).
class DecimalInputFormatter extends TextInputFormatter {
  static final _regex = RegExp(r'^\d*\.?\d*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    return _regex.hasMatch(newValue.text) ? newValue : oldValue;
  }
}
