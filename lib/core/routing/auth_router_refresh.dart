import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

/// Drives [GoRouter.redirect] whenever [AuthBloc] emits so splash/login resolve
/// after auth, even when the OS recreates the activity.
final class AuthGoRouterRefresh extends ChangeNotifier {
  AuthGoRouterRefresh(this._bloc) {
    _sub = _bloc.stream.listen((_) => notifyListeners());
  }

  final AuthBloc _bloc;
  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}
