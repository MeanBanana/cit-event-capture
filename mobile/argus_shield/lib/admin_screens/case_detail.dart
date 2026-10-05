// case_detail.dart — full page for one case (opened from the Cases tab, a
// submission's "Open case" button, or after creating a case).
//
// The admin can:
//   * change the status (Open / Under review / Closed) and edit the title
//     and description
//   * assign investigators and remove them (past assignments are kept)
//   * add pending submissions to the case, open an incident, move it to
//     another case or remove it from this one
// A closed case can't get new incidents or investigators until reopened.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/case_assignment_info.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';

class CaseDetailPage extends StatefulWidget {
  final int caseId;

  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const CaseDetailPage({super.key, required this.caseId, this.service});

  /// Status chips: label → database value.
  static const statuses = <(String, String)>[
    ('Open', 'open'),
    ('Under review', 'under_review'),
    ('Closed', 'closed'),
  ];

  @override
  State<CaseDetailPage> createState() => _CaseDetailPageState();
}

class _CaseDetailPageState extends State<CaseDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();

  CaseSummary? _case;
  List<CrimeSceneSummary> _incidents = const [];
  List<CaseAssignmentInfo> _assignments = const [];
  bool _loading = true;
  bool _busy = false; // an action is running
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the case, its incidents and its investigators together.
  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _service.getCase(widget.caseId),
        _service.getCaseIncidents(widget.caseId),
        _service.getCaseAssignments(widget.caseId),
      ]);
      if (!mounted) return;
      final c = results[0] as CaseSummary?;
      setState(() {
        _case = c;
        _incidents = results[1] as List<CrimeSceneSummary>;
        _assignments = results[2] as List<CaseAssignmentInfo>;
        _error = c == null ? 'This case no longer exists.' : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this case. Pull down to try again.';
        _loading = false;
      });
    }
  }

  /// Runs an action with a spinner, shows its message or error, reloads.
  Future<void> _run(String doneMessage, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showSnack(context, doneMessage);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  // ---- Status and details ---------------------------------------------------

  Future<void> _setStatus(String status) async {
    final c = _case;
    if (c == null || status == c.status) return;
    if (status == 'closed') {
      final ok = await confirmAction(
        context,
        title: 'Close ${c.reference}?',
        message: 'Assigned investigators keep access to it. You can\'t add '
            'incidents or investigators until it is reopened.',
        confirmLabel: 'Close case',
      );
      if (!ok || !mounted) return;
    }
    final (label, _) = statusStyle(status);
    await _run('${c.reference} is now ${label.toLowerCase()}',
        () => _service.updateCase(c.caseId, status: status));
  }

  Future<void> _edit() async {
    final c = _case;
    if (c == null) return;
    final saved = await showAdminSheet<bool>(
      context,
      title: 'Edit ${c.reference}',
      builder: (sheetContext) => NewCaseForm(
        initialTitle: c.title,
        initialDescription: c.description ?? '',
        buttonLabel: 'Save changes',
        onCreate: (title, description) async {
          await _service.updateCase(c.caseId,
              title: title, description: description);
          if (sheetContext.mounted) Navigator.pop(sheetContext, true);
        },
      ),
    );
    if (saved == true && mounted) {
      showSnack(context, '${c.reference} updated');
      await _load();
    }
  }

  // ---- Investigators --------------------------------------------------------

  Future<void> _assign() async {
    final c = _case;
    if (c == null) return;
    final active = _assignments.where((a) => a.isActive).map((a) => a.userId);
    final name = await showAdminSheet<String>(
      context,
      title: 'Assign to ${c.reference}',
      builder: (sheetContext) => InvestigatorPicker(
        service: _service,
        exclude: active.toSet(),
        onSelected: (person) async {
          try {
            await _service.assignInvestigator(c.caseId, person.userId);
            if (sheetContext.mounted) {
              Navigator.pop(sheetContext, person.displayName);
            }
          } catch (e) {
            if (sheetContext.mounted) showSnack(sheetContext, errorText(e));
          }
        },
      ),
    );
    if (name != null && mounted) {
      showSnack(context, '$name assigned to ${c.reference}');
      await _load();
    }
  }

  Future<void> _unassign(CaseAssignmentInfo a) async {
    final c = _case;
    if (c == null) return;
    final ok = await confirmAction(
      context,
      title: 'Remove ${a.name}?',
      message: '${a.name} will no longer see ${c.reference}. '
          'The assignment stays in the case history.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run('${a.name} removed from ${c.reference}',
        () => _service.unassignInvestigator(a.assignmentId));
  }

  // ---- Incidents -------------------------------------------------------------

  Future<void> _addIncidents() async {
    final c = _case;
    if (c == null) return;
    final added = await showAdminSheet<int>(
      context,
      title: 'Add to ${c.reference}',
      builder: (sheetContext) => IncidentPicker(
        service: _service,
        review: 'pending', // only submissions waiting for review
        multiSelect: true,
        confirmLabel: 'Add',
        onConfirm: (ids) async {
          try {
            await _service.addIncidentsToCase(c.caseId, ids);
            if (sheetContext.mounted) Navigator.pop(sheetContext, ids.length);
          } catch (e) {
            if (sheetContext.mounted) showSnack(sheetContext, errorText(e));
          }
        },
      ),
    );
    if (added != null && mounted) {
      showSnack(context,
          '$added ${added == 1 ? 'incident' : 'incidents'} added to ${c.reference}');
      await _load();
    }
  }

  Future<void> _openIncident(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _incidentAction(
      Future<bool> Function(BuildContext, SupabaseService, CrimeSceneSummary)
          action,
      CrimeSceneSummary s) async {
    final changed = await action(context, _service, s);
    if (changed && mounted) await _load();
  }

  // ---- Page ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ArgusAppBar(roleLabel: 'Admin'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _case == null
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: AppSpacing.page,
                      children: [
                        Text(_error ?? 'This case no longer exists.',
                            style: AppText.bodyMuted,
                            textAlign: TextAlign.center),
                      ],
                    )
                  : _content(_case!),
            ),
    );
  }

  Widget _content(CaseSummary c) {
    final (statusLabel, statusColor) = statusStyle(c.status);
    final active = _assignments.where((a) => a.isActive).toList();
    final past = _assignments.where((a) => !a.isActive).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: AppSpacing.page,
      children: [
        Row(
          children: [
            Expanded(child: Text(c.reference, style: AppText.sectionTitle)),
            StatusTag(label: statusLabel, color: statusColor),
          ],
        ),
        const SizedBox(height: 8),
        Text(c.title,
            style: AppText.body
                .copyWith(fontSize: 18, fontWeight: FontWeight.bold)),
        if (c.description != null) ...[
          const SizedBox(height: 6),
          Text(c.description!, style: AppText.bodyMuted),
        ],
        const SizedBox(height: 8),
        DetailLine(
          icon: Icons.event,
          text: 'Created ${formatDateTime(c.dateCreated)}'
              '${c.createdByName == null ? '' : ' by ${c.createdByName}'}',
        ),
        if (c.dateClosed != null)
          DetailLine(
              icon: Icons.lock_outline,
              text: 'Closed ${formatDateTime(c.dateClosed!)}'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _edit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit title / description'),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),

        // ---- Status ----------------------------------------------------------
        const SectionLabel('Status'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in CaseDetailPage.statuses)
              ChoiceChip(
                label: Text(label),
                selected: c.status == value,
                onSelected: _busy ? null : (_) => _setStatus(value),
                selectedColor: statusStyle(value).$2,
                backgroundColor: AppColors.header,
                labelStyle: AppText.body.copyWith(
                  fontSize: 13,
                  color: c.status == value
                      ? AppColors.header
                      : AppColors.textPrimary,
                ),
                showCheckmark: false,
              ),
          ],
        ),

        // ---- Investigators ---------------------------------------------------
        SectionLabel(
          'Investigators',
          trailing: SmallActionButton(
            label: '+ Assign',
            color: AppColors.accent,
            onPressed: c.isClosed || _busy ? null : _assign,
          ),
        ),
        if (active.isEmpty)
          Text(
            c.isClosed
                ? 'No investigators on this case.'
                : 'No investigator assigned yet.',
            style: AppText.bodyMuted.copyWith(
                color: c.isClosed ? AppColors.textMuted : AppColors.accent),
          ),
        for (final a in active)
          _AssignmentRow(
            assignment: a,
            onRemove: _busy ? null : () => _unassign(a),
          ),
        if (past.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Previously assigned',
              style: AppText.caption.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final a in past)
            Text(
              '${a.name} · ${formatDate(a.dateAssigned)}'
              '${a.dateUnassigned == null ? '' : ' – ${formatDate(a.dateUnassigned!)}'}',
              style: AppText.bodyMuted.copyWith(fontSize: 13),
            ),
        ],

        // ---- Incidents -------------------------------------------------------
        SectionLabel(
          'Incidents (${_incidents.length})',
          trailing: SmallActionButton(
            label: '+ Add',
            color: AppColors.accent,
            onPressed: c.isClosed || _busy ? null : _addIncidents,
          ),
        ),
        if (_incidents.isEmpty)
          const Text('No incidents in this case yet.',
              style: AppText.bodyMuted),
        for (final s in _incidents)
          _IncidentRow(
            incident: s,
            onOpen: () => _openIncident(s),
            onMove: s.isDuplicate || c.isClosed
                ? null
                : () => _incidentAction(moveToCase, s),
            onRemove: () => _incidentAction(removeFromCase, s),
          ),
      ],
    );
  }
}

