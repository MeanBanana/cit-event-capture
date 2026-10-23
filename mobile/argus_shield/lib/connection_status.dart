// Tells people in plain words when the phone has no internet or Supabase
// isn't answering.
//
// `connection` pings the server every 20s when things are fine and every 5s
// while it's down, so the warning clears itself once we're back.
// ConnectionBanner (wrapped around every screen in main.dart) shows a strip
// at the top with a Retry button while there's a problem, then "Back online"
// for a moment. networkErrorText(e) turns raw stuff like "ClientException:
// SocketException: Failed host lookup" into a friendly sentence, and pokes
// the monitor to check right away.
//
// No extra packages, just dart:io, since the app only runs on Android/iOS.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_settings.dart';
import 'theme/app_theme.dart';

/// online: all good. offline: the phone has no internet. serverDown: the
/// phone has internet but our server isn't answering.
enum NetStatus { online, offline, serverDown }

const String noInternetMessage =
    'No internet connection. Check your Wi-Fi or mobile data and try again.';
const String serverDownMessage =
    "The Argus server isn't responding right now. Please try again in a moment.";

class ConnectionMonitor extends ChangeNotifier with WidgetsBindingObserver {
  ConnectionMonitor._();

  static const _supabaseUrl = 'https://tnydrlxptqegzhbvwpcq.supabase.co';
  static const _publishableKey = 'sb_publishable_qyDg3_F69Cy2rpoWDvR-7A_Z3AXR8h3';

  static const _timeout = Duration(seconds: 8);
  static const _whileOnline = Duration(seconds: 20);
  static const _whileDown = Duration(seconds: 5);

  NetStatus _status = NetStatus.online;
  NetStatus get status => _status;
  bool get isOnline => _status == NetStatus.online;

  /// True for a few seconds after we come back online.
  bool _justRecovered = false;
  bool get justRecovered => _justRecovered;

  /// A check is in progress (Retry shows a spinner).
  bool _checking = false;
  bool get checking => _checking;

  bool _started = false;
  bool get started => _started;
  Timer? _timer;
  Timer? _recoveredTimer;

  /// Called once from main(). Widget tests don't start it, so they never hit
  /// the network.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    checkNow();
  }

  /// Check right now (Retry button, or after a request failed).
  Future<void> checkNow() async {
    if (!_started || _checking) return;
    _timer?.cancel();
    _checking = true;
    notifyListeners();
    final result = await _probe();
    _checking = false;
    _setStatus(result);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(isOnline ? _whileOnline : _whileDown, checkNow);
  }

  void _setStatus(NetStatus next) {
    final wasDown = _status != NetStatus.online;
    _status = next;
    if (wasDown && next == NetStatus.online) {
      _justRecovered = true;
      _recoveredTimer?.cancel();
      _recoveredTimer = Timer(const Duration(seconds: 3), () {
        _justRecovered = false;
        notifyListeners();
      });
    } else if (next != NetStatus.online) {
      _justRecovered = false;
    }
    notifyListeners();
  }

  /// Ask Supabase's auth server if it's healthy. Anything under 500 means
  /// it's reachable.
  Future<NetStatus> _probe() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client
          .getUrl(Uri.parse('$_supabaseUrl/auth/v1/health'))
          .timeout(_timeout);
      request.headers.set('apikey', _publishableKey);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>().timeout(_timeout);
      return response.statusCode < 500 ? NetStatus.online : NetStatus.serverDown;
    } catch (_) {
      // no answer, so is it the phone's internet or the server?
      return await _hasInternet() ? NetStatus.serverDown : NetStatus.offline;
    } finally {
      client.close(force: true);
    }
  }

  /// The phone has internet if it can resolve a few well-known sites.
  Future<bool> _hasInternet() async {
    for (final host in const ['google.com', 'cloudflare.com']) {
      try {
        final found = await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 4));
        if (found.isNotEmpty && found.first.rawAddress.isNotEmpty) return true;
      } catch (_) {
        // try the next one
      }
    }
    return false;
  }

  // Don't poll while the app's in the background, and check straight away
  // when they come back to it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkNow();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }
}

/// The one monitor for the whole app.
final connection = ConnectionMonitor._();

/// True if the request never got an answer: no internet, server down or too
/// slow, or the connection dropped halfway.
bool isNetworkError(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException ||
      error is AuthRetryableFetchException) {
    return true;
  }
  final text = error.toString();
  const signs = [
    'SocketException',
    'ClientException',
    'Failed host lookup',
    'Connection refused',
    'Connection reset',
    'Connection closed',
    'Connection timed out',
    'Network is unreachable',
    'No address associated with hostname',
    'HandshakeException',
    'TimeoutException',
  ];
  return signs.any(text.contains);
}

/// Friendly message for a network error (see isNetworkError). Also tells the
/// monitor to check the connection now.
String networkErrorText(Object error) {
  connection.checkNow();
  switch (connection.status) {
    case NetStatus.offline:
      return noInternetMessage;
    case NetStatus.serverDown:
      return serverDownMessage;
    case NetStatus.online:
      // haven't checked yet, but a failed name lookup nearly always means no internet
      final text = error.toString();
      if (text.contains('Failed host lookup') ||
          text.contains('Network is unreachable') ||
          text.contains('No address associated with hostname')) {
        return noInternetMessage;
      }
      return serverDownMessage;
  }
}

/// Shows a strip at the top of every screen while we're offline. Used in
/// main.dart as MaterialApp(builder: ...ConnectionBanner(child: ...)).
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final status = connection.status;
        final show = status != NetStatus.online || connection.justRecovered;
        final media = MediaQuery.of(context);

        return Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: show
                  ? _Strip(status: status, topPadding: media.padding.top)
                  : const SizedBox(width: double.infinity),
            ),
            Expanded(
              // The strip already covers the status bar, so the page below
              // shouldn't add that padding again. (Same widget tree either
              // way, so open screens keep their state.)
              child: MediaQuery.removePadding(
                context: context,
                removeTop: show,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.status, required this.topPadding});

  final NetStatus status;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final t = appSettings.t;
    final recovered = status == NetStatus.online;

    final (Color colour, IconData icon, String title, String body) = switch (status) {
      NetStatus.online => (
          AppColors.success,
          Icons.wifi_rounded,
          t('backOnline'),
          t('backOnlineBody'),
        ),
      NetStatus.offline => (
          AppColors.danger,
          Icons.wifi_off_rounded,
          t('offlineTitle'),
          t('offlineBody'),
        ),
      NetStatus.serverDown => (
          AppColors.accent,
          Icons.cloud_off_rounded,
          t('serverDownTitle'),
          t('serverDownBody'),
        ),
    };
    // dark text on amber, white on red and green
    final ink = status == NetStatus.serverDown ? AppColors.header : Colors.white;

    return Material(
      color: colour,
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, topPadding + 10, 8, 10),
          child: Row(
            children: [
              Icon(icon, color: ink, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(color: ink, fontSize: 12.5)),
                  ],
                ),
              ),
              if (!recovered)
                connection.checking
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: ink,
                          ),
                        ),
                      )
                    : TextButton(
                        onPressed: connection.checkNow,
                        style: TextButton.styleFrom(foregroundColor: ink),
                        child: Text(
                          t('retry'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
            ],
          ),
        ),
      ),
    );
  }
}
