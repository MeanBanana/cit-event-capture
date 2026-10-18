import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';
import 'preview_video_native.dart'
if (dart.library.html) 'preview_video_web.dart' as platform;

/// Previews local footage without uploading or editing the original file.
class MediaPreviewPage extends StatefulWidget {
  final XFile file;
  final bool isImage;

  const MediaPreviewPage({
    super.key,
    required this.file,
    required this.isImage,
  });

  @override
  State<MediaPreviewPage> createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage>
    with WidgetsBindingObserver {
  Future<Uint8List>? _image;
  VideoPlayerController? _video;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.isImage) {
      // Read once so rebuilding does not reload the image.
      _image = widget.file.readAsBytes();
    } else {
      _initialiseVideo();
    }
  }

  Future<void> _initialiseVideo() async {
    try {
      final controller = platform.createPreviewController(widget.file.path);
      _video = controller;

      await controller.initialize();

      if (!mounted) {
        return;
      }

      setState(() {
        _ready = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'This video could not be previewed. '
              'It may use a format your device cannot play.';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _video?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _video?.dispose();
    super.dispose();
  }

  Widget _message(String text) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppText.bodyMuted,
      ),
    );
  }

  String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }

  Widget _buildImagePreview() {
    return FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _message('This photo could not be opened.');
        }

        if (!snapshot.hasData) {
          return const CircularProgressIndicator();
        }

        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            // Limit decoded memory for large camera photos.
            cacheWidth: 1920,
            errorBuilder: (context, error, stackTrace) {
              return _message(
                'This image format cannot be previewed on your device.',
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _togglePlayback(VideoPlayerController video) async {
    try {
      if (video.value.isPlaying) {
        await video.pause();
      } else {
        if (video.value.position >= video.value.duration) {
          await video.seekTo(Duration.zero);
        }

        if (!mounted) {
          return;
        }

        await video.play();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Unable to play this video.';
        });
      }
    }
  }

  Widget _buildVideoPreview() {
    final video = _video;

    if (_error != null) {
      return _message(_error!);
    }

    if (!_ready || video == null) {
      return const CircularProgressIndicator();
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: video,
      builder: (context, value, child) {
        if (value.hasError) {
          return _message(
            'Video playback failed. '
                'Try selecting another supported video.',
          );
        }

        return Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio:
                  value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                  child: VideoPlayer(video),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: VideoProgressIndicator(
                video,
                allowScrubbing: true,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: value.isPlaying ? 'Pause' : 'Play',
                  iconSize: 44,
                  color: AppColors.accent,
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_circle
                        : Icons.play_circle,
                  ),
                  onPressed: () => _togglePlayback(video),
                ),
                Text(
                  '${_time(value.position)} / ${_time(value.duration)}',
                  style: AppText.bodyMuted,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.textPrimary,
      ),
      body: SafeArea(
        child: Center(
          child: widget.isImage
              ? _buildImagePreview()
              : _buildVideoPreview(),
        ),
      ),
    );
  }
}
