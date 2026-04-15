import 'package:flutter/services.dart';

/// Flattens input to remove leading zero when another natural number is typed over it.
/// e.g. input is '0'. User types '5'. Text becomes '5' instead of '05'.
class RemoveLeadingZeroFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // If the old value was precisely '0' and the new value is '0X', return 'X'
    if (oldValue.text == '0' && newValue.text.length == 2 && newValue.text.startsWith('0')) {
      final newChar = newValue.text[1];
      if (newChar == '.' || newChar == ',') return newValue; // allow "0." or "0,"
      
      return TextEditingValue(
        text: newChar,
        selection: const TextSelection.collapsed(offset: 1),
      );
    }
    
    // If we type into an empty field that was starting with '00', revert etc
    if (newValue.text.startsWith('0') && newValue.text.length > 1) {
      if (newValue.text[1] != '.' && newValue.text[1] != ',') {
         // remove the leading zero
         final fixedText = newValue.text.replaceFirst(RegExp(r'^0+'), '');
         if (fixedText.isEmpty) {
           return const TextEditingValue(
             text: '0',
             selection: TextSelection.collapsed(offset: 1),
           );
         }
         return TextEditingValue(
            text: fixedText,
            selection: TextSelection.collapsed(offset: fixedText.length),
         );
      }
    }
    
    return newValue;
  }
}
