import 'package:uuid/uuid.dart';

/// UUID generator for idempotency keys and document IDs.
class IdGenerator {
  static const _uuid = Uuid();

  /// Generate a v4 UUID string.
  static String v4() => _uuid.v4();
}
