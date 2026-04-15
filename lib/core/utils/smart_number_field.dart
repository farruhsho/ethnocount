import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [TextFormField] for monetary/numeric values that auto-clears the initial
/// "0" or "0.0" placeholder when the user starts typing.
class SmartNumberField extends StatefulWidget {
  const SmartNumberField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.suffix,
    this.prefix,
    this.initialValue = '0',
    this.allowDecimal = true,
    this.validator,
    this.onChanged,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final Widget? suffix;
  final Widget? prefix;
  final String initialValue;
  final bool allowDecimal;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool autofocus;

  @override
  State<SmartNumberField> createState() => _SmartNumberFieldState();
}

class _SmartNumberFieldState extends State<SmartNumberField> {
  late TextEditingController _ctrl;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _ctrl = widget.controller!;
    } else {
      _ctrl = TextEditingController(text: widget.initialValue);
      _ownsController = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _ctrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    final text = _ctrl.text.trim();
    if (text == '0' || text == '0.0' || text == '0.00') {
      _ctrl.clear();
    }
  }

  void _handleFocusLost() {
    if (_ctrl.text.trim().isEmpty) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (hasFocus) {
        if (!hasFocus) _handleFocusLost();
      },
      child: TextFormField(
        controller: _ctrl,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.allowDecimal,
        ),
        inputFormatters: [
          if (widget.allowDecimal)
            FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))
          else
            FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          suffixIcon: widget.suffix,
          prefixIcon: widget.prefix,
        ),
        validator: widget.validator,
        onChanged: widget.onChanged,
        onTap: _handleTap,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
      ),
    );
  }
}
