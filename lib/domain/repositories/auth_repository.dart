import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/user.dart';

/// Auth repository interface.
abstract class AuthRepository {
  /// Current auth state stream.
  Stream<AppUser?> get authStateChanges;

  /// Currently signed-in user (synchronous, JWT-only — role/permissions
  /// fall back to defaults). Use [fetchCurrentUserProfile] when the
  /// authoritative role from the DB is needed.
  AppUser? get currentUser;

  /// Fetches the current user's full profile from the database (role,
  /// permissions, assigned branches). Returns null if no active session.
  Future<AppUser?> fetchCurrentUserProfile();

  /// Sign in with email & password.
  Future<Either<Failure, AppUser>> signInWithEmail(String email, String password);

  /// Check if the system has been initialized (any users exist).
  Future<bool> isSystemInitialized();

  /// Sign up with email & password.
  Future<Either<Failure, AppUser>> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
    bool asCreator = false,
  });

  /// Sign in with Google.
  Future<Either<Failure, AppUser>> signInWithGoogle();

  /// Send password reset email.
  Future<Either<Failure, void>> resetPassword(String email);

  /// Sign out.
  Future<Either<Failure, void>> signOut();

  /// Revoke all sessions (all devices). Then sign out locally.
  Future<Either<Failure, void>> revokeAllSessionsAndSignOut();
}
