// suggested_matches.dart — one-tap review of the AI's case suggestions.
//
// The database scores every pending submission against the open cases
// (same plate, AI links, distance, time ...). Submissions that most likely
// belong to an existing case are listed here, each with its best case and
// the reasons. Every match starts ticked, except where another case also
// matches well. The admin checks the list, unticks anything wrong, and
// accepts the rest with one tap.
//
// Nothing joins a case automatically: until the admin taps Accept, the
// submissions stay pending and investigators can't see them.
//
//   SuggestedMatchesBanner  the "N submissions match existing cases" bar at
//                           the top of the Submissions list
//   SuggestedMatchesPage    the review list itself

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';

/// Bar shown above the Submissions list when there are suggested matches.
/// Shows nothing while loading, on error, or when there are none.
class SuggestedMatchesBanner extends StatefulWidget {
  final SupabaseService service;

  /// Called when the admin comes back from the review page, so the list
  /// behind can reload.
  final VoidCallback onChanged;

  const SuggestedMatchesBanner({
    super.key,
    required this.service,
    required this.onChanged,
  });

  @override
  State<SuggestedMatchesBanner> createState() => _SuggestedMatchesBannerState();
}

class _SuggestedMatchesBannerState extends State<SuggestedMatchesBanner> {
  late final Future<List<SuggestedMatch>> _matches = _load();

  Future<List<SuggestedMatch>> _load() async {
    try {
      return await widget.service.listSuggestedMatches();
    } catch (_) {
      return const []; // a bonus: never break the Submissions list
    }
  }

