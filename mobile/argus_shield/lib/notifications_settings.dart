import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:argus_shield/theme/app_theme.dart';

/// Notification choices saved on this device for one investigator account.
class NotificationPreferencesStore {
  NotificationPreferencesStore({String? userId})
      : _key = 'argus.notification_preferences.${userId ?? 'device'}';

  final String _key;

  static const Map<String, bool> defaults = {
    'case_assignments': true,
    'case_activity': true,
    'new_evidence': true,
    'urgent_alerts': true,
  };

  Future<Map<String, bool>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_key);
    if (stored == null) return Map.of(defaults);

    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Saved notification settings are invalid.');
    }
    return {
      for (final entry in defaults.entries)
        entry.key: decoded[entry.key] is bool
            ? decoded[entry.key] as bool
            : entry.value,
    };
  }

  Future<void> save(Map<String, bool> values) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(_key, jsonEncode(values));
    if (!saved) {
      throw StateError('Could not save notification settings.');
    }
  }
}

class NotificationsSettingsPage extends StatefulWidget {
  final String? userId;

  const NotificationsSettingsPage({super.key, this.userId});

  @override
  State<NotificationsSettingsPage> createState() =>
      _NotificationsSettingsPageState();
}

class _NotificationsSettingsPageState extends State<NotificationsSettingsPage> {
  late final NotificationPreferencesStore _store =
      NotificationPreferencesStore(userId: widget.userId);
  Map<String, bool> _values = Map.of(NotificationPreferencesStore.defaults);
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await _store.load();
      if (!mounted) return;
      setState(() {
        _values = values;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load notification settings: $error';
        _loading = false;
      });
    }
  }

  Future<void> _setPreference(String key, bool value) async {
    if (_saving || _loading) return;
    final previous = Map<String, bool>.of(_values);
    final updated = Map<String, bool>.of(_values)..[key] = value;
    setState(() {
      _values = updated;
      _saving = true;
    });
    try {
      await _store.save(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _values = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save notification settings: $error'),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.textPrimary,
      ),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          const Text('Choose your alerts', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.small),
          const Text(
            'Turn the notifications you need on or off. Your choices are '
            'saved for this account on this device. App notification delivery '
            'will need to be enabled separately.',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpacing.large),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null) ...[
            Text(
              _error!,
              style: AppText.bodyMuted.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: AppSpacing.small),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ),
          ] else ...[
            for (final preference in _notificationTypes)
              _PreferenceTile(
                preference: preference,
                value: _values[preference.key] ?? true,
                enabled: !_saving,
                onChanged: (value) =>
                    _setPreference(preference.key, value),
              ),
          ],
        ],
      ),
    );
  }
}

class _NotificationType {
  final String key;
  final String title;
  final String description;
  final IconData icon;

  const _NotificationType({
    required this.key,
    required this.title,
    required this.description,
    required this.icon,
  });
}

const _notificationTypes = [
  _NotificationType(
    key: 'case_assignments',
    title: 'Case assignments',
    description: 'When a new investigation is assigned to you.',
    icon: Icons.assignment_outlined,
  ),
  _NotificationType(
    key: 'case_activity',
    title: 'Case updates',
    description: 'Status changes and activity on your assigned cases.',
    icon: Icons.update_outlined,
  ),
  _NotificationType(
    key: 'new_evidence',
    title: 'New reports and evidence',
    description: 'When reports or footage are added to your cases.',
    icon: Icons.video_library_outlined,
  ),
  _NotificationType(
    key: 'urgent_alerts',
    title: 'Urgent alerts',
    description: 'Time-sensitive activity that may need prompt attention.',
    icon: Icons.priority_high,
  ),
];

class _PreferenceTile extends StatelessWidget {
  final _NotificationType preference;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _PreferenceTile({
    required this.preference,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.small),
      color: AppColors.header,
      child: SwitchListTile(
        key: ValueKey('notification-${preference.key}'),
        value: value,
        onChanged: enabled ? onChanged : null,
        activeThumbColor: AppColors.accent,
        secondary: Icon(preference.icon, color: AppColors.accent),
        title: Text(preference.title, style: AppText.body),
        subtitle: Text(preference.description, style: AppText.bodyMuted),
      ),
    );
  }
}
