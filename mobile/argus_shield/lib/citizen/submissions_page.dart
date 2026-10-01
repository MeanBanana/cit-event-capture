// submissions_page.dart — live session report list and its card helper.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'citizen_store.dart';

/// Builds report cards from the shared store rather than fixed sample records.
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
        return ListView(
          padding: AppSpacing.page,
          children: [
            const Text('My submissions', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.small),
            const Text(
              'Track the reports you have submitted to Argus Shield.',
              style: AppText.bodyMuted,
            ),
            const SizedBox(height: AppSpacing.large),
            // An empty state is shown until the citizen adds the first report.
            if (submissions.isEmpty)
              const Text('No reports added yet.', style: AppText.bodyMuted),
            // ... inserts each card and spacing widget into the children list.
            for (final submission in submissions) ...[
              SubmissionCard(
                reference: submission.reference,
                location: submission.location,
                date: _formatDate(submission.createdAt),
                status: 'Draft demo',
                statusColor: AppColors.accent,
                description: '${submission.description}\n\n'
                    'File: ${submission.attachment.name}',
              ),
              const SizedBox(height: AppSpacing.medium),
            ],
          ],
        );
      },
    );
  }

  /// Formats the creation date for display without another package.
  String _formatDate(DateTime date) =>
      '${date.day}/${date.month}/${date.year}';
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
              Expanded(child: Text(reference, style: AppText.cardTitle)),
              Text(
                status.toUpperCase(),
                style: AppText.caption.copyWith(color: statusColor),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            location,
            style: AppText.body.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(date, style: AppText.bodyMuted),
          const SizedBox(height: 12),
          Text(description, style: AppText.bodyMuted),
        ],
      ),
    );
  }
}
