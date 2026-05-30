import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/user.dart';

/// True если пользователь должен видеть данные ВСЕХ филиалов (без фильтра):
/// Creator (полный админ) и Director (управление + аналитика по всему).
/// Бухгалтер — только свои `assignedBranchIds`.
bool userSeesAllBranches(AppUser? user) {
  if (user == null) return false;
  return user.role.isCreator || user.role.isDirector;
}

/// Filters branches/data visible to the current user based on role and
/// [AppUser.assignedBranchIds]. Creators/директора видят всё; бухгалтеры —
/// только свои филиалы.
List<Branch> filterBranchesByAccess(List<Branch> branches, AppUser? user) {
  if (userSeesAllBranches(user)) return branches;
  if (user == null) return const [];
  final allowed = user.assignedBranchIds.toSet();
  return branches.where((b) => allowed.contains(b.id)).toList();
}

/// Returns true when user can view/operate on the given branch.
bool canAccessBranch(AppUser? user, String branchId) {
  if (user == null) return false;
  if (userSeesAllBranches(user)) return true;
  return user.assignedBranchIds.contains(branchId);
}

/// Returns the set of branch IDs the user can view. Для creator/director —
/// `null` означает «без фильтра, все филиалы». Для бухгалтера — assigned ids.
Set<String>? accessibleBranchIds(AppUser? user) {
  if (user == null) return <String>{};
  if (userSeesAllBranches(user)) return null;
  return user.assignedBranchIds.toSet();
}
