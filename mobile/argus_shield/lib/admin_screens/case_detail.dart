// case_detail.dart — full page for one case (opened from the Cases tab, the
// Submissions tab's Case view, a submission's "Open case" button, or after
// creating a case).
//
// The admin can:
//   * change the status (Open / Under review / Closed) and edit the title
//     and description
//   * assign investigators, choose the lead, remove them (past
//     assignments are kept)
//   * see every submission in the case (30 at a time, "Load more"), each
//     with the citizen's and the AI's descriptions
//   * add submissions: pick pending ones, or one tap on a RECOMMENDED one
//     (the database scores pending submissions against the case: AI links,
//     same plate, distance, time ...)
//   * open a submission, move it to another case, or remove it from this
//     one. Removing never deletes it: it goes back to "Pending review" and
//     keeps all its footage and history.
//   * read the case history (who did what, when)
// A closed case can't get new submissions or investigators until reopened.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/case_assignment_info.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';
import 'package:argus_shield/admin_screens/submissions.dart'
    show CrimeSceneCard;

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

  /// How many history lines show before "Show more".
  static const historyPageSize = 10;

  @override
  State<CaseDetailPage> createState() => _CaseDetailPageState();
}

class _CaseDetailPageState extends State<CaseDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();

  CaseSummary? _case;
  List<CrimeSceneSummary> _incidents = const [];
  bool _moreIncidents = false; // another page of submissions exists
  bool _loadingMore = false;
  List<CaseAssignmentInfo> _assignments = const [];
  List<(IncidentSuggestion, CrimeSceneSummary)> _suggestions = const [];
  List<CaseEvent> _history = const [];
  bool _moreHistory = false;
  bool _loading = true;
  bool _busy = false; // an action is running
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the case, the first page of its submissions, its investigators,
  /// suggestions and history together.
  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _service.getCase(widget.caseId),
        _service.listSubmissionsPage(caseId: widget.caseId),
        _service.getCaseAssignments(widget.caseId),
        _loadSuggestions(),
        _loadHistory(),
      ]);
      if (!mounted) return;
      final c = results[0] as CaseSummary?;
      final incidents = results[1] as List<CrimeSceneSummary>;
      final history = results[4] as List<CaseEvent>;
      setState(() {
        _case = c;
        _incidents = incidents;
        _moreIncidents = incidents.length >= SupabaseService.pageSize;
        _assignments = results[2] as List<CaseAssignmentInfo>;
        _suggestions =
            results[3] as List<(IncidentSuggestion, CrimeSceneSummary)>;
        _history = history;
        _moreHistory = history.length >= CaseDetailPage.historyPageSize;
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

  /// Suggested submissions with their details. Never fails the page.
  Future<List<(IncidentSuggestion, CrimeSceneSummary)>> _loadSuggestions() async {
    try {
      final found = await _service.suggestIncidentsForCase(widget.caseId);
      if (found.isEmpty) return const [];
      final rows = await _service.listSubmissionsPage(
          ids: [for (final f in found) f.incidentId], limit: found.length);
      final byId = {for (final r in rows) r.incidentId: r};
      return [
        for (final f in found)
          if (byId[f.incidentId] != null) (f, byId[f.incidentId]!),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<CaseEvent>> _loadHistory() async {
    try {
      return await _service.getCaseEvents(widget.caseId,
          limit: CaseDetailPage.historyPageSize);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadMoreIncidents() async {
    if (_loadingMore || _incidents.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _service.listSubmissionsPage(
          caseId: widget.caseId, after: _incidents.last);
      if (!mounted) return;
      setState(() {
        _incidents = [..._incidents, ...page];
        _moreIncidents = page.length >= SupabaseService.pageSize;
      });
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_history.isEmpty) return;
    try {
      final page = await _service.getCaseEvents(widget.caseId,
          before: _history.last, limit: CaseDetailPage.historyPageSize);
      if (!mounted) return;
      setState(() {
        _history = [..._history, ...page];
        _moreHistory = page.length >= CaseDetailPage.historyPageSize;
      });
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
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
            'submissions or investigators until it is reopened.',
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
          'The assignment stays in the case history.'
          '${a.isLead ? '\n\nThey are the lead: choose a new lead afterwards.' : ''}',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run('${a.name} removed from ${c.reference}',
        () => _service.unassignInvestigator(a.assignmentId));
  }

  Future<void> _makeLead(CaseAssignmentInfo a) async {
    final c = _case;
    if (c == null || a.isLead) return;
    await _run('${a.name} is now the lead on ${c.reference}',
        () => _service.setCaseLead(a.assignmentId));
  }

  // ---- Submissions -----------------------------------------------------------

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
          '${plural(added, 'submission')} added to ${c.reference}');
      await _load();
    }
  }

  Future<void> _addSuggested(CrimeSceneSummary s) async {
    final c = _case;
    if (c == null) return;
    await _run('${s.reference} added to ${c.reference}',
        () => _service.addIncidentsToCase(c.caseId, [s.incidentId]));
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

  Future<void> _incidentAction(ReviewAction action, CrimeSceneSummary s) async {
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
    final noLead = active.isNotEmpty && !active.any((a) => a.isLead);
    final total = c.incidentCount > _incidents.length
        ? c.incidentCount
        : _incidents.length;

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
        if (c.plates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final plate in c.plates)
                  FactChip(plate,
                      icon: Icons.pin_outlined, color: AppColors.accent),
              ],
            ),
          ),
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
        if (noLead)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('No lead investigator: tap ☆ to choose one.',
                style: AppText.bodyMuted.copyWith(color: AppColors.accent)),
          ),
        for (final a in active)
          _AssignmentRow(
            assignment: a,
            onRemove: _busy ? null : () => _unassign(a),
            onMakeLead: _busy || a.isLead ? null : () => _makeLead(a),
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

        // ---- Recommended -----------------------------------------------------
        if (!c.isClosed && _suggestions.isNotEmpty) ...[
          const SectionLabel('Recommended for this case'),
          Text(
            'Pending submissions that look like the same incident. '
            'Check them before adding.',
            style: AppText.bodyMuted.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final (suggestion, s) in _suggestions) ...[
            SuggestionTile(
              title: '${s.reference} · ${s.location}',
              score: suggestion.score,
              reasons: [
                ...suggestion.reasons,
                'matches ${incidentReference(suggestion.matchedIncidentId)}',
              ],
              actionLabel: 'Add',
              onAction: _busy ? null : () => _addSuggested(s),
              onTap: () => _openIncident(s),
            ),
            const SizedBox(height: AppSpacing.small),
          ],
        ],

        // ---- Submissions -----------------------------------------------------
        SectionLabel(
          'Submissions ($total)',
          trailing: SmallActionButton(
            label: '+ Add',
            color: AppColors.accent,
            onPressed: c.isClosed || _busy ? null : _addIncidents,
          ),
        ),
        if (_incidents.isEmpty)
          const Text('No submissions in this case yet.',
              style: AppText.bodyMuted),
        for (final s in _incidents)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.small),
            child: CrimeSceneCard(
              submission: s,
              onTap: () => _openIncident(s),
              menu: _IncidentMenu(
                onOpen: () => _openIncident(s),
                onMove: s.isDuplicate || c.isClosed
                    ? null
                    : () => _incidentAction(moveToCase, s),
                onRemove: () => _incidentAction(removeFromCase, s),
              ),
            ),
          ),
        if (_moreIncidents)
          Center(
            child: _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(),
                  )
                : TextButton(
                    onPressed: _loadMoreIncidents,
                    child: Text(
                        'Load more (${total - _incidents.length} not shown)'),
                  ),
          ),

        // ---- History ---------------------------------------------------------
        if (_history.isNotEmpty) ...[
          const SectionLabel('History'),
          for (final e in _history) _HistoryRow(event: e),
          if (_moreHistory)
            Center(
              child: TextButton(
                  onPressed: _loadMoreHistory,
                  child: const Text('Show older history')),
            ),
        ],
      ],
    );
  }
}

