// cases.dart — System Administrator view of every case (the "Cases" tab).
//
// A case groups one or more incidents (submissions) into one investigation
// and has investigators assigned to it. Here the admin can:
//   * see all cases, most recently active first
//   * search by case number ("3", "CASE-0003") or title
//   * filter by status (Open / Under review / Closed)
//   * create a new case
//   * tap a case to open CaseDetailPage (incidents, investigators, status)
//
// Data comes from SupabaseService.listCases (the list_cases function).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';

/// Body of the Cases tab. Like the other admin tabs, it has no Scaffold or
/// header of its own — AdminDashboard draws those.
class AdminCases extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const AdminCases({super.key, this.service});

  /// How long to wait after the last key press before searching.
  static const searchDelay = Duration(milliseconds: 400);

  /// Filter chips: label → status passed to the database (null = all).
  static const filters = <(String, String?)>[
    ('All', null),
    ('Open', 'open'),
    ('Under review', 'under_review'),
    ('Closed', 'closed'),
  ];

  @override
  State<AdminCases> createState() => _AdminCasesState();
}

class _AdminCasesState extends State<AdminCases> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  final _searchController = TextEditingController();
  Timer? _searchTimer;

  String _query = '';
  String? _status; // current filter chip (null = all)
  List<CaseSummary> _cases = const [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch(); // _loading already starts as true
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = ++_requestId;
    try {
      final rows = await _service.listCases(query: _query, status: _status);
      if (!mounted || id != _requestId) return;
      setState(() {
        _cases = rows;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'Could not load cases. Check your connection.';
        _loading = false;
      });
    }
  }

  void _reload() {
    _searchTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    _searchTimer = Timer(AdminCases.searchDelay, _reload);
  }

  void _clearSearch() {
    _searchController.clear();
    _query = '';
    _reload();
  }

  void _onFilter(String? status) {
    if (status == _status) return;
    _status = status;
    _reload();
  }

  Future<void> _openCase(int caseId) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CaseDetailPage(caseId: caseId, service: _service),
      ),
    );
    if (mounted) _reload();
  }

  /// New case (no incidents yet), then open it to add incidents.
  Future<void> _newCase() async {
    final caseId = await showAdminSheet<int>(
      context,
      title: 'New case',
      builder: (sheetContext) => NewCaseForm(
        onCreate: (title, description) async {
          final id =
              await _service.createCase(title: title, description: description);
          if (sheetContext.mounted) Navigator.pop(sheetContext, id);
        },
      ),
    );
    if (caseId == null || !mounted) return;
    showSnack(context, 'CASE-${caseId.toString().padLeft(4, '0')} created');
    await _openCase(caseId);
  }

  String get _countText {
    final n = _cases.length;
    if (_query.trim().isEmpty) {
      return n == 1 ? '1 case' : '$n cases';
    }
    return '$n ${n == 1 ? 'match' : 'matches'} for "${_query.trim()}"';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Cases', style: AppText.sectionTitle),
              ),
              SmallActionButton(
                label: '+ New case',
                color: AppColors.accent,
                onPressed: _newCase,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.small),
          const Text(
            'Monitor every investigation and assign investigators.',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpacing.medium),

          TextField(
            controller: _searchController,
            style: AppText.body,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _reload(),
            decoration: InputDecoration(
              hintText: 'Search by case number/title',
              prefixIcon: const Icon(Icons.search, color: AppColors.accent),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: AppColors.textMuted),
                      tooltip: 'Clear search',
                      onPressed: _clearSearch,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.small),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, value) in AdminCases.filters) ...[
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == value,
                    onSelected: (_) => _onFilter(value),
                    selectedColor: AppColors.accent,
                    backgroundColor: AppColors.header,
                    labelStyle: AppText.body.copyWith(
                      fontSize: 13,
                      color: _status == value
                          ? AppColors.header
                          : AppColors.textPrimary,
                    ),
                    showCheckmark: false,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.small),
          if (!_loading && _error == null)
            Text(
              _countText,
              style: AppText.caption.copyWith(color: AppColors.textMuted),
            ),
          const SizedBox(height: AppSpacing.medium),

          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppText.bodyMuted, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.small),
            TextButton(onPressed: _reload, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (_cases.isEmpty) {
      return Center(
        child: Text(
          _query.trim().isNotEmpty
              ? 'No cases match your search.'
              : _status == null
                  ? 'No cases yet. Accept a submission or tap "+ New case".'
                  : 'No cases with this status.',
          style: AppText.bodyMuted,
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _cases.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.medium),
        itemBuilder: (context, index) {
          final c = _cases[index];
          return CaseCard(caseSummary: c, onTap: () => _openCase(c.caseId));
        },
      ),
    );
  }
}

/// One case in the list: reference, status, title, incidents, who is on it.
class CaseCard extends StatelessWidget {
  final CaseSummary caseSummary;
  final VoidCallback? onTap;

  const CaseCard({super.key, required this.caseSummary, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = caseSummary;
    final (statusLabel, statusColor) = statusStyle(c.status);
    final unassigned = c.investigators.isEmpty && !c.isClosed;

    return Material(
      color: AppColors.header,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(c.reference, style: AppText.cardTitle)),
                  const SizedBox(width: AppSpacing.small),
                  StatusTag(label: statusLabel, color: statusColor),
                ],
              ),
              const SizedBox(height: 6),
              Text(c.title,
                  style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Divider(color: AppColors.fieldBorder, height: 1),
              const SizedBox(height: 12),
              DetailLine(
                icon: Icons.description_outlined,
                text: '${c.incidentCount} '
                    '${c.incidentCount == 1 ? 'incident' : 'incidents'}',
              ),
              DetailLine(
                icon: Icons.badge_outlined,
                text: unassigned
                    ? 'No investigator assigned'
                    : c.investigators.isEmpty
                        ? 'No investigators'
                        : c.investigators.map((i) => i.name).join(', '),
                color: unassigned ? AppColors.accent : null,
              ),
              DetailLine(
                icon: Icons.event,
                text: 'Created ${formatDate(c.dateCreated)}'
                    '${c.dateClosed == null ? '' : ' · closed ${formatDate(c.dateClosed!)}'}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
