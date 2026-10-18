// review_actions.dart — what happens when the admin taps Accept, Reject,
// Duplicate, Move, Remove from case or Reopen on a submission.
//
// Each function asks for whatever it needs (a case, a reason, ...), calls
// SupabaseService, shows a short message, and returns true when something
// changed, so the calling screen knows to reload.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';

/// The shape of every action below: returns true when something changed.
typedef ReviewAction = Future<bool> Function(
    BuildContext context, SupabaseService service, CrimeSceneSummary submission);

/// Accept: put the submission in a NEW case or an EXISTING one. The panel
/// suggests the cases it most likely belongs to first.
Future<bool> acceptSubmission(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) =>
    acceptSubmissions(context, service, [submission]);

/// Accept several submissions at once (e.g. a linked group) into one new
/// or existing case.
Future<bool> acceptSubmissions(
  BuildContext context,
  SupabaseService service,
  List<CrimeSceneSummary> submissions,
) async {
  if (submissions.isEmpty) return false;
  final title = submissions.length == 1
      ? 'Accept ${submissions.first.reference}'
      : 'Accept ${submissions.length} submissions';
  final result = await showAdminSheet<_AcceptResult>(
    context,
    title: title,
    builder: (sheetContext) =>
        _AcceptChoice(service: service, submissions: submissions),
  );
  if (result == null) return false;
  if (!context.mounted) return true;

  if (result.openCase) {
    // "The case isn't listed" -> it was just created; go to its page
    showSnack(context, result.message);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CaseDetailPage(caseId: result.caseId, service: service),
      ),
    );
  } else {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(result.message),
        action: SnackBarAction(
          label: 'OPEN CASE',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  CaseDetailPage(caseId: result.caseId, service: service),
            ),
          ),
        ),
      ));
  }
  return true;
}

/// What the Accept panel did.
class _AcceptResult {
  final String message;
  final int caseId;
  final bool openCase; // go to the case page now

  const _AcceptResult(this.message, this.caseId, {this.openCase = false});
}

/// Reject: ask for an optional reason, then reject. It stays on record.
Future<bool> rejectSubmission(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  // null = cancelled; '' = rejected without a reason
  final note = await showDialog<String>(
    context: context,
    builder: (_) => _RejectDialog(reference: submission.reference),
  );
  if (note == null || !context.mounted) return false;

  return _run(context, '${submission.reference} rejected',
      () => service.rejectSubmission(submission.incidentId, note: note));
}

/// Asks "Reject INC-0042?" with an optional reason. Pops with the reason
/// (possibly empty) or null when cancelled. Owns its text controller so it
/// is only disposed after the dialog has fully closed.
class _RejectDialog extends StatefulWidget {
  final String reference;

  const _RejectDialog({required this.reference});

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reject ${widget.reference}?', style: AppText.cardTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'It stays on record but will not be used in any case. '
            'You can reopen it later.',
            style: AppText.body,
          ),
          const SizedBox(height: AppSpacing.small),
          TextField(
            controller: _reason,
            style: AppText.body,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
                hintText: 'Reason (optional), e.g. not a CIT incident'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _reason.text.trim()),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}

/// Duplicate: choose the original incident.
Future<bool> markAsDuplicate(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  final done = await showAdminSheet<String>(
    context,
    title: '${submission.reference} is a duplicate of...',
    builder: (sheetContext) => IncidentPicker(
      service: service,
      exclude: {submission.incidentId},
      onSelected: (original) async {
        try {
          await service.markDuplicate(
              submission.incidentId, original.incidentId);
          if (sheetContext.mounted) {
            Navigator.pop(sheetContext,
                '${submission.reference} marked as a duplicate of ${original.reference}');
          }
        } catch (e) {
          if (sheetContext.mounted) showSnack(sheetContext, errorText(e));
        }
      },
    ),
  );
  if (done != null && context.mounted) showSnack(context, done);
  return done != null;
}

