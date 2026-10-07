import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';

/// Assigned-case brief for investigators. Administrative review and
/// assignment controls are intentionally omitted from this surface.
class InvestigatorCaseDetailPage extends StatefulWidget {
  final int caseId;
  final SupabaseService? service;

  const InvestigatorCaseDetailPage({
    super.key,
    required this.caseId,
    this.service,
  });

  @override
  State<InvestigatorCaseDetailPage> createState() =>
      _InvestigatorCaseDetailPageState();
}

class _InvestigatorCaseDetailPageState
    extends State<InvestigatorCaseDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  CaseSummary? _case;
  List<CrimeSceneSummary> _incidents = const [];
  List<CaseEvent> _events = const [];
  bool _loading = true;
  bool _updating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _service.getCase(widget.caseId),
        _service.listSubmissionsPage(caseId: widget.caseId, limit: 100),
        _service.getCaseEvents(widget.caseId, limit: 10),
      ]);
      if (!mounted) return;
      setState(() {
        _case = results[0] as CaseSummary?;
        _incidents = results[1] as List<CrimeSceneSummary>;
        _events = results[2] as List<CaseEvent>;
        _error = _case == null ? 'This case is no longer available.' : null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this case. Pull down to try again.';
        _loading = false;
      });
    }
  }

  Future<void> _changeStatus(String status) async {
    final current = _case;
    if (current == null || _updating) return;
    setState(() => _updating = true);
    try {
      await _service.updateCase(current.caseId, status: status);
      if (mounted) {
        final label = status == 'under_review' ? 'under review' : 'open';
        showSnack(context, '${current.reference} marked $label');
      }
      await _load();
    } catch (error) {
      if (mounted) showSnack(context, errorText(error));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _case;
    return Scaffold(
      appBar: AppBar(
        title: Text(current?.reference ?? 'Case brief'),
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.textPrimary,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: AppSpacing.page,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.large),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.large),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: AppText.bodyMuted.copyWith(color: AppColors.danger),
                ),
              )
            else if (current != null) ...[
              Text(current.title, style: AppText.sectionTitle),
              const SizedBox(height: AppSpacing.small),
              if (current.description?.isNotEmpty == true)
                Text(current.description!, style: AppText.bodyMuted),
              const SizedBox(height: AppSpacing.medium),
              _CaseStatusPanel(
                caseSummary: current,
                updating: _updating,
                onStatusChanged: _changeStatus,
              ),
              const SectionLabel('Incident reports'),
              if (_incidents.isEmpty)
                const Text(
                  'No reports are currently linked to this case.',
                  style: AppText.bodyMuted,
                )
              else
                for (final incident in _incidents)
                  _IncidentEvidenceCard(incident: incident),
              const SectionLabel('Case activity'),
              if (_events.isEmpty)
                const Text('No activity recorded yet.', style: AppText.bodyMuted)
              else
                for (final event in _events) _CaseEventRow(event: event),
            ],
          ],
        ),
      ),
    );
  }
}

class _CaseStatusPanel extends StatelessWidget {
  final CaseSummary caseSummary;
  final bool updating;
  final ValueChanged<String> onStatusChanged;