/// One assigned investigator, with a remove button.
class _AssignmentRow extends StatelessWidget {
  final CaseAssignmentInfo assignment;
  final VoidCallback? onRemove;

  const _AssignmentRow({required this.assignment, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final details = [
      if (a.badgeNumber != null) a.badgeNumber!,
      if (a.station != null) a.station!,
      'since ${formatDate(a.dateAssigned)}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.header,
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.badge_outlined, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name,
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                Text(details, style: AppText.bodyMuted.copyWith(fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.person_remove_outlined,
                color: AppColors.danger),
            tooltip: 'Remove from case',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// One incident in the case: tap to open; menu to move or remove.
class _IncidentRow extends StatelessWidget {
  final CrimeSceneSummary incident;
  final VoidCallback onOpen;
  final VoidCallback? onMove; // null hides "Move" (duplicates, closed case)
  final VoidCallback onRemove;

  const _IncidentRow({
    required this.incident,
    required this.onOpen,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final s = incident;
    final (statusLabel, statusColor) = statusStyle(s.status);

    // Material (not a coloured Container) so the ListTile's tap ripple
    // shows on top of the card colour
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
      color: AppColors.header,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 12, right: 0),
        onTap: onOpen,
        title: Text(
          s.isDuplicate && s.duplicateOf != null
              ? '${s.reference} · duplicate of ${incidentReference(s.duplicateOf!)}'
              : s.reference,
          style: AppText.cardTitle.copyWith(fontSize: 15),
        ),
        subtitle: Text(
          '${s.location}\n'
          'Happened ${formatDateTime(s.dateTime)} · $statusLabel',
          style: AppText.bodyMuted.copyWith(fontSize: 13),
        ),
        isThreeLine: true,
        leading: Icon(Icons.description_outlined, color: statusColor),
        trailing: PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
          color: AppColors.header,
          onSelected: (value) {
            if (value == 'open') {
              onOpen();
            } else if (value == 'move') {
              onMove?.call();
            } else {
              onRemove();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
                value: 'open', child: Text('View', style: AppText.body)),
            if (onMove != null)
              const PopupMenuItem(
                  value: 'move',
                  child: Text('Move to another case', style: AppText.body)),
            PopupMenuItem(
              value: 'remove',
              child: Text('Remove from case',
                  style: AppText.body.copyWith(color: AppColors.danger)),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
