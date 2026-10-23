// The phone's GPS position at the moment a citizen submits.
//
// Only if they agree (there's a switch on the Upload page). It's just a
// fallback: the worker prefers GPS from inside the footage, which is where it
// was actually filmed, but WhatsApp-forwarded files don't have that. This
// never holds up a report. No permission, GPS off or no fix in 10s and the
// report just goes without it.

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// (latitude, longitude), or null if we can't get one quickly.
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
    // timed out or no fix indoors, so fall back to the last known position
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return (last.latitude, last.longitude);
    } catch (_) {}
    debugPrint('Phone location not available: $e');
    return null;
  }
}
