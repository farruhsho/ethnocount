/// Лёгкая модель счёта филиала для дропдаунов в диалогах партнёров.
/// Хранит только то, что нужно показать в списке и передать в RPC.
class AccountOption {
  AccountOption({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.name,
    required this.currency,
    required this.type,
  });

  factory AccountOption.empty() => AccountOption(
        id: '',
        branchId: '',
        branchName: '',
        name: '',
        currency: '',
        type: '',
      );

  factory AccountOption.fromMap(Map<String, dynamic> m) {
    final branch = m['branches'];
    final branchName = branch is Map ? (branch['name'] ?? '').toString() : '';
    return AccountOption(
      id: m['id'].toString(),
      branchId: (m['branch_id'] ?? '').toString(),
      branchName: branchName,
      name: (m['name'] ?? '').toString(),
      currency: (m['currency'] ?? '').toString(),
      type: (m['type'] ?? '').toString(),
    );
  }

  final String id;
  final String branchId;
  final String branchName;
  final String name;
  final String currency;
  final String type;

  String get displayLabel {
    // Валюта в начале — облегчает визуальное группирование когда в
    // дропдауне много счетов из одного филиала разных валют (раньше
    // суффикс «(USD)» терялся в конце длинной строки).
    final cur = currency.toUpperCase();
    final parts = <String>[
      if (branchName.isNotEmpty) branchName,
      name,
    ];
    return '[$cur] ${parts.join(' · ')}';
  }
}
