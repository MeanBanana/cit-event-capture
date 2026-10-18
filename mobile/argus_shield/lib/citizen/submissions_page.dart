// submissions_page.dart — the citizen's own reports, from Supabase, with
// where each one is: received / added to a case, and whether its footage has
// been analysed. Pull down to refresh. Citizens never see the AI's findings
// (other people's faces and number plates) - only that it was analysed.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../app_settings.dart';
import 'citizen_store.dart';

/// Lists the citizen's reports from the shared store.
class SubmissionsPage extends StatelessWidget {
  final CitizenStore store;

  const SubmissionsPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    // Rebuild this content when CitizenStore calls notifyListeners().
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final submissions = store.submissions;
        return RefreshIndicator(
          onRefresh: store.loadSubmissions,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppSpacing.page,
            children: [
              Text(appSettings.t('mySubmissions'), style: titleOnPage(context)),
              const SizedBox(height: AppSpacing.small),
              Text(
                appSettings.t('submissionsTrack'),
                style: mutedOnPage(context),
              ),
              const SizedBox(height: AppSpacing.large),
              if (store.submissionsLoading && submissions.isEmpty)
                const Center(child: CircularProgressIndicator()),
              if (store.submissionsError != null) ...[
                Text(store.submissionsError!,
                    style: AppText.body.copyWith(color: AppColors.danger)),
                TextButton(
                  onPressed: store.loadSubmissions,
                  child: Text(appSettings.t('tryAgain')),
                ),
                const SizedBox(height: AppSpacing.medium),
              ],
              // An empty state is shown until the citizen sends the first report.
              if (!store.submissionsLoading &&
                  store.submissionsError == null &&
                  submissions.isEmpty)
                Text(appSettings.t('noReportsYet'), style: mutedOnPage(context)),
              for (final s in submissions) ...[
                SubmissionCard(
                  reference: s.reference,
                  location: s.location,
                  date: s.reportedAt == null ? '' : _formatDate(s.reportedAt!),
                  status: s.statusLabel,
                  statusColor: switch (s.reviewStatus) {
                    'accepted' => AppColors.success,
                    'rejected' || 'duplicate' => AppColors.textHint,
                    _ => AppColors.accent,
                  },
                  description: [
                    if ((s.description ?? '').isNotEmpty) s.description!,
                    '${s.fileCount} ${s.fileCount == 1 ? appSettings.t('fileOne') : appSettings.t('fileMany')} · ${s.aiLabel}',
                  ].join('\n\n'),
                ),
                const SizedBox(height: AppSpacing.medium),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 12/10/2026 19:42 — formatted without another package.
  String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.day}/${date.month}/${date.year} ${two(date.hour)}:${two(date.minute)}';
  }
}

/// Reusable presentation widget for one report; it does not modify stored data.
class SubmissionCard extends StatelessWidget {
  final String reference;
  final String location;
  final String date;
  final String status;
  final Color statusColor;
  final String description;

  const SubmissionCard({
    super.key,
    required this.reference,
    required this.location,
    required this.date,
    required this.status,
    required this.statusColor,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(reference, style: titleOnPage(context).copyWith(fontSize: 18)),
              ),
              Flexible(
                child: Text(
                  status.toUpperCase(),
                  textAlign: TextAlign.right,
                  style: AppText.caption.copyWith(color: statusColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            location,
            style: bodyOnPage(context).copyWith(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(date, style: mutedOnPage(context)),
          const SizedBox(height: 12),
          Text(description, style: mutedOnPage(context)),
        ],
      ),
    );
  }
}
