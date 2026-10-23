import 'package:video_player/video_player.dart';

/// On web, image_picker hands us a blob URL.
VideoPlayerController createPreviewController(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));
