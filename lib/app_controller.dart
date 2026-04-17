import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_models.dart';

enum StartSessionResult {
  started,
  permissionDenied,
  alreadyRunning,
  failed,
}

class AppController extends ChangeNotifier {
  AppController._(this._prefs);

  static const MethodChannel _appChannel = MethodChannel('time_tracker/app');

  static const String _kRecords = 'records_v2';
  static const String _kActiveSession = 'active_session_v2';
  static const String _kOverlayPrefs = 'overlay_prefs_v2';
  static const String _kPendingSettlement = 'pending_settlement_v2';

  final SharedPreferences _prefs;

  final List<SessionRecord> _records = <SessionRecord>[];

  OverlayPreferences _overlayPreferences = OverlayPreferences.defaults;
  ActiveSession? _activeSession;
  SessionRecord? _pendingSettlement;
  StreamSubscription<dynamic>? _overlaySubscription;
  String? _lastError;

  static Future<AppController> create() async {
    final prefs = await SharedPreferences.getInstance();
    final controller = AppController._(prefs);
    await controller._loadFromDisk();
    controller._bindOverlayListener();
    
    // Heartbeat for debugging
    Timer.periodic(const Duration(seconds: 15), (timer) {
      debugPrint('[AppController] Heartbeat - Active: ${controller._activeSession != null}, Records: ${controller._records.length}');
    });
    
    return controller;
  }

  List<SessionRecord> get records => List<SessionRecord>.unmodifiable(_records);

  OverlayPreferences get overlayPreferences => _overlayPreferences;

  ActiveSession? get activeSession => _activeSession;

  SessionRecord? get pendingSettlement => _pendingSettlement;

  String? get lastError => _lastError;

