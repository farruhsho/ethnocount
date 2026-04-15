import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Internal notification entity (Firestore-based, auditable).
class AppNotification extends Equatable {
  final String id;
  final String targetBranchId;
  final String? targetUserId;
  final NotificationType type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final bool isRead;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.targetBranchId,
    this.targetUserId,
    required this.type,
    required this.title,
    required this.body,
    this.data = const {},
    this.isRead = false,
    required this.createdAt,
  });

  @override
  List<Object?> get props =>
      [id, targetBranchId, type, title, isRead, createdAt];
}
