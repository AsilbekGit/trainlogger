import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:train_logger/services/location_service.dart';

Position _position() => Position(
  latitude: 41,
  longitude: 69,
  timestamp: DateTime.utc(2026),
  accuracy: 5,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 0,
  headingAccuracy: 0,
  speed: 10,
  speedAccuracy: 1,
);

void main() {
  test(
    'restart waits for the previous native subscription to cancel',
    () async {
      final cancellation = Completer<void>();
      final first = StreamController<Position>(
        sync: true,
        onCancel: () => cancellation.future,
      );
      final second = StreamController<Position>(sync: true);
      var streamRequests = 0;
      final location = LocationService(
        positionStreamFactory: (_) {
          streamRequests++;
          return streamRequests == 1 ? first.stream : second.stream;
        },
      );
      final received = <Position>[];
      final listener = location.positionStream.listen(received.add);
      await location.startListening();
      first.add(_position());
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      location.stopListening();
      // A late native event must not leak into a stopped/new tracking session.
      first.add(_position());
      final restart = location.startListening();
      await Future<void>.delayed(Duration.zero);
      expect(streamRequests, 1);
      expect(received, hasLength(1));
      cancellation.complete();
      await restart;
      expect(streamRequests, 2);
      second.add(_position());
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      await listener.cancel();
      location.dispose();
      await first.close();
      await second.close();
    },
  );

  test('dispose invalidates starts awaiting native cancellation', () async {
    final cancellation = Completer<void>();
    final source = StreamController<Position>(
      onCancel: () => cancellation.future,
    );
    var requests = 0;
    final location = LocationService(
      positionStreamFactory: (_) {
        requests++;
        return source.stream;
      },
    );
    await location.startListening();
    final restarting = location.startListening();
    location.dispose();
    cancellation.complete();
    await restarting;
    expect(requests, 1);
    await source.close();
    await expectLater(location.startListening(), throwsStateError);
  });

  test(
    'unexpected native stream completion is forwarded as an error',
    () async {
      final source = StreamController<Position>();
      final location = LocationService(
        positionStreamFactory: (_) => source.stream,
      );
      final errors = <Object>[];
      final listener = location.positionStream.listen(
        (_) {},
        onError: errors.add,
      );
      await location.startListening();
      await source.close();
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
      await listener.cancel();
      location.dispose();
    },
  );
}
