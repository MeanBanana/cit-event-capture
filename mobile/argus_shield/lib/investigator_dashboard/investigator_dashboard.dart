import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/login.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'investigator_case_detail.dart';

/// Investigator landing page. Case visibility is enforced by database RLS:
/// the cases returned here are only cases assigned to the signed-in officer.
class InvestigatorDashboard extends StatefulWidget {
  final SupabaseService? service;

  const InvestigatorDashboard({super.key, this.service});

  @override
  State<InvestigatorDashboard> createState() => _InvestigatorDashboardState();
}

class _InvestigatorDashboardState extends State<InvestigatorDashboard> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  List<CaseSummary> _cases = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  bool _showClosed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cases = await _service.listCases(
        status: _showClosed ? null : 'active',
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _cases = cases;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load assigned cases. Pull down to try again.';
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    try {
      await _service.logout();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    } catch (error) {
      if (mounted) showSnack(context, errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleCases = _cases.where((c) {
      final query = _query.trim().toLowerCase();
      return query.isEmpty ||
          c.title.toLowerCase().contains(query) ||
          c.reference.toLowerCase().contains(query) ||
          c.plates.any((plate) => plate.toLowerCase().contains(query));
    }).toList();
    final reports = _cases.fold<int>(0, (sum, c) => sum + c.incidentCount);
    final possiblePeople =
        _cases.fold<int>(0, (sum, c) => sum + c.possibleSuspects);

    return Scaffold(
      appBar: RoleAppBar(
        roleLabel: 'Investigator',
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: AppSpacing.page,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text('Investigation dashboard', style: AppText.sectionTitle),
            const SizedBox(height: 4),
            const Text(
              'Assigned cash-in-transit investigations',
              style: AppText.bodyMuted,
            ),
            const SizedBox(height: AppSpacing.medium),
            _OperationalSummary(
              caseCount: _cases.where((c) => !c.isClosed).length,
              reportCount: reports,
              possiblePeople: possiblePeople,
            ),
            const SizedBox(height: AppSpacing.large),
            Row(
              children: [
                const Expanded(
                  child: Text('MY CASES', style: AppText.cardTitle),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _showClosed = !_showClosed);
                    _load();
                  },
                  icon: Icon(
                    _showClosed ? Icons.visibility_off : Icons.history,
                    size: 18,
                  ),
                  label: Text(_showClosed ? 'Active only' : 'Include closed'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.small),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search case, reference or number plate',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: AppSpacing.medium),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.medium),
                child: Text(
                  _error!,
                  style: AppText.bodyMuted.copyWith(color: AppColors.danger),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.large),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (visibleCases.isEmpty)
              _EmptyCases(hasQuery: _query.isNotEmpty, showClosed: _showClosed)
            else
              for (final c in visibleCases)
                _InvestigatorCaseCard(
                  caseSummary: c,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => InvestigatorCaseDetailPage(
                          caseId: c.caseId,
                          service: _service,
                        ),
                      ),
                    );
                    if (mounted) _load();
                  },
                ),
            const SizedBox(height: AppSpacing.medium),
            const Text(
              'Case access is limited to assigned investigations. Unreviewed people are shown as counts only.',
              textAlign: TextAlign.center,
              style: AppText.bodyMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _OperationalSummary extends StatelessWidget {
  final int caseCount;
  final int reportCount;
  final int possiblePeople;

  const _OperationalSummary({
    required this.caseCount,
    required this.reportCount,
    required this.possiblePeople,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.header,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.accent.withAlpha(128)),
      ),
      child: Row(
        children: [
          _SummaryMetric(value: '$caseCount', label: 'ACTIVE CASES'),
          _SummaryMetric(value: '$reportCount', label: 'REPORTS'),
          _SummaryMetric(value: '$possiblePeople', label: 'REVIEW FLAGS'),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String value;
  final String label;

  const _SummaryMetric({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: AppText.cardTitle.copyWith(
              color: AppColors.accent,
              fontSize: 23,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(fontSize: 9),
          ),
        ],
      ),
    );
  }
}

class _InvestigatorCaseCard extends StatelessWidget {
  final CaseSummary caseSummary;
  final VoidCallback onTap;

  const _InvestigatorCaseCard({
    required this.caseSummary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (status, color) = statusStyle(caseSummary.status);
    final latest = caseSummary.preview.isEmpty
        ? null
        : caseSummary.preview.first.location;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.medium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.medium),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(caseSummary.reference, style: AppText.caption),
                        const SizedBox(height: 4),
                        Text(caseSummary.title, style: AppText.cardTitle),
                      ],
                    ),
                  ),
                  StatusTag(label: status, color: color),
                ],
              ),
              if (latest != null) ...[
                const SizedBox(height: AppSpacing.small),
                DetailLine(icon: Icons.place_outlined, text: latest),
              ],
              const Divider(),
              Wrap(
                spacing: AppSpacing.medium,
                runSpacing: AppSpacing.small,
                children: [
                  _CardFact(
                    icon: Icons.assignment_outlined,
                    label:
                        '${caseSummary.incidentCount} ${caseSummary.incidentCount == 1 ? 'report' : 'reports'}',
                  ),
                  if (caseSummary.plates.isNotEmpty)
                    _CardFact(
                      icon: Icons.directions_car_outlined,
                      label: caseSummary.plates.take(2).join(' · '),
                    ),
                  if (caseSummary.possibleSuspects > 0)
                    _CardFact(
                      icon: Icons.person_search_outlined,
                      label:
                          'About ${caseSummary.possibleSuspects} possible people to review',
                      color: AppColors.accent,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.small),
              const Align(
                alignment: Alignment.centerRight,
                child: Icon(Icons.arrow_forward, color: AppColors.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardFact extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _CardFact({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? AppColors.textMuted),
        const SizedBox(width: 5),
        Text(
          label,
          style: AppText.bodyMuted.copyWith(
            fontSize: 12,
            color: color ?? AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}

class _EmptyCases extends StatelessWidget {
  final bool hasQuery;
  final bool showClosed;

  const _EmptyCases({required this.hasQuery, required this.showClosed});

  @override
  Widget build(BuildContext context) {
    final message = hasQuery
        ? 'No assigned cases match that search.'
        : showClosed
            ? 'No cases are assigned to your account yet.'
            : 'No active cases are assigned to you.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const Icon(Icons.folder_open, size: 40, color: AppColors.textMuted),
          const SizedBox(height: AppSpacing.medium),
          Text(message, textAlign: TextAlign.center, style: AppText.bodyMuted),
          if (!hasQuery)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.small),
              child: Text(
                'Contact your system administrator if you need case access.',
                textAlign: TextAlign.center,
                style: AppText.bodyMuted,
              ),
            ),
        ],
      ),
    );
  }
}