  Future<void> _open() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SuggestedMatchesPage(service: widget.service),
      ),
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SuggestedMatch>>(
      future: _matches,
      builder: (context, snap) {
        final n = snap.data?.length ?? 0;
        if (n == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.medium),
          child: AdminCard(
            onTap: _open,
            borderColor: AppColors.success,
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_outlined, color: AppColors.success),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n == 1
                            ? '1 submission matches an existing case'
                            : '$n submissions match existing cases',
                        style: AppText.body.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text('Review them and accept in one tap',
                          style: AppText.bodyMuted.copyWith(fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One suggestion with the submission and case it is about.
class _Item {
  final SuggestedMatch match;
  final CrimeSceneSummary submission;
  final CaseSummary caseSummary;
  bool selected;

  _Item(this.match, this.submission, this.caseSummary)
      // ambiguous ones (another case matches too) start unticked
      : selected = match.otherCases == 0;
}

/// The review list.
class SuggestedMatchesPage extends StatefulWidget {
  final SupabaseService? service;

  const SuggestedMatchesPage({super.key, this.service});

  @override
  State<SuggestedMatchesPage> createState() => _SuggestedMatchesPageState();
}

class _SuggestedMatchesPageState extends State<SuggestedMatchesPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  List<_Item> _items = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The matches, plus the submissions and cases they are about (one call
  /// for all the submissions, one per distinct case).
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final matches = await _service.listSuggestedMatches();
      final subs = matches.isEmpty
          ? const <CrimeSceneSummary>[]
          : await _service.listSubmissionsPage(
              ids: [for (final m in matches) m.incidentId],
              limit: matches.length);
      final caseIds = {for (final m in matches) m.caseId}.toList();
      final cases = await Future.wait(caseIds.map(_service.getCase));
      final subById = {for (final s in subs) s.incidentId: s};
      final caseById = {for (final c in cases.nonNulls) c.caseId: c};
      if (!mounted) return;
      setState(() {
        _items = [
          for (final m in matches)
            if (subById[m.incidentId] != null && caseById[m.caseId] != null)
              _Item(m, subById[m.incidentId]!, caseById[m.caseId]!),
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the suggestions. Pull down to try again.';
        _loading = false;
      });
    }
  }

  int get _selectedCount => _items.where((i) => i.selected).length;

  Future<void> _acceptSelected() async {
    final chosen = [for (final i in _items) if (i.selected) i.match];
    if (chosen.isEmpty) return;
    setState(() => _saving = true);
    try {
      final added = await _service.acceptSuggestedMatches(chosen);
      if (!mounted) return;
      final skipped = chosen.length - added;
      showSnack(
          context,
          '${plural(added, 'submission')} added to cases'
          '${skipped > 0 ? ' ($skipped already reviewed by someone else)' : ''}');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _view(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) await _load(); // it may have been reviewed there
  }

  void _setAll(bool value) {
    setState(() {
      for (final i in _items) {
        i.selected = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = _selectedCount;
    return Scaffold(
        appBar: const ArgusAppBar(roleLabel: 'Admin'),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppSpacing.page,
            children: [
              const Text('Suggested matches', style: AppText.sectionTitle),
              const SizedBox(height: AppSpacing.small),
              const Text(
                'Pending submissions that look like part of an existing case. '
                'Untick anything that doesn\'t belong, then accept the rest. '
                'Nothing is added until you accept it.',
                style: AppText.bodyMuted,
              ),
              const SizedBox(height: AppSpacing.medium),
              if (_saving) const LinearProgressIndicator(),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.large),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Text(_error!, style: AppText.bodyMuted, textAlign: TextAlign.center)
              else if (_items.isEmpty)
                const Text('No suggested matches right now.',
                    style: AppText.bodyMuted, textAlign: TextAlign.center)
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: Text('$n of ${_items.length} selected',
                          style: AppText.caption
                              .copyWith(color: AppColors.textHint)),
                    ),
                    TextButton(
                        onPressed: () => _setAll(true),
                        child: const Text('Select all')),
                    TextButton(
                        onPressed: () => _setAll(false),
                        child: const Text('Clear')),
                  ],
                ),
                for (final item in _items) ...[
                  _MatchCard(
                    item: item,
                    onChanged: (v) => setState(() => item.selected = v),
                    onView: () => _view(item.submission),
                  ),
                  const SizedBox(height: AppSpacing.small),
                ],
                const SizedBox(height: 80), // room above the button
              ],
            ],
          ),
        ),
        bottomNavigationBar: _items.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: n == 0 || _saving ? null : _acceptSelected,
                      child: Text(n == 0
                          ? 'Tick the matches to accept'
                          : 'Accept ${plural(n, 'match', 'matches')}'),
                    ),
                  ),
                ),
              ),
    );
  }
}

/// One suggestion: tick box, the submission, the case it goes into, and why.
class _MatchCard extends StatelessWidget {
  final _Item item;
  final ValueChanged<bool> onChanged;
  final VoidCallback onView;

  const _MatchCard({
    required this.item,
    required this.onChanged,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final s = item.submission;
    final c = item.caseSummary;
    final m = item.match;

    return AdminCard(
      onTap: () => onChanged(!item.selected),
      borderColor: item.selected ? AppColors.success : AppColors.fieldBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: item.selected,
                activeColor: AppColors.success,
                onChanged: (v) => onChanged(v ?? false),
              ),
              Expanded(
                child: Text('${s.reference} · ${s.location}',
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
              ),
              TextButton(onPressed: onView, child: const Text('View')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.aiSummary ?? s.description ?? 'No description',
                  style: AppText.bodyMuted.copyWith(fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.arrow_forward,
                        size: 18, color: AppColors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${c.reference} · ${c.title}',
                          style: AppText.body.copyWith(
                              fontSize: 15, color: AppColors.success)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(suggestionStrength(m.score).toUpperCase(),
                    style: AppText.caption.copyWith(color: AppColors.success)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in m.reasons) FactChip(r),
                    FactChip('matches ${incidentReference(m.matchedIncidentId)}'),
                  ],
                ),
                if (m.otherCases > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Also matches ${plural(m.otherCases, 'other case')}: '
                    'check before accepting.',
                    style: AppText.bodyMuted
                        .copyWith(fontSize: 13, color: AppColors.accent),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
