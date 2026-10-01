// submissions_page.dart — live session report list and its card helper.

import 'package:flutter/material.dart';
import 'citizen_store.dart';
import 'app_styles.dart';

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
          padding: const EdgeInsets.fromLTRB(22, 25, 22, 35),
          children: [
            const Text(
              'MY SUBMISSIONS',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Track the reports you have submitted to Argus Shield.',
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 24),
            // An empty state is shown until the citizen adds the first report.
            if (submissions.isEmpty)
              const Text(
                'No reports added yet.',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            // ... inserts each card and spacing widget into the children list.
            for (final submission in submissions) ...[
              SubmissionCard(
                reference: submission.reference,
                location: submission.location,
                date: _formatDate(submission.createdAt),
                status: 'Draft demo',
                statusColor: argusGold,
                description: '${submission.description}\n\n'
                    'File: ${submission.attachment.name}',
              ),
              const SizedBox(height: 14),
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
        color: argusField,
        border: Border.all(color: argusBorder, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  reference,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                status,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            location,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(date, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(color: Colors.white70, height: 1.3),
          ),
        ],
      ),
    );
  }
}
