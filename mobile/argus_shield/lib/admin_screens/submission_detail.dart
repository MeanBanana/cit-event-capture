// submission_detail.dart — full page for one submission (opened with View
// or by tapping a submission card).
//
// Shows everything about the incident: the citizen's description, the
// AI SUMMARY with each person / vehicle / weapon the AI found under it
// (each with View crops -> its pictures), each clip with what the AI saw in it (View -> play
// the video / open the photo), and the admin's review, with the actions that
// fit its review status:
//   pending            Reject · Duplicate · Accept
//   accepted (in case) Open case · Move to another case · Remove from case
//   rejected           Reopen for review · Delete (for good)
//   duplicate          Reopen for review

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/submissions.dart'
    show AiFactChips, WhenLines;
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/admin_screens/case_evidence_section.dart';
import 'package:argus_shield/admin_screens/footage_list.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/submission_evidence_source.dart';

class SubmissionDetailPage extends StatefulWidget {
  final CrimeSceneSummary submission;

  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  /// Where the AI's people / vehicles / weapons of this submission come
  /// from. The app uses SubmissionEvidenceSource; a test that passes a FAKE
  /// service gets no AI section unless it passes a source here too.
  final CaseEvidenceSource? evidenceSource;

  const SubmissionDetailPage({
    super.key,
    required this.submission,
    this.service,
    this.evidenceSource,
  });

  @override
  State<SubmissionDetailPage> createState() => _SubmissionDetailPageState();
}

