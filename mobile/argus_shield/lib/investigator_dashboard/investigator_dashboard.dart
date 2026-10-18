import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/login.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/settings_screen.dart';
import 'package:argus_shield/app_settings.dart';
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
        _error = 'loadAssignedError';
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

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return Scaffold(
      appBar: RoleAppBar(
        roleLabel: appSettings.t('investigatorRole'),
        actions: [
          IconButton(
            tooltip: appSettings.t('settings'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: appSettings.t('signOut'),
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
            Text(appSettings.t('investigationDashboard'), style: titleOnPage(context)),
            const SizedBox(height: 4),
            Text(
              appSettings.t('assignedIntro'),
              style: mutedOnPage(context),
            ),
            const SizedBox(height: AppSpacing.medium),
            _OperationalSummary(
              caseCount: _cases.where((c) => !c.isClosed).length,
              reportCount: reports,
              possiblePeople: possiblePeople,
              casesLabel: appSettings.t('activeCasesLabel'),
              reportsLabel: appSettings.t('reportsLabel'),
              flagsLabel: appSettings.t('reviewFlags'),
            ),
            const SizedBox(height: AppSpacing.large),
            Row(
              children: [
                Expanded(
                  child: Text(appSettings.t('myCases'), style: titleOnPage(context)),
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
                  label: Text(_showClosed
                      ? appSettings.t('activeOnly')
                      : appSettings.t('includeClosed')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.small),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: appSettings.t('searchAssigned'),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
            const SizedBox(height: AppSpacing.medium),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.medium),
                child: Text(
                  appSettings.t(_error!),
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
            Text(
              appSettings.t('caseAccessNote'),
              textAlign: TextAlign.center,
              style: mutedOnPage(context),
            ),
          ],
        ),
      ),
    );
      },
    );
  }
}

class _OperationalSummary extends StatelessWidget {
  final int caseCount;
  final int reportCount;
  final int possiblePeople;
  final String casesLabel;
  final String reportsLabel;
  final String flagsLabel;

  const _OperationalSummary({
    required this.caseCount,
    required this.reportCount,
    required this.possiblePeople,
    required this.casesLabel,
    required this.reportsLabel,
    required this.flagsLabel,
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
      child: NavyText(
        child: Row(
        children: [
          _SummaryMetric(value: '$caseCount', label: casesLabel),
          _SummaryMetric(value: '$reportCount', label: reportsLabel),
          _SummaryMetric(value: '$possiblePeople', label: flagsLabel),
        ],
      ),
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
            style: const TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: Colors.white70,
            ),
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
    final c = caseSummary;
    final (status, color) = statusStyle(c.status);
    final latest = c.preview.isEmpty ? null : c.preview.first.location;
    final description = c.description?.trim() ?? '';

    // Same parts as the admin's case cards (cases.dart CaseCard): AdminCard,
    // Courier reference + status tag, title, divider, icon lines and fact
    // chips - with fewer lines, so it stays compact. Grey outline like the
    // admin's case cards: they only turn gold when no investigator is
    // assigned, and every case here is assigned to this investigator.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AdminCard(
        onTap: onTap,
        borderColor: AppColors.fieldBorder,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    c.reference,
                    style: AppText.cardTitle.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(width: AppSpacing.small),
                StatusTag(label: status, color: color),
              ],
            ),
            const SizedBox(height: 6),
            Text(c.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                )),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyMuted.copyWith(color: Colors.white70)),
            ],
            const SizedBox(height: 10),
            const Divider(color: AppColors.fieldBorder, height: 1),
            const SizedBox(height: 10),
            if (latest != null)
              DetailLine(icon: Icons.location_on_outlined, text: latest),
            DetailLine(
              icon: Icons.description_outlined,
              text: [
                plural(c.incidentCount, 'report'),
                if (c.mediaCount > 0)
                  '${c.mediaCount} media ${c.mediaCount == 1 ? 'file' : 'files'}',
              ].join(' · '),
            ),
            if (c.plates.isNotEmpty ||
                c.possibleSuspects > 0 ||
                c.confirmedSuspects > 0)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final plate in c.plates.take(2))
                    FactChip(plate,
                        icon: Icons.pin_outlined, color: AppColors.accent),
                  if (c.confirmedSuspects > 0)
                    FactChip(plural(c.confirmedSuspects, 'confirmed suspect'),
                        icon: Icons.person_outline, color: AppColors.danger),
                  if (c.possibleSuspects > 0)
                    FactChip(
                        'about ${plural(c.possibleSuspects, 'possible suspect')} to review',
                        icon: Icons.person_search_outlined,
                        color: AppColors.accent),
                ],
              ),
          ],
        ),
      ),
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
        ? appSettings.t('noCasesMatch')
        : showClosed
            ? appSettings.t('noCasesAssigned')
            : appSettings.t('noActiveAssigned');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.folder_open, size: 40, color: pageInkMuted(context)),
          const SizedBox(height: AppSpacing.medium),
          Text(message, textAlign: TextAlign.center, style: mutedOnPage(context)),
          if (!hasQuery)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.small),
              child: Text(
                appSettings.t('contactAdmin'),
                textAlign: TextAlign.center,
                style: mutedOnPage(context),
              ),
            ),
        ],
      ),
    );
  }
}
