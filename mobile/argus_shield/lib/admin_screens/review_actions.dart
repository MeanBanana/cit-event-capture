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
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';

/// Accept: put the submission in a NEW case or an EXISTING one.
Future<bool> acceptSubmission(
  BuildContext context,
  SupabaseService service,
  CrimeSceneSummary submission,
) async {
  final done = await showAdminSheet<String>(
    context,
    title: 'Accept ${submission.reference}',
    builder: (sheetContext) =>
        _AcceptChoice(service: service, submission: submission),
  );
  if (done != null && context.mounted) showSnack(context, done);
  return done != null;
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
    message: '${submission.reference} goes back to Pending review. '
        'Duplicates of it leave the case too.',
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

/// The Accept panel: first "New case" or "Existing case", then the form
/// or the case list.
class _AcceptChoice extends StatefulWidget {
  final SupabaseService service;
  final CrimeSceneSummary submission;

  const _AcceptChoice({required this.service, required this.submission});

  @override
  State<_AcceptChoice> createState() => _AcceptChoiceState();
}

enum _AcceptMode { choose, newCase, existingCase }

class _AcceptChoiceState extends State<_AcceptChoice> {
  _AcceptMode _mode = _AcceptMode.choose;

  @override
  Widget build(BuildContext context) {
    final s = widget.submission;
    switch (_mode) {
      case _AcceptMode.choose:
        return ListView(
          children: [
            Text(s.location, style: AppText.bodyMuted),
            const SizedBox(height: AppSpacing.medium),
            _ChoiceTile(
              icon: Icons.create_new_folder_outlined,
              title: 'Create a new case',
              subtitle: 'Start a new investigation with this incident in it.',
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
        return NewCaseForm(
          initialTitle: s.location,
          initialDescription: s.description ?? '',
          buttonLabel: 'Create case with ${s.reference}',
          onCreate: (title, description) async {
            final caseId = await widget.service.createCase(
              title: title,
              description: description,
              incidentIds: [s.incidentId],
            );
            if (context.mounted) {
              Navigator.pop(context,
                  '${s.reference} added to new case CASE-${caseId.toString().padLeft(4, '0')}');
            }
          },
        );
      case _AcceptMode.existingCase:
        return CasePicker(
          service: widget.service,
          onSelected: (c) =>
              _addToCase(context, widget.service, s, c.caseId, c.reference),
        );
    }
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
      child: ListTile(
        leading: Icon(icon, color: AppColors.accent, size: 30),
        title: Text(title,
            style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: AppText.bodyMuted),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
    );
  }
}
