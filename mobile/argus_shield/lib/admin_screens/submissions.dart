// submissions.dart — System Administrator view of every reported incident.
//
// Same layout as investigators.dart: a search bar and a
// scrollable list of cards.
//
// For now the list holds ONE hard-coded sample incident so the layout can be
// reviewed. When the Supabase fetch is ready, replace `_submissions` with the
// rows returned from SupabaseService — the search and cards keep working
// unchanged because they only read from that list.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// One reported incident as the card needs it.
///
/// Field names follow public.crimescene (incidentid, location, datetime,
/// attacktype, status, description, reportedby). The reporter's name comes
/// from public."User" via reportedby, and the media count from public.media.
class CrimeSceneSummary {
  final int incidentId;
  final String location;
  final DateTime dateTime; // when the incident happened
  final String? attackType; // nullable in the database
  final String status; // 'open' | 'under_review' | 'closed'
  final String? description; // nullable in the database
  final int reportedBy; // User.userid
  final String reporterName; // User.firstname + surname
  final int mediaCount; // rows in media for this incident

  const CrimeSceneSummary({
    required this.incidentId,
    required this.location,
    required this.dateTime,
    this.attackType,
    required this.status,
    this.description,
    required this.reportedBy,
    required this.reporterName,
    this.mediaCount = 0,
  });

  /// Display reference, e.g. incident 42 → "INC-0042".
  String get reference => 'INC-${incidentId.toString().padLeft(4, '0')}';
}

/// Body of the Submissions tab. Like the citizen pages, it has no Scaffold
/// or header of its own — AdminDashboard draws those.
class AdminSubmissions extends StatefulWidget {
  const AdminSubmissions({super.key});

  @override
  State<AdminSubmissions> createState() => _AdminSubmissionsState();
}

class _AdminSubmissionsState extends State<AdminSubmissions> {
  final _searchController = TextEditingController();
  String _query = '';

  // Sample data only — swap for the Supabase results later.
  // Not const because DateTime(...) isn't a const constructor.
  final List<CrimeSceneSummary> _submissions = [
    CrimeSceneSummary(
      incidentId: 42,
      location: 'R21 Highway, near OR Tambo off-ramp, Kempton Park',
      dateTime: DateTime(2026, 9, 28, 14, 35),
      attackType: 'Vehicle ambush',
      status: 'open',
      description: 'Cash van forced off the road by two sedans. Armed suspects '
          'fled north with cash cases. Dashcam and phone footage submitted.',
      reportedBy: 7,
      reporterName: 'Lerato Dlamini',
      mediaCount: 3,
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Incidents whose reference, location or reporter contains the search
  /// text. Case-insensitive, and "42" matches "INC-0042".
  List<CrimeSceneSummary> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _submissions;
    return _submissions.where((s) {
      return s.reference.toLowerCase().contains(q) ||
          s.incidentId.toString() == q ||
          s.location.toLowerCase().contains(q) ||
          s.reporterName.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final results = _filtered;

    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Submissions', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.small),
          const Text(
            'Review every incident reported to Argus Shield.',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpacing.medium),

          // Search bar — borders and focus colour come from the app theme.
          TextField(
            controller: _searchController,
            style: AppText.body,
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Search by reference/location/reporter',
              prefixIcon: const Icon(Icons.search, color: AppColors.accent),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: AppColors.textMuted),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.small),
          Text(
            '${results.length} of ${_submissions.length} submissions',
            style: AppText.caption.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.medium),

          // Only the list scrolls; the title and search bar stay in place.
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text(
                      'No submissions match your search.',
                      style: AppText.bodyMuted,
                    ),
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.medium),
                    itemBuilder: (context, index) =>
                        CrimeSceneCard(submission: results[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One incident's details. Same style as InvestigatorCard.
class CrimeSceneCard extends StatelessWidget {
  final CrimeSceneSummary submission;

  const CrimeSceneCard({super.key, required this.submission});

  /// Database value → label and colour for the status tag.
  static (String, Color) _status(String status) {
    switch (status) {
      case 'open':
        return ('Open', AppColors.danger);
      case 'under_review':
        return ('Under review', AppColors.accent);
      case 'closed':
        return ('Closed', AppColors.success);
      default:
        return (status, AppColors.textMuted);
    }
  }

  /// 28/09/2026 14:35 — formatted without adding the intl package.
  static String _formatDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = submission;
    final (statusLabel, statusColor) = _status(s.status);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.header,
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reference + status
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(s.reference, style: AppText.cardTitle)),
              const SizedBox(width: AppSpacing.small),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: statusColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  statusLabel.toUpperCase(),
                  style: AppText.caption.copyWith(color: statusColor),
                ),
              ),
            ],
          ),
          if (s.attackType != null) ...[
            const SizedBox(height: 6),
            Text(
              s.attackType!.toUpperCase(),
              style: AppText.caption.copyWith(fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          const Divider(color: AppColors.fieldBorder, height: 1),
          const SizedBox(height: 12),

          _DetailRow(icon: Icons.location_on_outlined, text: s.location),
          _DetailRow(icon: Icons.schedule, text: _formatDateTime(s.dateTime)),
          _DetailRow(
            icon: Icons.person_outline,
            text: 'Reported by ${s.reporterName}',
          ),
          _DetailRow(
            icon: Icons.perm_media_outlined,
            text: '${s.mediaCount} media '
                '${s.mediaCount == 1 ? 'file' : 'files'}',
          ),

          if (s.description != null) ...[
            const SizedBox(height: 4),
            Text(s.description!, style: AppText.bodyMuted),
          ],
        ],
      ),
    );
  }
}

/// Icon + text line used inside CrimeSceneCard.
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(child: Text(text, style: AppText.bodyMuted)),
        ],
      ),
    );
  }
}
