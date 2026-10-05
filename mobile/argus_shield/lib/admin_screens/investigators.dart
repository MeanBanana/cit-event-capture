// investigators.dart — System Administrator view of every investigator.
//
// Shows a search bar (name or badge number) and a
// scrollable list of investigator cards.
//
// For now the list holds ONE hard-coded sample investigator so the layout can
// be reviewed. When the Supabase fetch is ready, replace `_investigators`
// with the rows returned from SupabaseService — the search and cards will
// keep working unchanged because they only read from that list.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// One investigator as the card needs it.
///
/// Field names follow the database: public."User" (firstname, surname,
/// email, phonenumber) joined with public.investigator (rank, badgenumber,
/// station, unit, dutystatus).
class InvestigatorSummary {
  final int userId;
  final String firstName;
  final String surname;
  final String? rank; // e.g. 'Sgt.' — nullable in the database
  final String badgeNumber; // e.g. 'JHB-4471'
  final String station; // e.g. 'Kempton Park SAPS'
  final String? unit; // e.g. 'CIT Task Force' — nullable in the database
  final String dutyStatus; // 'on_duty' | 'available' | 'off_duty'
  final String email;
  final String? phoneNumber;
  final int activeCases; // count of active rows in caseassignment

  const InvestigatorSummary({
    required this.userId,
    required this.firstName,
    required this.surname,
    this.rank,
    required this.badgeNumber,
    required this.station,
    this.unit,
    required this.dutyStatus,
    required this.email,
    this.phoneNumber,
    this.activeCases = 0,
  });

  String get fullName => '$firstName $surname';

  /// "Sgt. Thabo Mokoena", or just the name when no rank is stored.
  String get displayName => rank == null ? fullName : '$rank $fullName';
}

/// Body of the Investigators tab. Like the citizen pages, it has no Scaffold
/// or header of its own — AdminDashboard draws those.
class Investigators extends StatefulWidget {
  const Investigators({super.key});

  @override
  State<Investigators> createState() => _InvestigatorsState();
}

class _InvestigatorsState extends State<Investigators> {
  final _searchController = TextEditingController();
  String _query = '';

  // Sample data only — swap for the Supabase results later.
  final List<InvestigatorSummary> _investigators = const [
    InvestigatorSummary(
      userId: 1,
      firstName: 'Thabo',
      surname: 'Mokoena',
      rank: 'Sgt.',
      badgeNumber: 'JHB-4471',
      station: 'Kempton Park SAPS',
      unit: 'CIT Task Force',
      dutyStatus: 'on_duty',
      email: 'thabo.mokoena@saps.gov.za',
      phoneNumber: '082 555 0147',
      activeCases: 3,
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Investigators whose name or badge number contains the search text.
  /// Case-insensitive, so "jhb" finds "JHB-4471" and "thabo" finds "Thabo".
  List<InvestigatorSummary> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _investigators;
    return _investigators.where((inv) {
      return inv.fullName.toLowerCase().contains(q) ||
          inv.badgeNumber.toLowerCase().contains(q);
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
          const Text('Investigators', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.small),
          const Text(
            'Search and review every investigator registered on Argus Shield.',
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
              hintText: 'Search by name/badge number',
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
            '${results.length} of ${_investigators.length} investigators',
            style: AppText.caption.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.medium),

          // Only the list scrolls; the title and search bar stay in place.
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text(
                      'No investigators match your search.',
                      style: AppText.bodyMuted,
                    ),
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.medium),
                    itemBuilder: (context, index) =>
                        InvestigatorCard(investigator: results[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One investigator's details. Styled like SubmissionCard on the citizen side
/// (outlined box, Courier title, small coloured status tag).
class InvestigatorCard extends StatelessWidget {
  final InvestigatorSummary investigator;

  const InvestigatorCard({super.key, required this.investigator});

  /// Database value → label and colour for the status tag.
  static (String, Color) _status(String dutyStatus) {
    switch (dutyStatus) {
      case 'on_duty':
        return ('On duty', AppColors.success);
      case 'available':
        return ('Available', AppColors.accent);
      case 'off_duty':
        return ('Off duty', AppColors.textHint);
      default:
        return (dutyStatus, AppColors.textMuted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = investigator;
    final (statusLabel, statusColor) = _status(inv.dutyStatus);

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
          // Name + duty status
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(inv.displayName, style: AppText.cardTitle),
              ),
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
          const SizedBox(height: 6),
          Text(
            'BADGE ${inv.badgeNumber}',
            style: AppText.caption.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.fieldBorder, height: 1),
          const SizedBox(height: 12),

          _DetailRow(icon: Icons.location_city, text: inv.station),
          if (inv.unit != null)
            _DetailRow(icon: Icons.groups, text: inv.unit!),
          _DetailRow(icon: Icons.email_outlined, text: inv.email),
          if (inv.phoneNumber != null)
            _DetailRow(icon: Icons.phone_outlined, text: inv.phoneNumber!),
          _DetailRow(
            icon: Icons.folder_open,
            text: '${inv.activeCases} active '
                '${inv.activeCases == 1 ? 'case' : 'cases'}',
          ),
        ],
      ),
    );
  }
}

/// Icon + text line used inside InvestigatorCard.
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(child: Text(text, style: AppText.bodyMuted)),
        ],
      ),
    );
  }
}
