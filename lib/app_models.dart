import 'dart:math';

class OverlayPreferences {
  const OverlayPreferences({
    required this.opacity,
    required this.scale,
  });

  static const OverlayPreferences defaults = OverlayPreferences(
    opacity: 0.85,
    scale: 1,
  );

  final double opacity;
  final double scale;

  int get overlayWidth => (300 * scale).round().clamp(240, 520);
  int get overlayHeight => (180 * scale).round().clamp(140, 400);

  OverlayPreferences copyWith({
    double? opacity,
    double? scale,
  }) {
    return OverlayPreferences(
      opacity: opacity ?? this.opacity,
      scale: scale ?? this.scale,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'opacity': opacity,
      'scale': scale,
    };
  }

  static OverlayPreferences fromJson(Map<String, dynamic> json) {
    return OverlayPreferences(
      opacity: (json['opacity'] as num?)?.toDouble() ?? defaults.opacity,
      scale: (json['scale'] as num?)?.toDouble() ?? defaults.scale,
    );
  }
}

class ActiveSession {
  ActiveSession({
    required this.id,
    required this.startedAt,
    required this.totalSeconds,
    required this.currentLapSeconds,
    required this.laps,
    required this.isPaused,
  });

  factory ActiveSession.start() {
    return ActiveSession(
      id: generateId('run'),
      startedAt: DateTime.now(),
      totalSeconds: 0,
      currentLapSeconds: 0,
      laps: const <int>[],
      isPaused: false,
    );
  }

  final String id;
  final DateTime startedAt;
  final int totalSeconds;
  final int currentLapSeconds;
  final List<int> laps;
  final bool isPaused;

  ActiveSession copyWith({
    String? id,
    DateTime? startedAt,
    int? totalSeconds,
    int? currentLapSeconds,
    List<int>? laps,
    bool? isPaused,
  }) {
    return ActiveSession(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      currentLapSeconds: currentLapSeconds ?? this.currentLapSeconds,
      laps: laps ?? this.laps,
      isPaused: isPaused ?? this.isPaused,
    );
  }

  ActiveSession tick() {
    if (isPaused) {
      return this;
    }
    return copyWith(
      totalSeconds: totalSeconds + 1,
      currentLapSeconds: currentLapSeconds + 1,
    );
  }

  ActiveSession recordLap() {
    final nextLaps = List<int>.from(laps)..add(currentLapSeconds);
    return copyWith(
      laps: nextLaps,
      currentLapSeconds: 0,
    );
  }

  ActiveSession togglePause() {
    return copyWith(isPaused: !isPaused);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'startedAt': startedAt.toIso8601String(),
      'totalSeconds': totalSeconds,
      'currentLapSeconds': currentLapSeconds,
      'laps': laps,
      'isPaused': isPaused,
    };
  }

  static ActiveSession fromJson(Map<String, dynamic> json) {
    return ActiveSession(
      id: json['id'] as String,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
      totalSeconds: json['totalSeconds'] as int? ?? 0,
      currentLapSeconds: json['currentLapSeconds'] as int? ?? 0,
      laps: (json['laps'] as List<dynamic>?)?.map((e) => e as int).toList() ?? const <int>[],
      isPaused: json['isPaused'] as bool? ?? false,
    );
  }
}

class SessionRecord {
  SessionRecord({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.totalSeconds,
    required this.laps,
  });

  factory SessionRecord.fromActiveSession({
    required ActiveSession session,
    required DateTime endedAt,
  }) {
    final finalLaps = List<int>.from(session.laps);
    if (session.currentLapSeconds > 0) {
      finalLaps.add(session.currentLapSeconds);
    }
    return SessionRecord(
      id: generateId('record'),
      startedAt: session.startedAt,
      endedAt: endedAt,
      totalSeconds: session.totalSeconds,
      laps: finalLaps,
    );
  }

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final int totalSeconds;
  final List<int> laps;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'totalSeconds': totalSeconds,
      'laps': laps,
    };
  }

  static SessionRecord fromJson(Map<String, dynamic> json) {
    return SessionRecord(
      id: json['id'] as String,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
      endedAt: DateTime.tryParse(json['endedAt'] as String? ?? '') ?? DateTime.now(),
      totalSeconds: json['totalSeconds'] as int? ?? 0,
      laps: (json['laps'] as List<dynamic>?)?.map((e) => e as int).toList() ?? const <int>[],
    );
  }
}

String generateId(String prefix) {
  final rnd = Random();
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-${rnd.nextInt(1 << 32)}';
}

String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String formatDateTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

Map<String, dynamic>? asStringKeyedMap(dynamic data) {
  if (data is! Map) {
    return null;
  }
  return data.map((key, value) => MapEntry('$key', value));
}
