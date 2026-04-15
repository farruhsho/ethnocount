import 'package:flutter/foundation.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/branch_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/domain/entities/export_settings.dart';
import 'package:ethnocount/domain/services/ledger_export_service.dart';

class ServerExportService {
  final LedgerRemoteDataSource _ledgerDs;
  final TransferRemoteDataSource _transferDs;
  final BranchRemoteDataSource _branchDs;
  final UserRemoteDataSource _userDs;
  final LedgerExportService _ledgerExport;

  ServerExportService(
    this._ledgerDs,
    this._transferDs,
    this._branchDs,
    this._userDs,
    this._ledgerExport,
  );

  Future<String?> exportReport({
    required String reportType,
    String? branchId,
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) async {
    try {
      // With Supabase, all exports are done client-side (local fallback always).
      return _exportLocal(
        reportType: reportType,
        branchId: branchId,
        startDate: startDate,
        endDate: endDate,
        exportSettings: exportSettings,
      );
    } catch (e) {
      debugPrint('Export error: $e');
      rethrow;
    }
  }

  Future<String?> _exportLocal({
    required String reportType,
    String? branchId,
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) async {
    final suffix = '${branchId ?? 'all'}_${DateTime.now().millisecondsSinceEpoch}';

    switch (reportType) {
      case 'ledger':
        if (branchId == null) return null;
        final entries = await _ledgerDs.getEntriesForExport(
          branchId: branchId,
          startDate: startDate,
          endDate: endDate,
          limit: exportSettings?.rowLimit,
        );
        final branchName = await _getBranchName(branchId);
        final accountNames = await _loadAccountNames(branchId);
        final ok = await _ledgerExport.exportLedgerToExcel(
          entries,
          'ledger_$suffix',
          accountNames: accountNames,
          branchName: branchName,
          startDate: startDate,
          endDate: endDate,
          exportSettings: exportSettings,
        );
        return ok ? 'local' : null;

      case 'transfers':
        final transfers = await _transferDs.getTransfersForExport(
          branchId: branchId,
          startDate: startDate,
          endDate: endDate,
          limit: exportSettings?.rowLimit,
        );
        final branchNames = await _loadBranchNames();
        final userNames = await _loadUserNames();
        final ok = await _ledgerExport.exportTransfersToExcel(
          transfers,
          'transfers_$suffix',
          branchNames: branchNames,
          userNames: userNames,
          startDate: startDate,
          endDate: endDate,
          exportSettings: exportSettings,
        );
        return ok ? 'local' : null;

      case 'commissions':
        final commissions = await _ledgerDs.getCommissionsForExport(
          startDate: startDate,
          endDate: endDate,
        );
        final ok = await _ledgerExport.exportCommissionsToExcel(
          commissions,
          'commissions_$suffix',
        );
        return ok ? 'local' : null;

      case 'monthly_summary':
        if (branchId == null) return null;
        final entries = await _ledgerDs.getEntriesForExport(
          branchId: branchId,
          startDate: startDate,
          endDate: endDate,
        );
        final branchName = await _getBranchName(branchId);
        final accountNames = await _loadAccountNames(branchId);
        final ok = await _ledgerExport.exportMonthlySummaryToExcel(
          entries,
          'monthly_summary_$suffix',
          accountNames: accountNames,
          branchName: branchName,
          startDate: startDate,
          endDate: endDate,
        );
        return ok ? 'local' : null;

      default:
        return null;
    }
  }

  Future<Map<String, String>> _loadBranchNames() async {
    final branches = await _branchDs.watchBranches().first;
    return {for (var b in branches) b.id: b.name};
  }

  Future<String> _getBranchName(String branchId) async {
    try {
      final branch = await _branchDs.getBranch(branchId);
      return branch.name;
    } catch (_) {
      return branchId;
    }
  }

  Future<Map<String, String>> _loadAccountNames(String branchId) async {
    try {
      final accounts = await _branchDs.watchBranchAccounts(branchId).first;
      return {for (var a in accounts) a.id: a.name};
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, String>> _loadUserNames() async {
    try {
      final users = await _userDs.watchUsers().first;
      return {for (var u in users) u.id: u.displayName};
    } catch (_) {
      return {};
    }
  }

  Future<String?> exportLedger({
    required String branchId,
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) =>
      exportReport(
        reportType: 'ledger',
        branchId: branchId,
        startDate: startDate,
        endDate: endDate,
        exportSettings: exportSettings,
      );

  Future<String?> exportTransfers({
    String? branchId,
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) =>
      exportReport(
        reportType: 'transfers',
        branchId: branchId,
        startDate: startDate,
        endDate: endDate,
        exportSettings: exportSettings,
      );

  Future<String?> exportCommissions({
    DateTime? startDate,
    DateTime? endDate,
  }) =>
      exportReport(
        reportType: 'commissions',
        startDate: startDate,
        endDate: endDate,
      );

  Future<String?> exportMonthlySummary({
    required String branchId,
    DateTime? startDate,
    DateTime? endDate,
  }) =>
      exportReport(
        reportType: 'monthly_summary',
        branchId: branchId,
        startDate: startDate,
        endDate: endDate,
      );
}
