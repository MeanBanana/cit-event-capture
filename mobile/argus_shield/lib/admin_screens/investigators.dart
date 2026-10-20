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
//
// Each card has Update (the same form, filled in: details, username, email,
// optional new temporary password -> SupabaseService.updateInvestigator) and
// Delete (SupabaseService.deleteInvestigator, after a confirmation).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/investigator_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/new_investigator_form.dart';
import 'package:argus_shield/app_settings.dart';
import 'package:argus_shield/saved_contact_details.dart' show localSaPhone;

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

  /// Opens the "New investigator" popup. On success: closes it, shows the
  /// username and temporary password to pass on, and reloads the list so
  /// the new account appears at the top.
  Future<void> _newInvestigator() async {
    final created = await showAdminSheet<NewInvestigatorDetails>(
      context,
      title: 'New investigator',
      builder: (sheetContext) => NewInvestigatorForm(
        onCreate: (details) async {
          await _service.createInvestigator(
            firstName: details.firstName,
            surname: details.surname,
            username: details.username,
            email: details.email,
            phone: details.phone,
            rank: details.rank,
            badgeNumber: details.badgeNumber,
            station: details.station,
            unit: details.unit,
            password: details.password,
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

    await _showLogIn(created,
        title: 'Account created',
        intro: '${created.firstName} ${created.surname}\'s account is ready.');
  }

  /// "Update": the New investigator form, filled in. The list doesn't carry
  /// the username, so it is fetched first.
  Future<void> _updateInvestigator(InvestigatorSummary inv) async {
    String? username;
    try {
      username = await _service.getUsername(inv.userId);
    } catch (_) {
      username = null;
    }
    if (!mounted) return;
    if (username == null) {
      showSnack(context, 'Could not load the account. Check your connection.');
      return;
    }
    final login = username;

    final saved = await showAdminSheet<NewInvestigatorDetails>(
      context,
      title: 'Update investigator',
      builder: (sheetContext) => NewInvestigatorForm(
        initial: NewInvestigatorDetails(
          firstName: inv.firstName,
          surname: inv.surname,
          username: login,
          email: inv.email,
          phone: localSaPhone(inv.phoneNumber),
          rank: inv.rank ?? '',
          badgeNumber: inv.badgeNumber,
          station: inv.station,
          unit: inv.unit ?? '',
          password: '',
        ),
        onCreate: (details) async {
          await _service.updateInvestigator(
            userId: inv.userId,
            firstName: details.firstName,
            surname: details.surname,
            username: details.username,
            email: details.email,
            phone: details.phone,
            rank: details.rank,
            badgeNumber: details.badgeNumber,
            station: details.station,
            unit: details.unit,
            password: details.password,
          );
          if (sheetContext.mounted) Navigator.pop(sheetContext, details);
        },
      ),
    );
    if (saved == null || !mounted) return;
    _reload();
    if (saved.password.isEmpty) {
      showSnack(context, '${saved.firstName} ${saved.surname}\'s details saved');
      return;
    }
    await _showLogIn(saved,
        title: 'Details saved',
        intro: 'Give ${saved.firstName} ${saved.surname} their new log-in.');
  }

  /// "Delete": asks first, then removes the account.
  Future<void> _deleteInvestigator(InvestigatorSummary inv) async {
    final cases = inv.activeCases;
    final ok = await confirmAction(
      context,
      title: 'Delete ${inv.displayName}?',
      message: 'They can no longer log in'
          '${cases > 0 ? ' and are taken off ${cases == 1 ? 'their active case' : 'their $cases active cases'}' : ''}. '
          'Anything they already did on a case (chat messages, corrections) '
          'stays in its records as "Former investigator". '
          'This can\'t be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _service.deleteInvestigator(inv.userId);
      if (!mounted) return;
      showSnack(context, '${inv.displayName}\'s account was deleted');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  /// The log-in details to pass on (after creating, or a new password).
  Future<void> _showLogIn(NewInvestigatorDetails created,
      {required String title, required String intro}) async {
    final details = 'Argus Shield log-in\n'
        'Username: ${created.username}\n'
        'Temporary password: ${created.password}\n'
        'You will be asked to choose your own password when you first log in.';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              intro,
              style: AppText.body,
            ),
            const SizedBox(height: AppSpacing.medium),
            SelectableText(
              'Username: ${created.username}\n'
              'Temporary password: ${created.password}',
              style: AppText.body.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: AppSpacing.medium),
            const Text(
              'Share these privately. They must choose their own password '
              'the first time they log in.',
              style: AppText.bodyMuted,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: details));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log-in details copied')),
              );
            },
            child: const Text('Copy'),
          ),
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
        itemBuilder: (context, index) {
          final inv = _investigators[index];
          return InvestigatorCard(
            investigator: inv,
            onUpdate: () => _updateInvestigator(inv),
            onDelete: () => _deleteInvestigator(inv),
          );
        },
      ),
    );
  }
}

/// One investigator's details. Styled like SubmissionCard on the citizen side
/// (outlined box, Courier title, small coloured status tag).
class InvestigatorCard extends StatelessWidget {
  final InvestigatorSummary investigator;

  /// Update / Delete buttons at the bottom (admins' Investigators tab).
  final VoidCallback? onUpdate;
  final VoidCallback? onDelete;

  const InvestigatorCard({
    super.key,
    required this.investigator,
    this.onUpdate,
    this.onDelete,
  });

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
          if (onUpdate != null || onDelete != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (onUpdate != null)
                  Expanded(
                    child: SmallActionButton(
                      key: ValueKey('update-${inv.userId}'),
                      label: 'Update',
                      color: AppColors.accent,
                      onPressed: onUpdate,
                    ),
                  ),
                if (onUpdate != null && onDelete != null)
                  const SizedBox(width: AppSpacing.small),
                if (onDelete != null)
                  Expanded(
                    child: SmallActionButton(
                      key: ValueKey('delete-${inv.userId}'),
                      label: 'Delete',
                      color: AppColors.danger,
                      onPressed: onDelete,
                    ),
                  ),
              ],
            ),
          ],
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
