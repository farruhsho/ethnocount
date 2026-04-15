import 'package:equatable/equatable.dart';

/// Base failure class for `Either<Failure, T>` returns.
abstract class Failure extends Equatable {
  final String message;
  final String? code;

  const Failure(this.message, {this.code});

  @override
  List<Object?> get props => [message, code];
}

/// Server-side error (Supabase RPC, Edge Functions).
class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code});
}

/// Network connectivity issue.
class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'No internet connection']);
}

/// Device is offline — mutation queued.
class OfflineFailure extends Failure {
  const OfflineFailure([super.message = 'Offline — action queued for sync']);
}

/// Authentication failure.
class AuthFailure extends Failure {
  const AuthFailure(super.message, {super.code});

  factory AuthFailure.fromCode(dynamic code) {
    final c = code.toString().toLowerCase();
    if (c.contains('user-not-found') || c.contains('invalid_credentials') || c == '400') {
      return const AuthFailure('Неверный email или пароль');
    }
    if (c.contains('wrong-password') || c.contains('invalid_grant')) {
      return const AuthFailure('Неверный пароль');
    }
    if (c.contains('email-already-in-use') || c.contains('user_already_exists') || c == '422') {
      return const AuthFailure('Этот email уже зарегистрирован');
    }
    if (c.contains('weak-password') || c.contains('weak_password')) {
      return const AuthFailure('Пароль слишком слабый');
    }
    if (c.contains('too-many-requests') || c.contains('over_request_rate_limit') || c == '429') {
      return const AuthFailure('Слишком много попыток. Попробуйте позже');
    }
    if (c.contains('user-disabled') || c.contains('user_banned')) {
      return const AuthFailure('Аккаунт заблокирован');
    }
    return AuthFailure('Ошибка аутентификации: $code');
  }
}

/// Permission denied.
class PermissionFailure extends Failure {
  const PermissionFailure([super.message = 'Permission denied']);
}

/// Validation failure.
class ValidationFailure extends Failure {
  const ValidationFailure(super.message);
}

/// Cache / local storage failure.
class CacheFailure extends Failure {
  const CacheFailure([super.message = 'Cache error']);
}

/// Unexpected failure.
class UnexpectedFailure extends Failure {
  const UnexpectedFailure([super.message = 'An unexpected error occurred']);
}

/// Insufficient funds for a financial operation.
class InsufficientFundsFailure extends Failure {
  const InsufficientFundsFailure(
      [super.message = 'Insufficient funds for this operation']);
}

/// Transfer has already been confirmed — prevents double confirmation.
class TransferAlreadyConfirmedFailure extends Failure {
  const TransferAlreadyConfirmedFailure(
      [super.message = 'Transfer has already been confirmed']);
}

/// Duplicate transfer detected.
class DuplicateTransferFailure extends Failure {
  const DuplicateTransferFailure(
      [super.message = 'Duplicate transfer — already exists']);
}
