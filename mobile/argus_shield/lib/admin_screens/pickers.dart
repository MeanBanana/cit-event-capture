// pickers.dart — the slide-up panels the admin uses to choose things:
//   CasePicker          an open case (accept into it / move to it)
//   IncidentPicker      one submission (duplicate of) or several (add to case)
//   InvestigatorPicker  an investigator to assign to a case
//   NewCaseForm         title + description for a new case
// Open them inside showAdminSheet().

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/investigator_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

/// Wait after the last key press before searching.
const pickerSearchDelay = Duration(milliseconds: 400);

/// Opens a panel from the bottom of the screen with a title bar and a close
/// button. [builder] fills the rest. Returns whatever the panel pops with.
Future<T?> showAdminSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: pageColor(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (sheetContext) {
      final height = MediaQuery.of(sheetContext).size.height * 0.85;
      return Padding(
        // keeps the content above the keyboard
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title.toUpperCase(),
                          style: AppText.cardTitle.copyWith(fontSize: 16)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppColors.neutral),
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(child: builder(sheetContext)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Search field used at the top of every picker.
class _PickerSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;

  const _PickerSearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      style: AppText.body,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, color: AppColors.accent),
        isDense: true,
      ),
    );
  }
}

/// Loading / error / empty handling shared by the pickers.
Widget _pickerBody({
  required bool loading,
  required String? error,
  required bool empty,
  required String emptyText,
  required Widget Function() list,
}) {
  if (loading) return const Center(child: CircularProgressIndicator());
  if (error != null) {
    return Center(
        child: Text(error, style: AppText.bodyMuted, textAlign: TextAlign.center));
  }
  if (empty) {
    return Center(
        child:
            Text(emptyText, style: AppText.bodyMuted, textAlign: TextAlign.center));
  }
  return list();
}

// ===========================================================================
// CasePicker
// ===========================================================================

/// Lists open / under-review cases (most recently active first) with a
/// search box. Tapping one calls [onSelected].
class CasePicker extends StatefulWidget {
  final SupabaseService service;
  final ValueChanged<CaseSummary> onSelected;

  /// Hidden from the list, e.g. the case the incident is already in.
  final int? excludeCaseId;

  /// When set, a "Case not listed? Create a new case" button is shown at
  /// the bottom and calls this.
  final VoidCallback? onNotListed;

  const CasePicker({
    super.key,
    required this.service,
    required this.onSelected,
    this.excludeCaseId,
    this.onNotListed,
  });

  @override
  State<CasePicker> createState() => _CasePickerState();
}

