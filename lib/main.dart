import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'app_models.dart';
import 'overlay_widget.dart';

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(child: FloatingTimerWidget()),
        ),
      ),
    ),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootstrapApp());
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key});

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  late final Future<AppController> _controllerFuture;

  @override
  void initState() {
    super.initState();
    _controllerFuture = AppController.create();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppController>(
      future: _controllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            theme: ThemeData(
              colorSchemeSeed: Colors.blue,
              useMaterial3: true,
            ),
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return MaterialApp(
            home: Scaffold(
              body: Center(
                child: Text(
                  '初始化失败：${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        return ChangeNotifierProvider<AppController>.value(
          value: snapshot.data!,
          child: const TimeTrackerApp(),
        );
      },
    );
  }
}

class TimeTrackerApp extends StatelessWidget {
  const TimeTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '计时器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isOpeningSettlement = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    _maybeOpenSettlement(controller);

    return Scaffold(
      appBar: AppBar(
        title: const Text('计时器'),
        actions: [
          IconButton(
            onPressed: () => controller.syncOverlayNow(),
            icon: const Icon(Icons.sync),
            tooltip: '手动同步',
          ),
          IconButton(
            onPressed: () => _showOverlaySettings(context, controller),
            icon: const Icon(Icons.settings),
            tooltip: '悬浮窗设置',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (kDebugMode) ...[
            Text('Debug: Active=${controller.activeSession != null}, Pending=${controller.pendingSettlement != null}', 
                 style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: FilledButton(
                onPressed: () => _handleStart(context, controller),
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  textStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                child: const Text('开始计时'),
              ),
            ),
          ),
          if (controller.activeSession != null) ...[
            const SizedBox(height: 20),
            Center(
              child: TextButton.icon(
                onPressed: () => _showForceStopDialog(context, controller),
                icon: const Icon(Icons.cleaning_services, color: Colors.red),
                label: const Text('发现计时冲突？点击强制重置', style: TextStyle(color: Colors.red)),
              ),
            ),
          ],
          if (controller.pendingSettlement != null) ...[
            const SizedBox(height: 30),
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.pending_actions),
                        SizedBox(width: 8),
                        Text('最近一次计时未保存', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('总用时: ${formatDuration(controller.pendingSettlement!.totalSeconds)}'),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => controller.discardPendingSettlement(),
                            child: const Text('舍弃'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SettlementPage(record: controller.pendingSettlement!, isDraft: true),
                              ),
                            ),
                            child: const Text('查看详情并保存'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 40),
          if (controller.records.isNotEmpty) ...[
            const Text(
              '历史记录',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...controller.records.map((record) => RecordCard(record: record)),
          ] else
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: Text('暂无历史记录', style: TextStyle(color: Colors.grey)),
              ),
            ),
        ],
      ),
    );
  }

  void _maybeOpenSettlement(AppController controller) {
    final pending = controller.pendingSettlement;
    if (pending == null || _isOpeningSettlement || !mounted) {
      return;
    }

    _isOpeningSettlement = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SettlementPage(record: pending, isDraft: true),
        ),
      );
      _isOpeningSettlement = false;
    });
  }

  Future<void> _showForceStopDialog(BuildContext context, AppController controller) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('强制重置计时'),
        content: const Text('当前似乎有一个任务正在运行。你想保留当前的计时进度并结算，还是直接彻底清除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('直接清除', style: TextStyle(color: Colors.red)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('结算并保留'),
          ),
        ],
      ),
    );

    if (result == 'save') {
      await controller.forceStopSession(saveLastKnown: true);
    } else if (result == 'discard') {
      await controller.forceStopSession(saveLastKnown: false);
    }
  }

  Future<void> _handleStart(BuildContext context, AppController controller) async {
    final result = await controller.startSession();
    if (!mounted) return;

    switch (result) {
      case StartSessionResult.started:
        // App typically goes to background when overlay shows, 
        // but we can also manually pop if needed. 
        // The user said "page closes, generate overlay".
        break;
      case StartSessionResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要悬浮窗权限才能开始计时')),
        );
        break;
      case StartSessionResult.alreadyRunning:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已有计时任务正在运行')),
        );
        break;
      case StartSessionResult.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('启动失败，请检查设置')),
        );
        break;
    }
  }

  Future<void> _showOverlaySettings(BuildContext context, AppController controller) async {
    var draft = controller.overlayPreferences;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('悬浮窗设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Text('透明度: ${(draft.opacity * 100).round()}%'),
                Slider(
                  value: draft.opacity,
                  min: 0.3,
                  max: 1.0,
                  onChanged: (v) => setModalState(() => draft = draft.copyWith(opacity: v)),
                ),
                Text('缩放: ${(draft.scale * 100).round()}%'),
                Slider(
                  value: draft.scale,
                  min: 0.5,
                  max: 1.5,
                  onChanged: (v) => setModalState(() => draft = draft.copyWith(scale: v)),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      controller.updateOverlayPreferences(draft);
                      Navigator.pop(context);
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

class RecordCard extends StatelessWidget {
  final SessionRecord record;
  const RecordCard({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text('用时: ${formatDuration(record.totalSeconds)}'),
        subtitle: Text('结束于: ${formatDateTime(record.endedAt)}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettlementPage(record: record, isDraft: false),
            ),
          );
        },
      ),
    );
  }
}

class SettlementPage extends StatelessWidget {
  final SessionRecord record;
  final bool isDraft;
  const SettlementPage({super.key, required this.record, required this.isDraft});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('计时详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('统计概览', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text('总用时: ${formatDuration(record.totalSeconds)}'),
                  Text('记录点数: ${record.laps.length}'),
                  Text('开始时间: ${formatDateTime(record.startedAt)}'),
                  Text('结束时间: ${formatDateTime(record.endedAt)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text('记录明细', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ...record.laps.asMap().entries.map((e) {
            final index = e.key;
            final duration = e.value;
            return Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text('第 ${index + 1} 段用时'),
                trailing: Text(formatDuration(duration)),
              ),
            );
          }),
        ],
      ),
      bottomNavigationBar: isDraft
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        context.read<AppController>().discardPendingSettlement();
                        Navigator.pop(context);
                      },
                      child: const Text('舍弃'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        context.read<AppController>().savePendingSettlement();
                        Navigator.pop(context);
                      },
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
