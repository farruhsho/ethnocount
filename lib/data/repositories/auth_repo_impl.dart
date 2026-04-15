import 'package:dartz/dartz.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/data/datasources/remote/auth_remote_ds.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/auth_repository.dart';

class AuthRepoImpl implements AuthRepository {
  final AuthRemoteDataSource _remoteDs;

  AuthRepoImpl(this._remoteDs);

  @override
  Stream<AppUser?> get authStateChanges => _remoteDs.authStateChanges;

  @override
  AppUser? get currentUser => _remoteDs.currentUser;

  @override
  Future<Either<Failure, AppUser>> signInWithEmail(
      String email, String password) async {
    try {
      final user = await _remoteDs.signInWithEmail(email, password);
      return Right(user);
    } on AuthException catch (e) {
      return Left(AuthFailure.fromCode(e.statusCode ?? e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<bool> isSystemInitialized() => _remoteDs.isSystemInitialized();

  @override
  Future<Either<Failure, AppUser>> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
    bool asCreator = false,
  }) async {
    try {
      final user = await _remoteDs.signUpWithEmail(
        email: email,
        password: password,
        displayName: displayName,
        asCreator: asCreator,
      );
      return Right(user);
    } on AuthException catch (e) {
      return Left(AuthFailure.fromCode(e.statusCode ?? e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, AppUser>> signInWithGoogle() async {
    // TODO: Implement Google sign-in
    return const Left(UnexpectedFailure('Google sign-in not yet implemented'));
  }

  @override
  Future<Either<Failure, void>> resetPassword(String email) async {
    try {
      await _remoteDs.resetPassword(email);
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure.fromCode(e.statusCode ?? e.message));
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> signOut() async {
    try {
      await _remoteDs.signOut();
      return const Right(null);
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> revokeAllSessionsAndSignOut() async {
    try {
      await _remoteDs.revokeAllSessions();
    } catch (_) {
      // Server may be unavailable — still sign out locally
    }
    try {
      await _remoteDs.signOut();
      return const Right(null);
    } catch (e) {
      return Left(UnexpectedFailure(e.toString()));
    }
  }
}
