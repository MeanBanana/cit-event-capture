// investigators.dart — System Administrator view of every investigator.
//
// Shows a search bar (name or badge number) and a scrollable list of
// investigator cards.
//
// Data comes from SupabaseService:
//   * on opening: getRecentInvestigators()  -> the 20 newest accounts
//   * while searching: searchInvestigators() -> matches by name/badge number
// The search runs in the database (not on the phone), so it finds any
// investigator, not only the 20 already on screen.
//
// "+ New investigator" opens a popup (NewInvestigatorForm) that creates the
// account through SupabaseService.createInvestigator.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/investigator_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/new_investigator_form.dart';
import 'package:argus_shield/app_settings.dart';

// Other screens (e.g. overview.dart) import InvestigatorSummary from here.
export 'package:argus_shield/models/investigator_summary.dart';

/// Body of the Investigators tab. Like the citizen pages, it has no Scaffold
/// or header of its own — AdminDashboard draws those.
class Investigators extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const Investigators({super.key, this.service});

  /// How long to wait after the last key press before searching, so typing
  /// "JHB-4471" sends one request instead of eight.
  static const searchDelay = Duration(milliseconds: 400);

  @override
  State<Investigators> createState() => _InvestigatorsState();
}

class _InvestigatorsState extends State<Investigators> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  final _searchController = TextEditingController();
  Timer? _searchTimer;

  String _query = '';
  List<InvestigatorSummary> _investigators = const [];
  bool _loading = true;
  String? _error;

  // Each request gets a number; only the newest one may update the screen,
  // so a slow old search cannot overwrite a newer result.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch(); // _loading already starts as true
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Loads the recent investigators, or the search results when there is
  /// search text.
  Future<void> _fetch() async {
    final id = ++_requestId;
    final query = _query.trim();
    try {
      final rows = query.isEmpty
          ? await _service.getRecentInvestigators()
          : await _service.searchInvestigators(query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _investigators = rows;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = appSettings.t('loadInvestigatorsError');
        _loading = false;
      });
    }
  }

  /// Shows the spinner and loads again (search changed, or "Try again").
  void _reload() {
    _searchTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    _searchTimer = Timer(Investigators.searchDelay, _reload);
  }

  void _clearSearch() {
    _searchController.clear();
    _query = '';
    _reload();
  }

  /// Opens the "New investigator" popup. On success: closes it, explains
  /// how the investigator sets their password, and reloads the list so the
  /// new account appears at the top.
  Future<void> _newInvestigator() async {
    var emailSent = true;
    final created = await showAdminSheet<NewInvestigatorDetails>(
      context,
      title: 'New investigator',
      builder: (sheetContext) => NewInvestigatorForm(
        onCreate: (details) async {
          emailSent = await _service.createInvestigator(
            firstName: details.firstName,
            surname: details.surname,
            username: details.username,
            email: details.email,
            phone: details.phone,
            rank: details.rank,
            badgeNumber: details.badgeNumber,
            station: details.station,
            unit: details.unit,
          );
          if (sheetContext.mounted) Navigator.pop(sheetContext, details);
        },
      ),
    );
    if (created == null || !mounted) return;

    // Show the newest accounts again (the new one is first).
    _searchController.clear();
    _query = '';
    _reload();

    final passwordHelp = emailSent
        ? 'We\'ve emailed ${created.email} a link to choose a password. '
            'After that they log in on Argus Shield. The link expires, so ask '
            'them to use it soon.'
        : 'The email with the password link could not be sent. They can open '
            'Argus Shield on their own phone, tap "Forgot password?" and '
            'enter ${created.email}.';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Account created', style: AppText.cardTitle),
        content: Text(
          '${created.firstName} ${created.surname}\'s account is ready, with '
          'the username "${created.username}".\n\n$passwordHelp',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String get _countText {
    final n = _investigators.length;
    if (_query.trim().isEmpty) {
      return n == 1
          ? appSettings.t('showingRecentOne')
          : '${appSettings.t('showingThe')} $n ${appSettings.t('mostRecentInvestigators')}';
    }
    return '$n ${n == 1 ? appSettings.t('matchOne') : appSettings.t('matchMany')} ${appSettings.t('forWord')} "${_query.trim()}"';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Padding(
      padding: AppSpacing.tab,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title on its own line ("Investigators" is too long to share a
          // line with the button on a phone), then the add button below it
          // on the right, styled like "+ New case" on Cases.
          Text(appSettings.t('investigators'), style: titleOnPage(context)),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: SmallActionButton(
              label: appSettings.t('newInvestigator'),
              color: AppColors.accent,
              onPressed: _newInvestigator,
            ),
          ),
          const SizedBox(height: AppSpacing.small),
          Text(
            appSettings.t('investigatorsIntro'),
            style: mutedOnPage(context),
          ),
          const SizedBox(height: AppSpacing.medium),

          // Search bar — borders and focus colour come from the app theme.
          TextField(
            controller: _searchController,
            style: bodyOnPage(context),
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _reload(), // search now, don't wait
            decoration: InputDecoration(
              hintText: appSettings.t('searchInvestigators'),
              hintStyle: mutedOnPage(context),
              prefixIcon: const Icon(Icons.search, color: AppColors.accent),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, color: pageInkMuted(context)),
                      tooltip: appSettings.t('clearSearch'),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.small),
          if (!_loading && _error == null)
            Text(
              _countText,
              style: mutedOnPage(context),
            ),
          const SizedBox(height: AppSpacing.medium),

          // Only the list scrolls; the title and search bar stay in place.
          Expanded(child: _buildList()),
        ],
      ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: mutedOnPage(context), textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.small),
            TextButton(onPressed: _reload, child: Text(appSettings.t('tryAgain'))),
          ],
        ),
      );
    }

    if (_investigators.isEmpty) {
      return Center(
        child: Text(
          _query.trim().isEmpty
              ? appSettings.t('noInvestigators')
              : appSettings.t('noInvestigatorsMatch'),
          style: mutedOnPage(context),
        ),
      );
    }

    // Pull down to refresh.
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 12), // gap after the last card
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _investigators.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.medium),
        itemBuilder: (context, index) =>
            InvestigatorCard(investigator: _investigators[index]),
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
        return (appSettings.t('onDuty'), AppColors.success);
      case 'available':
        return (appSettings.t('available'), AppColors.accent);
      case 'off_duty':
        return (appSettings.t('offDuty'), AppColors.neutral);
      default:
        return (dutyStatus, AppColors.neutral);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = investigator;
    final (statusLabel, statusColor) = _status(inv.dutyStatus);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
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
            '${appSettings.t('badge')} ${inv.badgeNumber}',
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
            text: '${inv.activeCases} ${inv.activeCases == 1 ? appSettings.t('activeCaseOne') : appSettings.t('activeCaseMany')}',
          ),
        ],
      ),
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
