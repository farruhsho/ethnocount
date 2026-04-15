import 'package:flutter/material.dart';

/// Detects country from phone number prefix and provides flag display.
class PhoneCountryDetector {
  PhoneCountryDetector._();

  static const _prefixes = <String, _CountryInfo>{
    '+9989': _CountryInfo('Узбекистан', 'UZ', Color(0xFF1EB53A)),
    '+998': _CountryInfo('Узбекистан', 'UZ', Color(0xFF1EB53A)),
    '+996': _CountryInfo('Кыргызстан', 'KG', Color(0xFFE8112D)),
    '+992': _CountryInfo('Таджикистан', 'TJ', Color(0xFF006600)),
    '+971': _CountryInfo('ОАЭ', 'AE', Color(0xFF00732F)),
    '+90': _CountryInfo('Турция', 'TR', Color(0xFFE30A17)),
    '+86': _CountryInfo('Китай', 'CN', Color(0xFFDE2910)),
    '+77': _CountryInfo('Казахстан', 'KZ', Color(0xFF00AFCA)),
    '+7': _CountryInfo('Россия', 'RU', Color(0xFF0039A6)),
  };

  /// Detect country from raw phone string. Returns null if not matched.
  static CountryMatch? detect(String phone) {
    final cleaned = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (cleaned.isEmpty || !cleaned.startsWith('+')) return null;

    // Longest prefix first for correct matching (+77 before +7, etc.)
    for (final entry in _prefixes.entries) {
      if (cleaned.startsWith(entry.key)) {
        return CountryMatch(
          countryName: entry.value.name,
          countryCode: entry.value.code,
          brandColor: entry.value.color,
        );
      }
    }
    return null;
  }

  /// All supported prefix → country code pairs (for hint text).
  static const supportedPrefixes = <String, String>{
    '+7': 'RU / KZ',
    '+998': 'UZ',
    '+90': 'TR',
    '+971': 'AE',
    '+86': 'CN',
    '+996': 'KG',
    '+992': 'TJ',
  };
}

class _CountryInfo {
  final String name;
  final String code;
  final Color color;
  const _CountryInfo(this.name, this.code, this.color);
}

/// Result of a successful phone prefix match.
class CountryMatch {
  final String countryName;
  final String countryCode;
  final Color brandColor;
  const CountryMatch({
    required this.countryName,
    required this.countryCode,
    required this.brandColor,
  });
}

/// Small circular badge showing 2-letter country code as a flag substitute.
/// Works correctly on all platforms (including Windows where emoji flags fail).
class CountryBadge extends StatelessWidget {
  const CountryBadge({super.key, required this.match, this.size = 28});

  final CountryMatch match;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: match.brandColor,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        match.countryCode,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
