import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/user.dart';

/// Filters branches/data visible to the current user based on role and
/// [AppUser.assignedBranchIds]. Creators see everything; accountants see
/// only their assigned branches.
List<Branch> filterBranchesByAccess(List<Branch> branches, AppUser? user) {
  if (user == null || user.role.isAdminOrCreator) return branches;
  final allowed = user.assignedBranchIds.toSet();
  return branches.where((b) => allowed.contains(b.id)).toList();
}

/// Returns true when user can view/operate on the given branch.
bool canAccessBranch(AppUser? user, String branchId) {
  if (user == null) return false;
  return user.role.isAdminOrCreator ||
      user.assignedBranchIds.contains(branchId);
}
