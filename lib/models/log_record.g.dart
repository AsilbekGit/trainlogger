// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'log_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class LogRecordAdapter extends TypeAdapter<LogRecord> {
  @override
  final int typeId = 0;

  @override
  LogRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LogRecord(
      index: fields[0] as int,
      timestamp: fields[1] as String,
      latitude: fields[2] as double,
      longitude: fields[3] as double,
      speedKmh: fields[4] as double,
      altitudeM: fields[5] as double,
      segmentDistanceM: fields[6] as double,
      elevationDeltaM: fields[7] as double?,
      gradePercent: fields[8] as double?,
      totalDistanceM: fields[9] as double,
    );
  }

  @override
  void write(BinaryWriter writer, LogRecord obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.index)
      ..writeByte(1)
      ..write(obj.timestamp)
      ..writeByte(2)
      ..write(obj.latitude)
      ..writeByte(3)
      ..write(obj.longitude)
      ..writeByte(4)
      ..write(obj.speedKmh)
      ..writeByte(5)
      ..write(obj.altitudeM)
      ..writeByte(6)
      ..write(obj.segmentDistanceM)
      ..writeByte(7)
      ..write(obj.elevationDeltaM)
      ..writeByte(8)
      ..write(obj.gradePercent)
      ..writeByte(9)
      ..write(obj.totalDistanceM);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