  const _CaseStatusPanel({
    required this.caseSummary,
    required this.updating,
    required this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    final (status, color) = statusStyle(caseSummary.status);
    final nextStatus = caseSummary.status == 'open' ? 'under_review' : 'open';
    final actionLabel =
        nextStatus == 'under_review' ? 'Mark under review' : 'Reopen as open';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.medium),
      decoration: BoxDecoration(
        color: AppColors.header,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(140)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('CASE STATUS', style: AppText.caption)),
              StatusTag(label: status, color: color),
            ],
          ),
          const SizedBox(height: AppSpacing.small),
          Text(
            caseSummary.isClosed
                ? 'Closed cases are read-only. Contact an administrator if further work is required.'
                : 'Update the case status as field work progresses.',
            style: AppText.bodyMuted.copyWith(fontSize: 13),
          ),
          if (!caseSummary.isClosed) ...[
            const SizedBox(height: AppSpacing.small),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: updating ? null : () => onStatusChanged(nextStatus),
                icon: updating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(actionLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _IncidentEvidenceCard extends StatelessWidget {
  final CrimeSceneSummary incident;

  const _IncidentEvidenceCard({required this.incident});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.medium),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(incident.reference, style: AppText.caption),
            const SizedBox(height: 5),
            Text(incident.location, style: AppText.cardTitle),
            const SizedBox(height: AppSpacing.small),
            DetailLine(
              icon: Icons.schedule,
              text:
                  'Incident time: ${formatDateTime(incident.bestTime)}'
                  '${incident.capturedAt == null ? ' (reported time)' : ' (footage capture)'}',
            ),
            if (incident.timeMismatch)
              DetailLine(
                icon: Icons.warning_amber,
                color: AppColors.danger,
                text: 'Footage time differs from the reported incident time.',
              ),
            if (incident.attackType?.isNotEmpty == true)
              DetailLine(
                icon: Icons.report_outlined,
                text: 'Incident type: ${incident.attackType}',
              ),
            if (incident.hasGps)
              DetailLine(
                icon: Icons.my_location,
                text:
                    'GPS: ${incident.latitude!.toStringAsFixed(5)}, ${incident.longitude!.toStringAsFixed(5)}',
              ),
            if (incident.description?.isNotEmpty == true) ...[
              const SectionLabel('Reported details'),
              Text(incident.description!, style: AppText.bodyMuted),
            ],
            if (incident.aiSummary?.isNotEmpty == true) ...[
              const SectionLabel('Footage intelligence'),
              Text(incident.aiSummary!, style: AppText.bodyMuted),
            ],
            if (incident.hasAiFacts) ...[
              const SectionLabel('Detection summary'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (incident.vehicleCount > 0)
                    _EvidenceChip(
                      icon: Icons.directions_car_outlined,
                      label: '${incident.vehicleCount} vehicle(s)',
                    ),
                  if (incident.personCount > 0)
                    _EvidenceChip(
                      icon: Icons.people_outline,
                      label: '${incident.personCount} people',
                    ),
                  if (incident.weaponCount > 0)
                    _EvidenceChip(
                      icon: Icons.warning_amber,
                      label: '${incident.weaponCount} weapon(s)',
                    ),
                  if (incident.possibleSuspects > 0)
                    _EvidenceChip(
                      icon: Icons.person_search_outlined,
                      label:
                          '${incident.possibleSuspects} possible suspect(s) to review',
                      color: AppColors.accent,
                    ),
                  if (incident.confirmedSuspects > 0)
                    _EvidenceChip(
                      icon: Icons.verified_user_outlined,
                      label:
                          '${incident.confirmedSuspects} confirmed suspect(s)',
                      color: AppColors.success,
                    ),
                  for (final plate in incident.plates)
                    _EvidenceChip(
                      icon: Icons.pin_outlined,
                      label: plate,
                    ),
                ],
              ),
            ],
            if (incident.mediaCount > 0) ...[
              const SizedBox(height: AppSpacing.small),
              DetailLine(
                icon: Icons.perm_media_outlined,
                text:
                    '${incident.mediaCount} footage item(s) attached${incident.aiSummaryStatus == 'processing' ? ' · analysis in progress' : ''}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EvidenceChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _EvidenceChip({
    required this.icon,
    required this.label,
    this.color = AppColors.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(
        label,
        style: AppText.bodyMuted.copyWith(fontSize: 11, color: color),
      ),
      side: BorderSide(color: color.withAlpha(100)),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CaseEventRow extends StatelessWidget {
  final CaseEvent event;

  const _CaseEventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.medium),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.circle, size: 9, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.text, style: AppText.body),
                const SizedBox(height: 3),
                Text(
                  '${formatDateTime(event.occurredAt)}${event.actorName == null ? '' : ' · ${event.actorName}'}',
                  style: AppText.bodyMuted.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
