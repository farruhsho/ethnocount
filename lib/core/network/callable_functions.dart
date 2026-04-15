/// Legacy CallableFunctions wrapper — kept as a minimal shell for any code
/// that still references CallableFunctionsException.
/// All RPC calls now go directly through SupabaseClient.rpc().

class CallableFunctionsException implements Exception {
  final String code;
  final String message;

  CallableFunctionsException(this.code, this.message);

  @override
  String toString() => 'CallableFunctionsException($code): $message';
}
