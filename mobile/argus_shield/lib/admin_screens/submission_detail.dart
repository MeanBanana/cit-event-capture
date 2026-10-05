// submission_detail.dart — full page for one submission (opened with View
// or by tapping a submission card).
//
// Shows everything about the incident and the admin's review, with the
// actions that fit its review status:
//   pending            Reject · Duplicate · Accept
//   accepted (in case) Open case · Move to another case · Remove from case
//   rejected/duplicate Reopen for review

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';

class SubmissionDetailPage extends StatefulWidget {
  final CrimeSceneSummary submission;

  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const SubmissionDetailPage({
    super.key,
    required this.submission,
    this.service,
  });

  @override
  State<SubmissionDetailPage> createState() => _SubmissionDetailPageState();
}

class _SubmissionDetailPageState extends State<SubmissionDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  late CrimeSceneSummary _s = widget.submission;

  /// Fetches this incident again after an action changed it.
  Future<void> _refresh() async {
    try {
      final rows = await _service.searchSubmissions(
          _s.incidentId.toString(), limit: 100);
      final fresh = rows.where((r) => r.incidentId == _s.incidentId);
      if (mounted && fresh.isNotEmpty) setState(() => _s = fresh.first);
    } catch (_) {
      // keep showing the old details; the list reloads when going back
    }
  }

  /// Runs one of the review actions (each shows its own panel / dialog
  /// and message), then refreshes the page.
  Future<void> _act(
      Future<bool> Function(BuildContext, SupabaseService, CrimeSceneSummary)
          action) async {
    final changed = await action(context, _service, _s);
    if (changed) await _refresh();
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
      final rows = await _service.searchSubmissions(originalId.toString(),
          limit: 100);
      final original = rows.where((r) => r.incidentId == originalId);
      if (!mounted) return;
      if (original.isEmpty) {
        showSnack(context, 'Could not find ${incidentReference(originalId)}.');
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SubmissionDetailPage(
              submission: original.first, service: _service),
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
          DetailLine(
              icon: Icons.schedule,
              text: 'Happened ${formatDateTime(s.dateTime)}'),
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
          if (s.description != null) ...[
            const SizedBox(height: 4),
            Text(s.description!, style: AppText.body),
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
                color: AppColors.textMuted,
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
                color: AppColors.textMuted,
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
        ];
    }
  }
}
