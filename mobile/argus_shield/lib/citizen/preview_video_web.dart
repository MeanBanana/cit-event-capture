import 'package:video_player/video_player.dart';

/// On web, image_picker supplies a browser blob URL.
VideoPlayerController createPreviewController(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));
