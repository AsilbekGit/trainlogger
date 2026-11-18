/// How a [StationEvent] was created.
enum StationEventType {
  /// Detected automatically: the train stood still long enough to count.
  autoStop('auto_stop', 'Stop'),

  /// Recorded when the user tapped "Mark Station".
  manualMark('manual_mark', 'Marked station');

  const StationEventType(this.code, this.label);

  /// Stable value used in JSON and CSV.
  final String code;

  /// Human-readable name for the UI.
  final String label;

  static StationEventType fromCode(String code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    throw FormatException('Unknown station event type: $code');
  }
}

/// A station-related point on the route: an automatic stop or a manual mark.
///
/// Saved separately from the 50 m [LogRecord]s, so stops and marks never
/// shift the distance milestones. Export merges both into one CSV.
class StationEvent {
  /// 1-based, shared by both types, in the order the events were created.
  final int id;
  final StationEventType type;

  /// UTC ISO 8601. Arrival time for an automatic stop; tap time for a mark.
  final String timestamp;

  /// Automatic stops only: when the train started moving again. Null while
  /// the train is still standing, or when tracking ended before it left.
  final String? departureTimestamp;

  final double latitude;
  final double longitude;
  final double altitudeM;

  /// Speed when the event was recorded. Always 0 for an automatic stop.
  final double speedKmh;

  /// Cumulative tracked distance at the event (not rounded to a 50 m mark).
  final double totalDistanceM;

  /// Manual marks only: seconds between the GPS fix that supplied the position
  /// and speed, and the tap. A large value means GPS was weak (for example
  /// under a station roof), so position and speed are from that earlier fix.
  final double? gpsAgeS;

  const StationEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    this.departureTimestamp,
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
    required this.speedKmh,
    required this.totalDistanceM,
    this.gpsAgeS,
  });

  /// Time standing at an automatic stop, once the departure is known.
  Duration? get dwell {
    final departure = departureTimestamp;
    if (departure == null) return null;
    return DateTime.parse(departure).difference(DateTime.parse(timestamp));
  }

  StationEvent copyWith({
    String? departureTimestamp,
    double? latitude,
    double? longitude,
    double? altitudeM,
  }) => StationEvent(
    id: id,
    type: type,
    timestamp: timestamp,
    departureTimestamp: departureTimestamp ?? this.departureTimestamp,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    altitudeM: altitudeM ?? this.altitudeM,
    speedKmh: speedKmh,
    totalDistanceM: totalDistanceM,
    gpsAgeS: gpsAgeS,
  );
}
