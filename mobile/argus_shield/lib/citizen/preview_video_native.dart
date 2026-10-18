import 'dart:io';
import 'package:video_player/video_player.dart';

/// Preview the picker's local file without loading an entire video into memory.
VideoPlayerController createPreviewController(String path) =>
    VideoPlayerController.file(File(path));