/// One assigned investigator: lead star, details, remove button.
class _AssignmentRow extends StatelessWidget {
  final CaseAssignmentInfo assignment;
  final VoidCallback? onRemove;
  final VoidCallback? onMakeLead; // null for the lead itself

  const _AssignmentRow({
    required this.assignment,
    this.onRemove,
    this.onMakeLead,
  });

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final details = [
      if (a.isLead) 'Lead',
      if (a.badgeNumber != null) a.badgeNumber!,
      if (a.station != null) a.station!,
      'since ${formatDate(a.dateAssigned)}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.header,
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(a.isLead ? Icons.star : Icons.star_border,
                color: AppColors.accent),
            tooltip: a.isLead ? 'Lead investigator' : 'Make lead',
            onPressed: onMakeLead,
          ),
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

/// ⋮ menu on a submission in the case: view, move, remove.
class _IncidentMenu extends StatelessWidget {
  final VoidCallback onOpen;
  final VoidCallback? onMove; // null hides "Move" (duplicates, closed case)
  final VoidCallback onRemove;

  const _IncidentMenu({
    required this.onOpen,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
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
    );
  }
}

/// One line of the case history.
class _HistoryRow extends StatelessWidget {
  final CaseEvent event;

  const _HistoryRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final e = event;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 8, color: AppColors.accent),
          ),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.text, style: AppText.body.copyWith(fontSize: 14)),
                Text(
                  '${formatDateTime(e.occurredAt)}'
                  '${e.actorName == null ? '' : ' · ${e.actorName}'}',
                  style: AppText.bodyMuted.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