  Future<StartSessionResult> startSession() async {
    if (_activeSession != null) {
      return StartSessionResult.alreadyRunning;
    }

    final granted = await _ensureOverlayPermission();
    if (!granted) {
      return StartSessionResult.permissionDenied;
    }

    try {
      // 1. Prepare data first
      _activeSession = ActiveSession.start();
      _lastError = null;
      await _saveActiveSession();
      _safeNotify();

      // 2. Ensure previous overlay is closed
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // 3. Show new overlay
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: '计时器',
        overlayContent: '正在记录时间',
        alignment: OverlayAlignment.centerLeft,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        flag: OverlayFlag.defaultFlag,
        width: _overlayPreferences.overlayWidth,
        height: _overlayPreferences.overlayHeight,
      );

      // 4. Repeatedly try to sync for a short period to ensure the overlay gets it
      // as it might still be initializing.
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration(milliseconds: 300 * (i + 1)));
        if (!await FlutterOverlayWindow.isActive()) break;
        if (_activeSession != null && _activeSession!.totalSeconds == 0) {
          await syncOverlayNow();
        }
      }
      
      return StartSessionResult.started;
    } catch (error) {
      debugPrint('[AppController] Start session error: $error');
      _lastError = '$error';
      _activeSession = null;
      await _saveActiveSession();
      _safeNotify();
      return StartSessionResult.failed;
    }
  }

  Future<void> syncOverlayNow() async {
    await _sendSettingsToOverlay();
    await _sendSessionToOverlay();
  }

  Future<void> finishSessionFromMain() async {
    final session = _activeSession;
    if (session == null) {
      return;
    }

    _pendingSettlement = SessionRecord.fromActiveSession(
      session: session,
      endedAt: DateTime.now(),
    );
    _activeSession = null;

    await Future.wait(<Future<void>>[
      _savePendingSettlement(),
      _saveActiveSession(),
    ]);

    if (await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.closeOverlay();
    }

    _safeNotify();
  }

  Future<void> savePendingSettlement() async {
    final pending = _pendingSettlement;
    if (pending == null) {
      return;
    }

    _records.insert(0, pending);
    _pendingSettlement = null;

    await Future.wait(<Future<void>>[
      _saveRecords(),
      _savePendingSettlement(),
    ]);

    _safeNotify();
  }

  Future<void> discardPendingSettlement() async {
    _pendingSettlement = null;
    await _savePendingSettlement();
    _safeNotify();
  }

  Future<void> forceStopSession({bool saveLastKnown = true}) async {
    final session = _activeSession;
    if (saveLastKnown && session != null && session.totalSeconds > 0) {
      _pendingSettlement = SessionRecord.fromActiveSession(
        session: session,
        endedAt: DateTime.now(),
      );
      await _savePendingSettlement();
    }
    
    _activeSession = null;
    await _saveActiveSession();
    if (await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.closeOverlay();
    }
    _safeNotify();
  }

  Future<void> updateOverlayPreferences(OverlayPreferences preferences) async {
    _overlayPreferences = preferences;
    await _saveOverlayPreferences();

    if (await FlutterOverlayWindow.isActive()) {
      await _sendSettingsToOverlay();
      await FlutterOverlayWindow.resizeOverlay(
        _overlayPreferences.overlayWidth,
        _overlayPreferences.overlayHeight,
        true,
      );
    }

    _safeNotify();
  }

  Future<void> _loadFromDisk() async {
    _records
      ..clear()
      ..addAll(_readList(_kRecords, SessionRecord.fromJson));

    _records.sort((a, b) => b.endedAt.compareTo(a.endedAt));

    _overlayPreferences = _readSingle(
          _kOverlayPrefs,
          OverlayPreferences.fromJson,
        ) ??
        OverlayPreferences.defaults;

    _activeSession = _readSingle(_kActiveSession, ActiveSession.fromJson);
    _pendingSettlement =
        _readSingle(_kPendingSettlement, SessionRecord.fromJson);
  }

  List<T> _readList<T>(
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return <T>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <T>[];
      
      return decoded.map((item) {
        if (item is Map) {
          return fromJson(item.map((k, v) => MapEntry('$k', v)));
        }
        return null;
      }).whereType<T>().toList();
    } catch (e) {
      debugPrint('[AppController] Error reading list $key: $e');
      return <T>[];
    }
  }

  T? _readSingle<T>(
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return fromJson(decoded.map((k, v) => MapEntry('$k', v)));
    } catch (e) {
      debugPrint('[AppController] Error reading single $key: $e');
      return null;
    }
  }

  Future<void> _saveRecords() async {
    final payload = jsonEncode(_records.map((record) => record.toJson()).toList());
    await _prefs.setString(_kRecords, payload);
  }

  Future<void> _saveActiveSession() async {
    if (_activeSession == null) {
      await _prefs.remove(_kActiveSession);
      return;
    }

    await _prefs.setString(
      _kActiveSession,
      jsonEncode(_activeSession!.toJson()),
    );
  }

  Future<void> _savePendingSettlement() async {
    if (_pendingSettlement == null) {
      await _prefs.remove(_kPendingSettlement);
      return;
    }

    await _prefs.setString(
      _kPendingSettlement,
      jsonEncode(_pendingSettlement!.toJson()),
    );
  }

  Future<void> _saveOverlayPreferences() async {
    await _prefs.setString(
      _kOverlayPrefs,
      jsonEncode(_overlayPreferences.toJson()),
    );
  }

  Future<bool> _ensureOverlayPermission() async {
    var granted = await FlutterOverlayWindow.isPermissionGranted();
    if (granted) {
      return true;
    }

    final result = await FlutterOverlayWindow.requestPermission();
    granted = result == true;
    return granted;
  }

  void _bindOverlayListener() {
    _overlaySubscription = FlutterOverlayWindow.overlayListener.listen(
      _onOverlayMessage,
      onError: (Object error, StackTrace stackTrace) {
        _lastError = '$error';
        _safeNotify();
      },
    );
  }

  Future<void> _onOverlayMessage(dynamic raw) async {
    final message = asStringKeyedMap(raw);
    if (message == null || message['source'] != 'overlay') {
      return;
    }

    final type = message['type'] as String?;
    if (type == null) {
      return;
    }

    // Comprehensive logging for debugging
    debugPrint('[AppController] Overlay message: $type, data: ${jsonEncode(message)}');

    switch (type) {
      case 'request_sync':
        await syncOverlayNow();
        break;
      case 'tick':
      case 'lap':
      case 'pause_state':
        await _handleSessionUpdate(message);
        break;
      case 'finished':
        await _handleSessionFinished(message);
        break;
      default:
        break;
    }
  }

  Future<void> _handleSessionUpdate(Map<String, dynamic> message) async {
    final runMap = asStringKeyedMap(message['run']);
    if (runMap == null) {
      debugPrint('[AppController] Update failed: run data is null');
      return;
    }

    final newSession = ActiveSession.fromJson(runMap);
    
    // Only update if the new session is further ahead or if it's a state change
    if (_activeSession == null || 
        newSession.totalSeconds >= _activeSession!.totalSeconds ||
        newSession.isPaused != _activeSession!.isPaused ||
        newSession.laps.length != _activeSession!.laps.length) {
      
      _activeSession = newSession;
      
      if (_activeSession!.totalSeconds % 10 == 0) {
        await _saveActiveSession();
      }
      _safeNotify();
    }
  }

  Future<void> _handleSessionFinished(Map<String, dynamic> message) async {
    debugPrint('[AppController] Handling session finished');
    try {
      final runMap = asStringKeyedMap(message['run']);
      if (runMap == null) {
        debugPrint('[AppController] Error: run data is null in finished message');
        return;
      }

      final endedAtMs = (message['endedAtMs'] as num?)?.toInt();
      final endedAt = endedAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(endedAtMs);

      final session = ActiveSession.fromJson(runMap);
      _pendingSettlement = SessionRecord.fromActiveSession(
        session: session,
        endedAt: endedAt,
      );
      _activeSession = null;

      await Future.wait(<Future<void>>[
        _savePendingSettlement(),
        _saveActiveSession(),
      ]);

      debugPrint('[AppController] Session finished and SAVED. Pending settlement ready.');
      await _bringAppToFront();
      _safeNotify();
    } catch (e, stack) {
      debugPrint('[AppController] CRITICAL ERROR handling finished message: $e');
      debugPrint('$stack');
      _lastError = '结算数据处理失败: $e';
      _safeNotify();
    }
  }

  Future<void> _bringAppToFront() async {
    try {
      await _appChannel.invokeMethod<bool>('bringToFront');
    } catch (_) {
      // Non-fatal
    }
  }

  Future<void> _sendSessionToOverlay() async {
    await FlutterOverlayWindow.shareData(<String, dynamic>{
      'source': 'app',
      'type': 'sync',
      'run': _activeSession?.toJson(),
    });
  }

  Future<void> _sendSettingsToOverlay() async {
    await FlutterOverlayWindow.shareData(<String, dynamic>{
      'source': 'app',
      'type': 'settings',
      'settings': _overlayPreferences.toJson(),
    });
  }

  void _safeNotify() {
    if (!hasListeners) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _overlaySubscription?.cancel();
    super.dispose();
  }
}
