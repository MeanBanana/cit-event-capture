// submissions_page.dart — the citizen's own reports, from Supabase, with
// where each one is: received / added to a case, and whether its footage has
// been analysed. Pull down to refresh. Citizens never see the AI's findings
// (other people's faces and number plates) - only that it was analysed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../app_settings.dart';
import 'citizen_store.dart';

/// Lists the citizen's reports from the shared store.
class SubmissionsPage extends StatefulWidget {
  final CitizenStore store;

  const SubmissionsPage({super.key, required this.store});

  @override
  State<SubmissionsPage> createState() => _SubmissionsPageState();
}

class _SubmissionsPageState extends State<SubmissionsPage>
    with AutomaticKeepAliveClientMixin<SubmissionsPage> {
  String _query = '';
  String? _status;
  CitizenStore get store => widget.store;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Rebuild this content when CitizenStore calls notifyListeners().
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final all = store.submissions;
        final statuses = all.map((s) => s.statusLabel).toSet().toList()..sort();
        final submissions = all.where((s) {
          final text = '${s.reference} ${s.location} ${s.description ?? ''}'
              .toLowerCase();
          return (_status == null || s.statusLabel == _status) &&
              text.contains(_query);
        }).toList();
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
              const SizedBox(height: AppSpacing.medium),
              TextField(
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: const InputDecoration(
                  hintText: 'Search reference, location or description',
                  prefixIcon: Icon(Icons.search, color: AppColors.accent),
                ),
              ),
              const SizedBox(height: AppSpacing.small),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: Text('All (${all.length})'),
                    selected: _status == null,
                    onSelected: (_) => setState(() => _status = null),
                  ),
                  for (final status in statuses)
                    ChoiceChip(
                      label: Text(status),
                      selected: _status == status,
                      onSelected: (selected) =>
                          setState(() => _status = selected ? status : null),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.medium),
              if (store.submissionsLoading && all.isNotEmpty)
                const LinearProgressIndicator(),
              if (all.isNotEmpty && submissions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'No reports match your search or filter.',
                    style: AppText.bodyMuted,
                  ),
                ),
              if (store.submissionsLoading && all.isEmpty)
                const Center(child: CircularProgressIndicator()),
              if (store.submissionsError != null) ...[
                Text(
                  store.submissionsError!,
                  style: AppText.body.copyWith(color: AppColors.danger),
                ),
                TextButton(
                  onPressed: store.loadSubmissions,
                  child: const Text('Try again'),
                ),
                const SizedBox(height: AppSpacing.medium),
              ],
              // An empty state is shown until the citizen sends the first report.
              if (!store.submissionsLoading &&
                  store.submissionsError == null &&
                  all.isEmpty)
                Text(
                  appSettings.t('noReportsYet'),
                  style: mutedOnPage(context),
                ),
              for (final s in submissions) ...[
                SubmissionCard(
                  reference: s.reference,
                  location: s.location,
                  date: s.reportedAt == null
                      ? ''
                      : _formatDate(s.reportedAt!.toLocal()),
                  status: s.statusLabel,
                  statusColor: switch (s.reviewStatus) {
                    'accepted' => AppColors.success,
                    'rejected' || 'duplicate' => AppColors.textHint,
                    _ => AppColors.accent,
                  },
                  description: [
                    if ((s.description ?? '').isNotEmpty) s.description!,
                    '${s.fileCount} file${s.fileCount == 1 ? '' : 's'} · ${s.aiLabel}',
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
                child: SelectableText(
                  reference,
                  style: titleOnPage(context).copyWith(fontSize: 18),
                ),
              ),
              IconButton(
                tooltip: 'Copy reference',
                icon: const Icon(Icons.copy, size: 18, color: AppColors.accent),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: reference));
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reference copied')),
                  );
                },
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
