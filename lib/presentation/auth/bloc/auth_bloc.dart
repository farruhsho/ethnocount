import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/core/services/credential_storage_service.dart';
import 'package:ethnocount/core/services/session_service.dart';
import 'package:ethnocount/data/datasources/remote/system_settings_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_session_remote_ds.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/auth_repository.dart';
import 'package:ethnocount/domain/usecases/auth/sign_in.dart';

// ─── Events ───

abstract class AuthEvent extends Equatable {
  const AuthEvent();
  @override
  List<Object?> get props => [];
}

class AuthCheckRequested extends AuthEvent {
  const AuthCheckRequested();
}

class AuthSignInRequested extends AuthEvent {
  final String email;
  final String password;
  final bool rememberMe;
  const AuthSignInRequested(this.email, this.password, {this.rememberMe = false});
  @override
  List<Object?> get props => [email, password, rememberMe];
}

class AuthSignUpRequested extends AuthEvent {
  final String email;
  final String password;
  final String displayName;
  final bool asCreator;
  const AuthSignUpRequested(this.email, this.password, this.displayName, {this.asCreator = false});
  @override
  List<Object?> get props => [email, password, displayName, asCreator];
}

class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

class AuthSignOutAllDevicesRequested extends AuthEvent {
  const AuthSignOutAllDevicesRequested();
}

/// Internal event fired by the Supabase auth-state stream (token refresh,
/// server-side sign-out, profile reload).
class _AuthUserStreamUpdated extends AuthEvent {
  final AppUser? user;
  const _AuthUserStreamUpdated(this.user);
  @override
  List<Object?> get props => [user];
}

class AuthResetPasswordRequested extends AuthEvent {
  final String email;
  const AuthResetPasswordRequested(this.email);
  @override
  List<Object?> get props => [email];
}

// ─── State ───

enum AuthStatus { initial, loading, authenticated, unauthenticated, error }

class AuthState extends Equatable {
  final AuthStatus status;
  final AppUser? user;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.errorMessage,
  });

  const AuthState.initial() : this();

  AuthState copyWith({
    AuthStatus? status,
    AppUser? user,
    bool clearUser = false,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: clearUser ? null : (user ?? this.user),
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, user, errorMessage];
}

