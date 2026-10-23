// A submission's clips/photos, each with what the AI saw in it and a View
// button. Used on the admin's submission page and the investigator's case
// page.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/media_viewer_page.dart';

/// True if [service] is the real database. The widget tests' fakes return
/// false and skip the AI pictures and footage, since those hit Supabase
/// directly.
bool usesRealDatabase(SupabaseService? service) =>
    service == null || service.runtimeType == SupabaseService;

class FootageList extends StatefulWidget {
  final SupabaseService service;
  final int incidentId;

  /// e.g. "INC-0057", used in the viewer title ("INC-0057 · Clip 2").
  final String reference;

  /// For the viewer's top bar.
  final String roleLabel;

  const FootageList({
    super.key,
    required this.service,
    required this.incidentId,
    required this.reference,
    this.roleLabel = 'Admin',
  });

  @override
  State<FootageList> createState() => _FootageListState();
}

class _FootageListState extends State<FootageList> {
  late final Future<List<MediaItem>> _media =
      widget.service.getIncidentMedia(widget.incidentId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: _media,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Text('Could not load the footage list.',
              style: AppText.bodyMuted);
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final clips = snap.data!;
        if (clips.isEmpty) {
          return const Text('No footage.', style: AppText.bodyMuted);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < clips.length; i++)
              ClipCard(
                number: i + 1,
                clip: clips[i],
                onView: clips[i].mediaType == 'audio'
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MediaViewerPage(
                              storagePath: clips[i].storagePath,
                              mediaType: clips[i].mediaType,
                              title: '${widget.reference} · Clip ${i + 1}',
                              roleLabel: widget.roleLabel,
                            ),
                          ),
                        ),
              ),
          ],
        );
      },
    );
  }
}

/// One clip/photo and what the AI saw in it.
class ClipCard extends StatelessWidget {
  final int number;
  final MediaItem clip;

  /// Opens it. Null hides the View button.
  final VoidCallback? onView;

  const ClipCard(
      {super.key, required this.number, required this.clip, this.onView});

  @override
  Widget build(BuildContext context) {
    final c = clip;
    final icon = switch (c.mediaType) {
      'image' => Icons.photo_outlined,
      'audio' => Icons.mic_none,
      _ => Icons.videocam_outlined,
    };
    final (statusText, statusColor) = switch (c.processingStatus) {
      'completed' => ('Analysed', AppColors.success),
      'processing' => ('Analysing…', AppColors.accent),
      'failed' => ('Analysis failed', AppColors.danger),
      _ => ('Waiting for analysis', AppColors.neutral),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Clip $number'
                  '${c.captured == null ? '' : ' · ${formatDateTime(c.captured!)}'}',
                  style: AppText.body.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (onView != null) ...[
                const SizedBox(width: 8),
                SmallActionButton(
                  label: 'View',
                  color: AppColors.accent,
                  onPressed: onView,
                ),
              ],
            ],
          ),
          // its own line, because a long tag like "Waiting for analysis" plus
          // the View button won't fit beside the title on a phone
          const SizedBox(height: 6),
          StatusTag(label: statusText, color: statusColor),
          const SizedBox(height: 6),
          Text(
            c.aiDescription ?? 'No AI description yet.',
            style: c.aiDescription == null
                ? AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic)
                : AppText.body.copyWith(fontSize: 15),
          ),
          if (c.detections > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${plural(c.detections, 'detection')}'
              '${c.verified > 0 ? ' · ${c.verified} confirmed by an investigator' : ''}',
              style: AppText.bodyMuted.copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
      ),
    );
  }
}
