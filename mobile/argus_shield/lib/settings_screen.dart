import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'app_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(appSettings.t('settings')),
            backgroundColor: AppColors.header,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                appSettings.t('language'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              // RadioGroup tracks which of the three languages is picked
              RadioGroup<String>(
                groupValue: appSettings.language,
                onChanged: (value) {
                  if (value != null) appSettings.setLanguage(value);
                },
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      title: Text('English'),
                      value: 'English',
                    ),
                    RadioListTile<String>(
                      title: Text('Afrikaans'),
                      value: 'Afrikaans',
                    ),
                    RadioListTile<String>(
                      title: Text('Zulu'),
                      value: 'Zulu',
                    ),
                  ],
                ),
              ),
              const Divider(),
              Text(
                appSettings.t('display'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SwitchListTile(
                title: Text(appSettings.t('darkMode')),
                value: appSettings.isDarkMode,
                onChanged: appSettings.setDarkMode,
              ),
            ],
          ),
        );
      },
    );
  }
}
