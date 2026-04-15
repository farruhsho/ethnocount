import 'package:connectivity_plus/connectivity_plus.dart';

/// Service to monitor network connectivity.
class ConnectivityService {
  final Connectivity _connectivity = Connectivity();

  /// Check current connectivity status.
  Future<bool> get isConnected async {
    final result = await _connectivity.checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Stream of connectivity changes.
  Stream<bool> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged.map(
      (results) => !results.contains(ConnectivityResult.none),
    );
  }
}