/// Move an accepted submission to another case.
Future<bool> moveToCase(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  final done = await showAdminSheet<String>(
    context,
    title: 'Move ${submission.reference} to...',
    builder: (sheetContext) => CasePicker(
      service: service,
      excludeCaseId: submission.caseId,
      onSelected: (target) => _addToCase(
          sheetContext, service, submission, target.caseId, target.reference),
    ),
  );
  if (done != null && context.mounted) showSnack(context, done);
  return done != null;
}

/// Remove from its case: back to the review queue.
Future<bool> removeFromCase(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  final ok = await confirmAction(
    context,
    title: 'Remove from ${submission.caseReference ?? 'case'}?',
    message: '${submission.reference} is not deleted: it goes back to '
        'Pending review with all its footage, and you can add it to a case '
        'again. Duplicates of it leave the case too.',
    confirmLabel: 'Remove',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  return _run(context, '${submission.reference} removed from the case',
      () => service.reopenSubmission(submission.incidentId));
}

/// Reopen a rejected / duplicate submission for review.
Future<bool> reopenSubmission(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  final ok = await confirmAction(
    context,
    title: 'Reopen ${submission.reference}?',
    message: 'It goes back to Pending review so you can decide again.',
    confirmLabel: 'Reopen',
  );
  if (!ok || !context.mounted) return false;
  return _run(context, '${submission.reference} is pending review again',
      () => service.reopenSubmission(submission.incidentId));
}

// ---------------------------------------------------------------------------

/// Runs [action]; shows [doneMessage] or the error. True when it worked.
Future<bool> _run(BuildContext context, String doneMessage,
    Future<void> Function() action) async {
  try {
    await action();
    if (context.mounted) showSnack(context, doneMessage);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return false;
  }
}

/// Adds the submission to a case, then closes the sheet with a message.
Future<void> _addToCase(BuildContext sheetContext, SupabaseService service,
    CrimeSceneSummary submission, int caseId, String caseReference) async {
  try {
    await service.addIncidentsToCase(caseId, [submission.incidentId]);
    if (sheetContext.mounted) {
      Navigator.pop(
          sheetContext, '${submission.reference} added to $caseReference');
    }
  } catch (e) {
    if (sheetContext.mounted) showSnack(sheetContext, errorText(e));
  }
}

/// "INC-0042" or "3 submissions".
String _what(List<CrimeSceneSummary> submissions) => submissions.length == 1
    ? submissions.first.reference
    : '${submissions.length} submissions';

/// The Accept panel: suggested cases first, then "New case" or "Existing
/// case", then the form or the case list. The case list has a "not
/// listed? create it" button that creates the case and opens its page.
class _AcceptChoice extends StatefulWidget {
  final SupabaseService service;
  final List<CrimeSceneSummary> submissions;

  const _AcceptChoice({required this.service, required this.submissions});

  @override
  State<_AcceptChoice> createState() => _AcceptChoiceState();
}

enum _AcceptMode { choose, newCase, existingCase, newCaseThenOpen }

class _AcceptChoiceState extends State<_AcceptChoice> {
  _AcceptMode _mode = _AcceptMode.choose;

  /// Suggested cases (with their details) for the first submission.
  late final Future<List<(CaseSuggestion, CaseSummary)>> _suggestions =
      _loadSuggestions();

  Future<List<(CaseSuggestion, CaseSummary)>> _loadSuggestions() async {
    try {
      final found = await widget.service
          .suggestCasesForIncident(widget.submissions.first.incidentId);
      final cases =
          await Future.wait(found.map((f) => widget.service.getCase(f.caseId)));
      return [
        for (var i = 0; i < found.length; i++)
          if (cases[i] != null) (found[i], cases[i]!),
      ];
    } catch (_) {
      return const []; // suggestions are a bonus; never block accepting
    }
  }

  List<int> get _ids => [for (final s in widget.submissions) s.incidentId];

  Future<void> _addTo(int caseId, String reference) async {
    try {
      await widget.service.addIncidentsToCase(caseId, _ids);
      if (mounted) {
        Navigator.pop(
            context,
            _AcceptResult(
                '${_what(widget.submissions)} added to $reference', caseId));
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _create(String title, String description,
      {required bool open}) async {
    final caseId = await widget.service.createCase(
      title: title,
      description: description,
      incidentIds: _ids,
    );
    if (mounted) {
      Navigator.pop(
          context,
          _AcceptResult(
              '${_what(widget.submissions)} added to new case '
              '${caseReference(caseId)}',
              caseId,
              openCase: open));
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.submissions.first;
    switch (_mode) {
      case _AcceptMode.choose:
        return ListView(
          children: [
            Text(
              widget.submissions.length == 1
                  ? first.location
                  : widget.submissions.map((s) => s.reference).join(', '),
              style: AppText.bodyMuted,
            ),
            const SizedBox(height: AppSpacing.medium),
            FutureBuilder<List<(CaseSuggestion, CaseSummary)>>(
              future: _suggestions,
              builder: (context, snap) {
                final items = snap.data ?? const [];
                if (items.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('SUGGESTED CASES',
                        style:
                            AppText.caption.copyWith(color: AppColors.textHint)),
                    const SizedBox(height: 6),
                    for (final (suggestion, c) in items) ...[
                      SuggestionTile(
                        title: '${c.reference} · ${c.title}',
                        score: suggestion.score,
                        reasons: [
                          ...suggestion.reasons,
                          'matches ${incidentReference(suggestion.matchedIncidentId)}',
                        ],
                        actionLabel: 'Add',
                        onAction: () => _addTo(c.caseId, c.reference),
                      ),
                      const SizedBox(height: AppSpacing.small),
                    ],
                    const SizedBox(height: AppSpacing.small),
                  ],
                );
              },
            ),
            _ChoiceTile(
              icon: Icons.create_new_folder_outlined,
              title: 'Create a new case',
              subtitle: widget.submissions.length == 1
                  ? 'Start a new investigation with this incident in it.'
                  : 'Start a new investigation with these submissions in it.',
              onTap: () => setState(() => _mode = _AcceptMode.newCase),
            ),
            const SizedBox(height: AppSpacing.small),
            _ChoiceTile(
              icon: Icons.folder_open,
              title: 'Add to an existing case',
              subtitle: 'For example, another report of the same robbery.',
              onTap: () => setState(() => _mode = _AcceptMode.existingCase),
            ),
          ],
        );
      case _AcceptMode.newCase:
      case _AcceptMode.newCaseThenOpen:
        final open = _mode == _AcceptMode.newCaseThenOpen;
        return NewCaseForm(
          initialTitle: first.location,
          initialDescription: first.description ?? '',
          buttonLabel: open
              ? 'Create case and open it'
              : 'Create case with ${_what(widget.submissions)}',
          onCreate: (title, description) =>
              _create(title, description, open: open),
        );
      case _AcceptMode.existingCase:
        return CasePicker(
          service: widget.service,
          onSelected: (c) => _addTo(c.caseId, c.reference),
          onNotListed: () =>
              setState(() => _mode = _AcceptMode.newCaseThenOpen),
        );
    }
  }
}

/// A suggestion: title, how strong the match is, why, and one action.
class SuggestionTile extends StatelessWidget {
  final String title;
  final int score;
  final List<String> reasons;
  final String actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onTap;

  const SuggestionTile({
    super.key,
    required this.title,
    required this.score,
    required this.reasons,
    required this.actionLabel,
    this.onAction,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      onTap: onTap,
      borderColor: AppColors.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined,
                  color: AppColors.success, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 6),
              SmallActionButton(
                  label: actionLabel,
                  color: AppColors.success,
                  onPressed: onAction),
            ],
          ),
          const SizedBox(height: 6),
          Text(suggestionStrength(score).toUpperCase(),
              style: AppText.caption.copyWith(color: AppColors.success)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final r in reasons) FactChip(r)],
          ),
        ],
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.header,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
        child: ListTile(
        leading: Icon(icon, color: AppColors.accent, size: 30),
        title: Text(title,
            style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: AppText.bodyMuted),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
      ),
    );
  }
}
