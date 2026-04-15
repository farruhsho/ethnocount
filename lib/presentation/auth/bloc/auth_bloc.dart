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
  }

  Future<void> _onCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    try {
      final currentUser = _authRepository.currentUser;
      if (currentUser == null) {
        emit(state.copyWith(status: AuthStatus.unauthenticated));
        return;
      }
      try {
        final stillListed =
            await _userSessionDs.isOurSessionStillListed(currentUser.id);
        if (!stillListed) {
          await _authRepository.signOut();
          await _sessionService.clearLogin();
          emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
          return;
        }
      } catch (_) {
        // Ignore: Firestore may be unavailable
      }
      final sessionDays =
          await _systemSettingsDs.getSessionDurationDays();
      final expired = await _sessionService.isSessionExpired(sessionDays);
      if (expired) {
        await _authRepository.signOut();
        await _sessionService.clearLogin();
        emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
        return;
      }
      try {
        await _userSessionDs.logSession(currentUser.id);
      } catch (_) {
        // Ignore: Firestore rules may not be deployed yet
      }
      emit(state.copyWith(status: AuthStatus.authenticated, user: currentUser));
    } catch (_) {
      emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
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
    await _signOut();
    await _sessionService.clearLogin();
    emit(state.copyWith(status: AuthStatus.unauthenticated, clearUser: true));
  }

  Future<void> _onSignOutAllDevices(
    AuthSignOutAllDevicesRequested event,
    Emitter<AuthState> emit,
  ) async {
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