class _SubmissionDetailPageState extends State<SubmissionDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  late CrimeSceneSummary _s = widget.submission;
  late final CaseEvidenceSource? _evidence = widget.evidenceSource ??
      (usesRealDatabase(widget.service) ? SubmissionEvidenceSource() : null);

  /// Changes after a refresh, so the AI section loads again.
  int _evidenceVersion = 0;

  /// Fetches this incident again after an action changed it.
  Future<void> _refresh() async {
    try {
      final fresh = await _service.getSubmission(_s.incidentId);
      if (mounted && fresh != null) {
        setState(() {
          _s = fresh;
          _evidenceVersion++; // reload the clips and what the AI found
        });
      }
    } catch (_) {
      // keep showing the old details; the list reloads when going back
    }
  }

  /// Runs one of the review actions (each shows its own panel / dialog
  /// and message), then refreshes the page.
  Future<void> _act(ReviewAction action) async {
    final changed = await action(context, _service, _s);
    if (changed) await _refresh();
  }

  /// Deletes a rejected submission for good, then leaves this page (the
  /// list reloads when it shows again).
  Future<void> _delete() async {
    final deleted = await deleteSubmission(context, _service, _s);
    if (deleted && mounted) Navigator.pop(context);
  }

  Future<void> _openCase() async {
    final caseId = _s.caseId;
    if (caseId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CaseDetailPage(caseId: caseId, service: _service),
      ),
    );
    await _refresh(); // the case page may have moved / removed it
  }

  Future<void> _openOriginal() async {
    final originalId = _s.duplicateOf;
    if (originalId == null) return;
    try {
      final original = await _service.getSubmission(originalId);
      if (!mounted) return;
      if (original == null) {
        showSnack(context, 'Could not find ${incidentReference(originalId)}.');
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SubmissionDetailPage(submission: original, service: _service),
        ),
      );
      await _refresh();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final (statusLabel, statusColor) = statusStyle(s.status);
    final (reviewLabel, reviewColor) = reviewStyle(s.reviewStatus);

    return Scaffold(
      appBar: const ArgusAppBar(roleLabel: 'Admin'),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          Text(s.reference, style: AppText.sectionTitle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusTag(label: reviewLabel, color: reviewColor),
              StatusTag(label: statusLabel, color: statusColor),
            ],
          ),
          if (s.attackType != null) ...[
            const SizedBox(height: 8),
            Text(s.attackType!.toUpperCase(),
                style: AppText.caption.copyWith(fontSize: 13)),
          ],

          // ---- The incident ----------------------------------------------
          const SectionLabel('Incident'),
          DetailLine(icon: Icons.location_on_outlined, text: s.location),
          WhenLines(submission: s),
          if (s.dateReported != null)
            DetailLine(
                icon: Icons.upload_outlined,
                text: 'Reported ${formatDateTime(s.dateReported!)}'),
          DetailLine(
              icon: Icons.person_outline, text: 'Reported by ${s.reporterName}'),
          DetailLine(
            icon: Icons.perm_media_outlined,
            text: '${s.mediaCount} media '
                '${s.mediaCount == 1 ? 'file' : 'files'}',
          ),
          if (s.hasGps)
            DetailLine(
              icon: Icons.gps_fixed,
              text: 'GPS ${s.latitude!.toStringAsFixed(5)}, '
                  '${s.longitude!.toStringAsFixed(5)}',
            ),

          // ---- What the citizen reported --------------------------------------
          if (_evidence == null) ...[
            // (tests with a fake service: the plain descriptions)
            const SectionLabel('Descriptions'),
            SubmissionDescriptions(
              citizen: s.description,
              ai: s.aiSummary,
              aiStatus: s.aiSummaryStatus,
              mediaCount: s.mediaCount,
            ),
            if (s.hasAiFacts) ...[
              const SizedBox(height: 8),
              AiFactChips(submission: s),
            ],
          ] else ...[
            const SectionLabel('Description'),
            SubmissionDescriptions(
              citizen: s.description,
              ai: s.aiSummary,
              showAi: false,
            ),

            // ---- AI summary: the text, then each person / vehicle / weapon
            //      with View crops (like the pipeline's console output) -------
            CaseEvidenceSection(
              key: ValueKey('evidence-${s.incidentId}-$_evidenceVersion'),
              caseId: s.incidentId,
              source: _evidence,
              title: 'AI summary',
              summary: s.aiSummary ?? '',
              summaryNote: _aiNote(s),
              belowSummary: s.hasAiFacts ? AiFactChips(submission: s) : null,
              perSubmission: true,
              emptyText: s.mediaCount == 0
                  ? 'No footage was sent with this report.'
                  : s.aiSummaryStatus == 'processing' || s.aiSummaryStatus == 'pending'
                      ? 'The AI is still analysing the footage. Come back shortly.'
                      : 'The AI found no people, vehicles or weapons in this footage.',
            ),
          ],

          // ---- Each clip, with View (play the video / open the photo) -------
          if (s.mediaCount > 0) ...[
            const SectionLabel('Footage'),
            FootageList(
              key: ValueKey('footage-${s.incidentId}-$_evidenceVersion'),
              service: _service,
              incidentId: s.incidentId,
              reference: s.reference,
            ),
          ],

          // ---- The review --------------------------------------------------
          const SectionLabel('Review'),
          ..._reviewDetails(s),

          const SizedBox(height: AppSpacing.medium),
          ..._actions(s),
        ],
      ),
    );
  }

  /// "AI analysis in progress… · Written 12 Oct 2026 19:42" (null if none).
  String? _aiNote(CrimeSceneSummary s) {
    final parts = [
      aiStatusNote(s.aiSummaryStatus,
          hasSummary: s.aiSummary != null, mediaCount: s.mediaCount),
      if (s.aiSummaryAt != null) 'Written ${formatDateTime(s.aiSummaryAt!)}',
    ].whereType<String>();
    return parts.isEmpty ? null : parts.join(' · ');
  }

  List<Widget> _reviewDetails(CrimeSceneSummary s) {
    final when = s.reviewedAt == null ? '' : ' on ${formatDateTime(s.reviewedAt!)}';
    switch (s.reviewStatus) {
      case 'accepted':
        return [
          DetailLine(
            icon: Icons.folder_open,
            text: 'In ${s.caseReference}'
                '${s.caseTitle == null ? '' : ' · ${s.caseTitle}'}$when',
            color: AppColors.success,
          ),
        ];
      case 'rejected':
        return [
          DetailLine(
              icon: Icons.block, text: 'Rejected$when', color: AppColors.danger),
          if (s.reviewNote != null)
            DetailLine(icon: Icons.notes, text: 'Reason: ${s.reviewNote}'),
        ];
      case 'duplicate':
        return [
          DetailLine(
            icon: Icons.copy_all,
            text: 'Duplicate of ${incidentReference(s.duplicateOf!)}$when'
                '${s.caseReference == null ? '' : ' · in ${s.caseReference}'}',
          ),
        ];
      default:
        return const [
          DetailLine(
            icon: Icons.hourglass_empty,
            text: 'Waiting for an admin to accept, reject or mark it '
                'as a duplicate.',
          ),
        ];
    }
  }

  List<Widget> _actions(CrimeSceneSummary s) {
    Widget row(List<Widget> buttons) => Row(
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.small),
              Expanded(child: buttons[i]),
            ],
          ],
        );

    switch (s.reviewStatus) {
      case 'pending':
        return [
          row([
            SmallActionButton(
                label: 'Reject',
                color: AppColors.danger,
                onPressed: () => _act(rejectSubmission)),
            SmallActionButton(
                label: 'Duplicate',
                color: AppColors.neutral,
                onPressed: () => _act(markAsDuplicate)),
            SmallActionButton(
                label: 'Accept',
                color: AppColors.success,
                onPressed: () => _act(acceptSubmission)),
          ]),
        ];
      case 'accepted':
        return [
          row([
            SmallActionButton(
                label: 'Open ${s.caseReference}',
                color: AppColors.accent,
                onPressed: _openCase),
          ]),
          const SizedBox(height: AppSpacing.small),
          row([
            SmallActionButton(
                label: 'Move to another case',
                color: AppColors.neutral,
                onPressed: () => _act(moveToCase)),
            SmallActionButton(
                label: 'Remove from case',
                color: AppColors.danger,
                onPressed: () => _act(removeFromCase)),
          ]),
        ];
      default: // rejected / duplicate
        return [
          if (s.isDuplicate) ...[
            row([
              SmallActionButton(
                  label: 'View ${incidentReference(s.duplicateOf!)}',
                  color: AppColors.accent,
                  onPressed: _openOriginal),
            ]),
            const SizedBox(height: AppSpacing.small),
          ],
          row([
            SmallActionButton(
                label: 'Reopen for review',
                color: AppColors.accent,
                onPressed: () => _act(reopenSubmission)),
          ]),
          if (s.isRejected) ...[
            const SizedBox(height: AppSpacing.small),
            row([
              SmallActionButton(
                  key: const ValueKey('delete-submission'),
                  label: 'Delete submission',
                  color: AppColors.danger,
                  onPressed: _delete),
            ]),
          ],
        ];
    }
  }
}