class _CasePickerState extends State<CasePicker> {
  Timer? _timer;
  String _query = '';
  List<CaseSummary> _cases = const [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = ++_requestId;
    try {
      final rows = await widget.service
          .listCases(query: _query, status: 'active', limit: 50);
      if (!mounted || id != _requestId) return;
      setState(() {
        _cases =
            rows.where((c) => c.caseId != widget.excludeCaseId).toList();
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _onSearch(String value) {
    _query = value;
    _timer?.cancel();
    _timer = Timer(pickerSearchDelay, () {
      setState(() => _loading = true);
      _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PickerSearchField(
            hint: 'Search by case number/title', onChanged: _onSearch),
        const SizedBox(height: AppSpacing.small),
        Expanded(
          child: _pickerBody(
            loading: _loading,
            error: _error,
            empty: _cases.isEmpty,
            emptyText: _query.trim().isEmpty
                ? 'There are no open cases yet.'
                : 'No open cases match your search.',
            list: () => ListView.separated(
              itemCount: _cases.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.fieldBorder, height: 1),
              itemBuilder: (context, i) {
                final c = _cases[i];
                final (label, color) = statusStyle(c.status);
                final people = c.investigators.length;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${c.reference} · ${c.title}',
                      style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${plural(c.incidentCount, 'submission')} · '
                    '${plural(people, 'investigator')}',
                    style: AppText.bodyMuted.copyWith(fontSize: 13),
                  ),
                  trailing: StatusTag(label: label, color: color),
                  onTap: () => widget.onSelected(c),
                );
              },
            ),
          ),
        ),
        if (widget.onNotListed != null) ...[
          const SizedBox(height: AppSpacing.small),
          OutlinedButton.icon(
            onPressed: widget.onNotListed,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Case not listed? Create a new case'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side: const BorderSide(color: AppColors.accent),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ],
    );
  }
}

// ===========================================================================
// IncidentPicker
// ===========================================================================

/// Lists submissions with a search box (incident number or location).
///  * single choice: tapping one calls [onSelected]
///  * [multiSelect]: tick several, then the button calls [onConfirm]
class IncidentPicker extends StatefulWidget {
  final SupabaseService service;

  /// Only submissions with this review status (e.g. 'pending'); null = all.
  final String? review;

  /// Incident ids to leave out (e.g. the incident itself).
  final Set<int> exclude;

  final bool multiSelect;
  final ValueChanged<CrimeSceneSummary>? onSelected;
  final Future<void> Function(List<int> incidentIds)? onConfirm;
  final String confirmLabel;

  const IncidentPicker({
    super.key,
    required this.service,
    this.review,
    this.exclude = const {},
    this.multiSelect = false,
    this.onSelected,
    this.onConfirm,
    this.confirmLabel = 'Add',
  });

  @override
  State<IncidentPicker> createState() => _IncidentPickerState();
}

class _IncidentPickerState extends State<IncidentPicker> {
  Timer? _timer;
  String _query = '';
  List<CrimeSceneSummary> _incidents = const [];
  final Set<int> _chosen = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = ++_requestId;
    try {
      final rows = await widget.service
          .searchSubmissions(_query, limit: 50, review: widget.review);
      if (!mounted || id != _requestId) return;
      setState(() {
        _incidents =
            rows.where((s) => !widget.exclude.contains(s.incidentId)).toList();
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _onSearch(String value) {
    _query = value;
    _timer?.cancel();
    _timer = Timer(pickerSearchDelay, () {
      setState(() => _loading = true);
      _fetch();
    });
  }

  Future<void> _confirm() async {
    final onConfirm = widget.onConfirm;
    if (onConfirm == null || _chosen.isEmpty) return;
    setState(() => _saving = true);
    try {
      await onConfirm(_chosen.toList());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PickerSearchField(
            hint: 'Search by incident number/location', onChanged: _onSearch),
        const SizedBox(height: AppSpacing.small),
        Expanded(
          child: _pickerBody(
            loading: _loading,
            error: _error,
            empty: _incidents.isEmpty,
            emptyText: _query.trim().isEmpty
                ? 'No submissions to choose from.'
                : 'No submissions match your search.',
            list: () => ListView.separated(
              itemCount: _incidents.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.fieldBorder, height: 1),
              itemBuilder: (context, i) {
                final s = _incidents[i];
                final title = Text('${s.reference} · ${s.location}',
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold));
                final subtitle = Text(
                  'Reported ${formatDateTime(s.dateReported ?? s.dateTime)}',
                  style: AppText.bodyMuted.copyWith(fontSize: 13),
                );
                if (widget.multiSelect) {
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    activeColor: AppColors.accent,
                    value: _chosen.contains(s.incidentId),
                    title: title,
                    subtitle: subtitle,
                    onChanged: (on) => setState(() => on == true
                        ? _chosen.add(s.incidentId)
                        : _chosen.remove(s.incidentId)),
                  );
                }
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: title,
                  subtitle: subtitle,
                  onTap: () => widget.onSelected?.call(s),
                );
              },
            ),
          ),
        ),
        if (widget.multiSelect) ...[
          const SizedBox(height: AppSpacing.small),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _chosen.isEmpty || _saving ? null : _confirm,
              child: Text(_chosen.isEmpty
                  ? 'Tick the incidents to add'
                  : '${widget.confirmLabel} ${_chosen.length} '
                      '${_chosen.length == 1 ? 'incident' : 'incidents'}'),
            ),
          ),
        ],
      ],
    );
  }
}