// ─── BLoC ───

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final SignInUseCase _signIn;
  final SignUpUseCase _signUp;
  final SignOutUseCase _signOut;
  final AuthRepository _authRepository;
  final CredentialStorageService _credentialStorage;
  final SessionService _sessionService;
  final SystemSettingsRemoteDataSource _systemSettingsDs;
  final UserSessionRemoteDataSource _userSessionDs;

  StreamSubscription<AppUser?>? _authStreamSub;
  DateTime? _lastCheckAt;

  AuthBloc({
    required SignInUseCase signIn,
    required SignUpUseCase signUp,
    required SignOutUseCase signOut,
    required AuthRepository authRepository,
    required CredentialStorageService credentialStorage,
    required SessionService sessionService,
    required SystemSettingsRemoteDataSource systemSettingsDs,
    required UserSessionRemoteDataSource userSessionDs,
  })  : _signIn = signIn,
        _signUp = signUp,
        _signOut = signOut,
        _authRepository = authRepository,
        _credentialStorage = credentialStorage,
        _sessionService = sessionService,
        _systemSettingsDs = systemSettingsDs,
        _userSessionDs = userSessionDs,
        super(const AuthState.initial()) {
    on<AuthCheckRequested>(_onCheckRequested);
    on<AuthSignInRequested>(_onSignIn);
    on<AuthSignUpRequested>(_onSignUp);
    on<AuthSignOutRequested>(_onSignOut);
    on<AuthSignOutAllDevicesRequested>(_onSignOutAllDevices);
    on<AuthResetPasswordRequested>(_onResetPassword);
    on<_AuthUserStreamUpdated>(_onUserStreamUpdated);

    // React to Supabase auth events: token refresh, server-side sign-out,
    // session restored from disk on cold start. The stream loads the full
    // profile from the `users` table, so the role is always authoritative.
    _authStreamSub = _authRepository.authStateChanges.listen(
      (user) => add(_AuthUserStreamUpdated(user)),
      onError: (_) {},
    );
  }

  @override
  Future<void> close() async {
    await _authStreamSub?.cancel();
    return super.close();
  }

  Future<void> _onCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    // Debounce: lifecycle resume can fire frequently. If we already verified
    // recently and the user is authenticated, skip the network round-trip.
    final now = DateTime.now();
    if (_lastCheckAt != null &&
        state.status == AuthStatus.authenticated &&
        now.difference(_lastCheckAt!).inSeconds < 30) {
      return;
    }
    _lastCheckAt = now;

    // 1) Synchronous probe of the locally persisted Supabase session.
    final cached = _authRepository.currentUser;
    if (cached == null) {
      emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
      return;
    }

    // 2) Optimistic emit so we don't flash the login screen on cold start /
    //    resume. Skip if we're mid sign-in or already authenticated.
    if (state.status != AuthStatus.authenticated || state.user == null) {
      emit(state.copyWith(status: AuthStatus.authenticated, user: cached));
    }

    // 3) Refine with the authoritative profile (real role, permissions,
    //    branches). A network failure here MUST NOT log the user out — we
    //    keep whatever user we already have.
    try {
      final profile = await _authRepository.fetchCurrentUserProfile();
      if (profile != null) {
        emit(state.copyWith(status: AuthStatus.authenticated, user: profile));
      }
    } catch (_) {
      // Keep cached/optimistic user — role refresh will happen next time
      // network is available.
    }

    // 4) Server-side revocation check. Only sign the user out on a
    //    DEFINITIVE "no" — never on a network/transport error, otherwise
    //    flaky connectivity (e.g. resuming the app on a metro) would log
    //    everyone out.
    try {
      final stillListed =
          await _userSessionDs.isOurSessionStillListed(cached.id);
      if (!stillListed) {
        await _authRepository.signOut();
        await _sessionService.clearLogin();
        emit(state.copyWith(
          status: AuthStatus.unauthenticated,
          clearUser: true,
        ));
        return;
      }
    } catch (_) {
      // Server unavailable — trust the local session for now.
    }

    // 5) Local TTL based on system setting. Only enforced on a successful
    //    settings read.
    try {
      final sessionDays = await _systemSettingsDs.getSessionDurationDays();
      final expired = await _sessionService.isSessionExpired(sessionDays);
      if (expired) {
        await _authRepository.signOut();
        await _sessionService.clearLogin();
        emit(state.copyWith(
          status: AuthStatus.unauthenticated,
          clearUser: true,
        ));
        return;
      }
    } catch (_) {/* keep user signed in */}

    // 6) Best-effort heartbeat.
    try {
      await _userSessionDs.logSession(cached.id);
    } catch (_) {}
  }

  Future<void> _onUserStreamUpdated(
    _AuthUserStreamUpdated event,
    Emitter<AuthState> emit,
  ) async {
    final user = event.user;
    if (user == null) {
      // Server-side sign-out (refresh token revoked, deleted, etc.). Only
      // honour it if we previously thought we were authenticated — never
      // override an in-flight `loading` state from `AuthSignInRequested`.
      if (state.status == AuthStatus.authenticated) {
        await _sessionService.clearLogin();
        emit(state.copyWith(
          status: AuthStatus.unauthenticated,
          clearUser: true,
        ));
      }
      return;
    }
    // Token refresh / profile reload — keep the user authenticated and
    // update the cached profile (role/permissions/branches may have
    // changed server-side).
    if (state.user != user) {
      emit(state.copyWith(status: AuthStatus.authenticated, user: user));
    } else if (state.status != AuthStatus.authenticated) {
      emit(state.copyWith(status: AuthStatus.authenticated, user: user));
    }
  }

  Future<void> _onSignIn(
    AuthSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(status: AuthStatus.loading));
    final result = await _signIn(event.email, event.password);
    await result.fold(
      (failure) async => emit(state.copyWith(
        status: AuthStatus.error,
        errorMessage: failure.message,
      )),
      (user) async {
        await _credentialStorage.saveCredentials(
          email: event.email,
          password: event.password,
          rememberMe: event.rememberMe,
        );
        await _sessionService.recordLogin();
        try {
          await _userSessionDs.logSession(user.id);
        } catch (_) {
          // Ignore: Firestore rules may not be deployed yet
        }
        emit(state.copyWith(status: AuthStatus.authenticated, user: user));
      },
    );
  }

  Future<void> _onSignUp(
    AuthSignUpRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(status: AuthStatus.loading));
    final result = await _signUp(
      email: event.email,
      password: event.password,
      displayName: event.displayName,
      asCreator: event.asCreator,
    );
    result.fold(
      (failure) => emit(state.copyWith(
        status: AuthStatus.error,
        errorMessage: failure.message,
      )),
      (user) => emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: user,
      )),
    );
  }

  Future<void> _onSignOut(
    AuthSignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    _lastCheckAt = null;
    await _signOut();
    await _sessionService.clearLogin();
    emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
  }

  Future<void> _onSignOutAllDevices(
    AuthSignOutAllDevicesRequested event,
    Emitter<AuthState> emit,
  ) async {
    _lastCheckAt = null;
    final result = await _authRepository.revokeAllSessionsAndSignOut();
    await result.fold(
      (failure) async => emit(state.copyWith(
        status: AuthStatus.error,
        errorMessage: failure.message,
      )),
      (_) async {
        await _sessionService.clearLogin();
        emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
      },
    );
  }

  Future<void> _onResetPassword(
    AuthResetPasswordRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(status: AuthStatus.loading));
    final result = await _authRepository.resetPassword(event.email);
    result.fold(
      (failure) => emit(state.copyWith(
        status: AuthStatus.error,
        errorMessage: failure.message,
      )),
      (_) => emit(state.copyWith(
        status: AuthStatus.unauthenticated,
        errorMessage: null,
      )),
    );
  }
}
