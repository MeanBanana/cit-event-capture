// Full-screen view of one submitted video or photo. Photos get pinch to zoom,
// videos get play/pause and a scrub bar, and there's a Download button that
// saves the original to the gallery.
//
// The file comes from the private bucket using the user's own session, so
// the bucket rules decide who can see it. Videos stream from a signed link
// that lasts an hour.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

class MediaViewerPage extends StatefulWidget {
  /// Bucket path, e.g. "57/media/3f9c....mp4".
  final String storagePath;

  /// 'video' or 'image'
  final String mediaType;

  /// Title at the top, e.g. "INC-0057 · Clip 2".
  final String title;

  /// For the top bar, 'Admin' or 'Investigator'.
  final String roleLabel;

  const MediaViewerPage({
    super.key,
    required this.storagePath,
    required this.mediaType,
    required this.title,
    this.roleLabel = 'Admin',
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  static const _bucket = SupabaseEvidenceSource.bucket;
  final _source = SupabaseEvidenceSource();

  VideoPlayerController? _video;
  String? _error;
  bool _saving = false;

  bool get _isVideo => widget.mediaType != 'image';

  @override
  void initState() {
    super.initState();
    if (_isVideo) _openVideo();
  }

  Future<void> _openVideo() async {
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(widget.storagePath, 3600);
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(() {
        if (mounted) setState(() {}); // update the play/pause icon and position
      });
      setState(() => _video = controller);
      await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'The video could not be played ($e).');
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() => _saving = true);
    String message;
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      final bytes = await _source.bytes(widget.storagePath);
      final fileName = 'argus_${widget.storagePath.replaceAll('/', '_')}';
      if (_isVideo) {
        // Gal can only save videos from a file
        final file = File('${Directory.systemTemp.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        await Gal.putVideo(file.path);
        await file.delete().catchError((_) => file);
      } else {
        await Gal.putImageBytes(bytes, name: fileName.replaceAll(RegExp(r'\.\w+$'), ''));
      }
      message = 'Saved to your gallery';
    } on GalException catch (e) {
      message = e.type == GalExceptionType.accessDenied
          ? 'Allow photo access in Settings to download'
          : 'Could not save the file (${e.type.name})';
    } catch (e) {
      message = 'Could not download the file';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showSnack(context, message);
  }

  String _time(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.inMinutes}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ArgusAppBar(roleLabel: widget.roleLabel),
      backgroundColor: Colors.black,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(widget.title, style: AppText.cardTitle),
          ),
          Expanded(child: Center(child: _isVideo ? _videoView() : _imageView())),
          if (_isVideo && _video != null) _videoControls(_video!),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: _saving ? null : _download,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.header,
                minimumSize: const Size.fromHeight(46),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: Text(_isVideo ? 'Download video' : 'Download photo'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageView() => InteractiveViewer(
        maxScale: 6,
        child: Image(
          image: _source.image(widget.storagePath),
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const CircularProgressIndicator(),
          errorBuilder: (_, _, _) => const Text('The photo could not be loaded.',
              style: AppText.bodyMuted),
        ),
      );

  Widget _videoView() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!, style: AppText.bodyMuted, textAlign: TextAlign.center),
      );
    }
    final video = _video;
    if (video == null) return const CircularProgressIndicator();
    return GestureDetector(
      onTap: () => video.value.isPlaying ? video.pause() : video.play(),
      child: AspectRatio(
        aspectRatio: video.value.aspectRatio == 0 ? 16 / 9 : video.value.aspectRatio,
        child: VideoPlayer(video),
      ),
    );
  }

  Widget _videoControls(VideoPlayerController video) {
    final value = video.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          VideoProgressIndicator(
            video,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: AppColors.accent,
              bufferedColor: AppColors.textHint,
              backgroundColor: AppColors.header,
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: AppColors.textPrimary),
                tooltip: value.isPlaying ? 'Pause' : 'Play',
                onPressed: () => value.isPlaying ? video.pause() : video.play(),
              ),
              IconButton(
                icon: const Icon(Icons.replay_10, color: AppColors.textPrimary),
                tooltip: 'Back 10 seconds',
                onPressed: () => video.seekTo(value.position - const Duration(seconds: 10)),
              ),
              const Spacer(),
              Text('${_time(value.position)} / ${_time(value.duration)}',
                  style: AppText.bodyMuted),
            ],
          ),
        ],
      ),
    );
  }
}