// ===========================================================================
// InvestigatorPicker
// ===========================================================================

/// Lists investigators (newest first) with a search box (name or badge).
/// Tapping one calls [onSelected].
class InvestigatorPicker extends StatefulWidget {
  final SupabaseService service;
  final ValueChanged<InvestigatorSummary> onSelected;

  /// User ids to leave out (e.g. already assigned).
  final Set<int> exclude;

  const InvestigatorPicker({
    super.key,
    required this.service,
    required this.onSelected,
    this.exclude = const {},
  });

  @override
  State<InvestigatorPicker> createState() => _InvestigatorPickerState();
}

class _InvestigatorPickerState extends State<InvestigatorPicker> {
  Timer? _timer;
  String _query = '';
  List<InvestigatorSummary> _people = const [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = ++_requestId;
    try {
      final rows = await widget.service.searchInvestigators(_query, limit: 50);
      if (!mounted || id != _requestId) return;
      setState(() {
        _people = rows.where((p) => !widget.exclude.contains(p.userId)).toList();
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _onSearch(String value) {
    _query = value;
    _timer?.cancel();
    _timer = Timer(pickerSearchDelay, () {
      setState(() => _loading = true);
      _fetch();
    });
  }

  static String _duty(String status) => switch (status) {
        'on_duty' => 'On duty',
        'available' => 'Available',
        'off_duty' => 'Off duty',
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PickerSearchField(
            hint: 'Search by name/badge number', onChanged: _onSearch),
        const SizedBox(height: AppSpacing.small),
        Expanded(
          child: _pickerBody(
            loading: _loading,
            error: _error,
            empty: _people.isEmpty,
            emptyText: _query.trim().isEmpty
                ? 'No investigators to assign.'
                : 'No investigators match your search.',
            list: () => ListView.separated(
              itemCount: _people.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.fieldBorder, height: 1),
              itemBuilder: (context, i) {
                final p = _people[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.displayName,
                      style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${p.badgeNumber} · ${_duty(p.dutyStatus)} · '
                    '${p.activeCases} active '
                    '${p.activeCases == 1 ? 'case' : 'cases'}',
                    style: AppText.bodyMuted.copyWith(fontSize: 13),
                  ),
                  onTap: () => widget.onSelected(p),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// NewCaseForm
// ===========================================================================

/// Title + description for a new case. [onCreate] does the saving; if it
/// throws, the error is shown and the form stays open.
class NewCaseForm extends StatefulWidget {
  final String initialTitle;
  final String initialDescription;
  final String buttonLabel;
  final Future<void> Function(String title, String description) onCreate;

  const NewCaseForm({
    super.key,
    this.initialTitle = '',
    this.initialDescription = '',
    this.buttonLabel = 'Create case',
    required this.onCreate,
  });

  @override
  State<NewCaseForm> createState() => _NewCaseFormState();
}

class _NewCaseFormState extends State<NewCaseForm> {
  late final _title = TextEditingController(text: widget.initialTitle);
  late final _description =
      TextEditingController(text: widget.initialDescription);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Give the case a title.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onCreate(_title.text.trim(), _description.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Text('Title', style: AppText.fieldLabel),
        const SizedBox(height: 6),
        TextField(
          controller: _title,
          style: AppText.body,
          maxLength: 150,
          decoration: const InputDecoration(
              hintText: 'e.g. N1 Midrand toll plaza ramming'),
        ),
        const SizedBox(height: AppSpacing.small),
        const Text('Description (optional)', style: AppText.fieldLabel),
        const SizedBox(height: 6),
        TextField(
          controller: _description,
          style: AppText.body,
          minLines: 3,
          maxLines: 6,
          decoration:
              const InputDecoration(hintText: 'What is this case about?'),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.small),
          Text(_error!,
              style: AppText.bodyMuted.copyWith(color: AppColors.danger)),
        ],
        const SizedBox(height: AppSpacing.medium),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _saving ? null : _submit,
            child: Text(_saving ? 'Saving...' : widget.buttonLabel),
          ),
        ),
      ],
    );
  }
}
