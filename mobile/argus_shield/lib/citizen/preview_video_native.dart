import 'dart:io';
import 'package:video_player/video_player.dart';

/// Plays the picked file straight from disk instead of loading the whole video into memory.
VideoPlayerController createPreviewController(String path) =>
    VideoPlayerController.file(File(path));
