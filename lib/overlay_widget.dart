import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'app_models.dart';

class FloatingTimerWidget extends StatefulWidget {
  const FloatingTimerWidget({super.key});

  @override
  State<FloatingTimerWidget> createState() => _FloatingTimerWidgetState();
}

class _FloatingTimerWidgetState extends State<FloatingTimerWidget> {
  // Give app-side listener and SharedPreferences writes enough time to finish
  // before forcing overlay shutdown on slower/background-throttled devices.
  static const Duration _finishedSendTimeout = Duration(seconds: 3);
  static const Duration _endSessionCloseFallbackTimeout = Duration(seconds: 8);

  ActiveSession? _session;
  OverlayPreferences _preferences = OverlayPreferences.defaults;

  StreamSubscription<dynamic>? _overlaySub;
  Timer? _tickTimer;
  Timer? _hintTimer;
  Timer? _endSessionSafetyTimer;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayMessage);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), _onTick);

    // More aggressive sync request on start
    _requestSyncLoop();
  }

  Future<void> _requestSyncLoop() async {
    for (var i = 0; i < 3; i++) {
      if (!mounted || _session != null) break;
      await _sendMessage('request_sync');
      await Future<void>.delayed(Duration(milliseconds: 500 * (i + 1)));
    }
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    _tickTimer?.cancel();
    _hintTimer?.cancel();
    _endSessionSafetyTimer?.cancel();
    super.dispose();
  }

  void _onTick(Timer timer) {
    final session = _session;
    if (session == null) {
      return;
    }
    
    if (session.isPaused) {
      return;
    }

    final updated = session.tick();
    setState(() {
      _session = updated;
    });

    // Use unawaited for ticks to avoid blocking the UI thread
    unawaited(_sendMessage('tick', <String, dynamic>{'run': updated.toJson()}));
  }

  Future<void> _onOverlayMessage(dynamic raw) async {
    final message = asStringKeyedMap(raw);
    if (message == null || message['source'] != 'app') {
      return;
    }

    final type = message['type'] as String?;
    if (type == null) {
      return;
    }

    switch (type) {
      case 'sync':
        final runMap = asStringKeyedMap(message['run']);
        if (runMap == null) {
          setState(() {
            _session = null;
          });
        } else {
          final newSession = ActiveSession.fromJson(runMap);
          // Only update if we don't have a session, or if the new one is significantly different
          // (e.g. state change or much further ahead/behind). 
          // Avoid overwriting local ticks with slightly older app state.
          if (_session == null || 
              (newSession.totalSeconds - _session!.totalSeconds).abs() > 5 ||
              newSession.isPaused != _session!.isPaused) {
            setState(() {
              _session = newSession;
            });
          }
        }
        break;
      case 'settings':
        final settingMap = asStringKeyedMap(message['settings']);
        if (settingMap == null) return;
        final nextPrefs = OverlayPreferences.fromJson(settingMap);
        setState(() {
          _preferences = nextPrefs;
        });
        await FlutterOverlayWindow.resizeOverlay(
          nextPrefs.overlayWidth,
          nextPrefs.overlayHeight,
          true,
        );
        break;
      case 'close':
        _endSessionSafetyTimer?.cancel();
        _endSessionSafetyTimer = null;
        await FlutterOverlayWindow.closeOverlay();
        break;
      default:
        break;
    }
  }

  Future<void> _pauseOrResume() async {
    debugPrint('[Overlay] Pause/Resume clicked');
    final session = _session;
    if (session == null) return;

    final updated = session.togglePause();
    setState(() {
      _session = updated;
    });

    _showHint(updated.isPaused ? '已暂停' : '继续计时');
    await _sendMessage(
      'pause_state',
      <String, dynamic>{'run': updated.toJson()},
    );
  }

  Future<void> _recordLap() async {
    debugPrint('[Overlay] Record lap clicked');
    final session = _session;
    if (session == null) return;

    if (session.isPaused) {
      _showHint('请先继续计时');
      return;
    }

    final updated = session.recordLap();
    final lapDuration = session.currentLapSeconds;

    setState(() {
      _session = updated;
    });

    _showHint('记录：${formatDuration(lapDuration)}');
    await _sendMessage(
      'lap',
      <String, dynamic>{'run': updated.toJson()},
    );
  }

  Future<void> _endSession() async {
    debugPrint('[Overlay] End session button clicked');
    
    final session = _session;
    if (session == null) {
      debugPrint('[Overlay] Session is already null, just closing');
      await FlutterOverlayWindow.closeOverlay();
      return;
    }

    final sessionData = session.toJson();

    setState(() {
      _session = null;
    });

    _endSessionSafetyTimer?.cancel();
    _endSessionSafetyTimer = Timer(_endSessionCloseFallbackTimeout, () {
      debugPrint(
        '[Overlay] Safety fallback after $_endSessionCloseFallbackTimeout: force closing overlay now',
      );
      unawaited(
        FlutterOverlayWindow.closeOverlay().catchError((Object e) {
          debugPrint('[Overlay] Error closing overlay in safety fallback: $e');
        }),
      );
    });

    try {
      debugPrint('[Overlay] Sending finished message to app...');
      await _sendMessage(
        'finished',
        <String, dynamic>{
          'run': sessionData,
          'endedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
        throwOnError: true,
      ).timeout(
        _finishedSendTimeout,
        onTimeout: () => throw TimeoutException(
          'Overlay finished message dispatch timed out after $_finishedSendTimeout',
        ),
      );
      
      debugPrint('[Overlay] Finished message sent successfully');
      debugPrint('[Overlay] Waiting for app close acknowledgement...');
    } catch (e) {
      debugPrint('[Overlay] Error or timeout sending finished message: $e');
    }
  }

  Future<void> _sendMessage(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ], {
    bool throwOnError = false,
  }) async {
    try {
      await FlutterOverlayWindow.shareData(<String, dynamic>{
        'source': 'overlay',
        'type': type,
        ...payload,
      });
    } catch (e) {
      debugPrint('[Overlay] Error sending message $type: $e');
      if (throwOnError) {
        rethrow;
      }
    }
  }

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() {
      _hint = text;
    });

    _hintTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _hint = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final bgColor = Colors.black.withOpacity(_preferences.opacity.clamp(0.3, 1));

    if (session == null) {
      return Material(
        color: Colors.transparent,
        child: Container(
          width: _preferences.overlayWidth.toDouble(),
          height: _preferences.overlayHeight.toDouble(),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              const SizedBox(height: 12),
              const Text(
                '正在连接...',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => FlutterOverlayWindow.closeOverlay(),
                child: const Text('强制关闭', style: TextStyle(color: Colors.white60, fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        width: _preferences.overlayWidth.toDouble(),
        height: _preferences.overlayHeight.toDouble(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Time Display
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  session.isPaused ? Icons.pause_circle_outline : Icons.timer_outlined,
                  color: session.isPaused ? Colors.orangeAccent : Colors.greenAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  formatDuration(session.totalSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            if (_hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _hint!,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 12),
            // Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: _ControlButton(
                    icon: session.isPaused ? Icons.play_arrow : Icons.pause,
                    label: session.isPaused ? '继续' : '暂停',
                    color: Colors.blueAccent,
                    onPressed: _pauseOrResume,
                  ),
                ),
                Expanded(
                  child: _ControlButton(
                    icon: Icons.fiber_manual_record,
                    label: '记录',
                    color: Colors.amberAccent,
                    onPressed: _recordLap,
                  ),
                ),
                Expanded(
                  child: _ControlButton(
                    icon: Icons.stop,
                    label: '结束',
                    color: Colors.redAccent,
                    onPressed: _endSession,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
