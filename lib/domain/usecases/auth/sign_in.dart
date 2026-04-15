import 'package:dartz/dartz.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/domain/entities/user.dart';
import 'package:ethnocount/domain/repositories/auth_repository.dart';

class SignInUseCase {
  final AuthRepository _repo;
  const SignInUseCase(this._repo);

  Future<Either<Failure, AppUser>> call(String email, String password) {
    return _repo.signInWithEmail(email, password);
  }
}

class SignUpUseCase {
  final AuthRepository _repo;
  const SignUpUseCase(this._repo);

  Future<Either<Failure, AppUser>> call({
    required String email,
    required String password,
    required String displayName,
    bool asCreator = false,
  }) {
    return _repo.signUpWithEmail(
      email: email,
      password: password,
      displayName: displayName,
      asCreator: asCreator,
    );
  }
}

class SignOutUseCase {
  final AuthRepository _repo;
  const SignOutUseCase(this._repo);

  Future<Either<Failure, void>> call() => _repo.signOut();
}
