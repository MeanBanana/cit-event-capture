// phone_location.dart — the phone's GPS position when the citizen submits.
//
// Only used if the citizen agrees (a switch on the Upload page). It is the
// FALLBACK location: the AI worker prefers the GPS inside the video / photo
// itself (where it was filmed), which WhatsApp-forwarded files don't have.
// Never blocks a report: no permission, GPS off or no fix within 10 s ->
// the report is sent without it (the typed location still works).

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// (latitude, longitude), or null when it can't be had quickly.
Future<(double, double)?> currentPhoneLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
    return (position.latitude, position.longitude);
  } catch (e) {
    // timeout, no fix indoors ...: fall back to the last known position
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return (last.latitude, last.longitude);
    } catch (_) {}
    debugPrint('Phone location not available: $e');
    return null;
  }
}
