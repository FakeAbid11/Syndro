import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';
import 'package:syndro/core/models/transfer_history_entry.dart';
import 'package:syndro/core/providers/device_provider.dart';
import 'package:syndro/core/providers/history_provider.dart';
import 'package:syndro/core/providers/transfer_provider.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';
import 'package:syndro/ui/screens/main_navigation_screen.dart';
import 'package:syndro/ui/theme/app_theme.dart';

/// A window size the layout under test must survive.
typedef WindowSize = ({String label, Size size});

const desktopWindows = <WindowSize>[
  (label: 'small 900x600', size: Size(900, 600)),
  (label: 'laptop 1280x800', size: Size(1280, 800)),
  (label: 'maximised 1920x1080', size: Size(1920, 1080)),
];

const mobileWindows = <WindowSize>[
  (label: 'portrait 412x915', size: Size(412, 915)),
  (label: 'landscape 915x412', size: Size(915, 412)),
];

Device testDevice({
  String id = 'dev-laptop',
  String name = "Abid's Laptop",
  DevicePlatform platform = DevicePlatform.windows,
  String ip = '192.168.1.10',
  bool online = true,
  DateTime? lastSeen,
}) {
  return Device(
    id: id,
    name: name,
    platform: platform,
    ipAddress: ip,
    port: 8000,
    isOnline: online,
    lastSeen: lastSeen ?? DateTime(2026, 9, 24, 10, 42),
  );
}

/// The two-device network every layout test sees, so discovery timing cannot
/// change what a screen renders.
final List<Device> twoDevices = [
  testDevice(),
  testDevice(
    id: 'dev-phone',
    name: "Abid's Phone",
    platform: DevicePlatform.android,
    ip: '192.168.1.12',
  ),
];

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// A two-file drop totalling 248 MB, for the drop-confirmation UI.
const droppedFiles = <TransferItem>[
  TransferItem(name: 'holiday-photos.zip', path: '', size: 180 * 1024 * 1024),
  TransferItem(name: 'itinerary.pdf', path: '', size: 68 * 1024 * 1024),
];
const _transferEventsChannel = EventChannel('com.syndro.app/transfer_events');
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Stubs the plugin channels the shell touches during `build`, so a layout
/// test never dies on `MissingPluginException` half-way through a tree.
///
/// The one pref seeded by default is the update-check cooldown: without it
/// `MainNavigationScreen.initState` fires a live GitHub release check, and a
/// layout test would start depending on what is published upstream. [prefs]
/// adds to that map.
void installUiChannelStubs({Map<String, Object> prefs = const {}}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'syndro.update.lastCheckAt': DateTime.now().millisecondsSinceEpoch,
    ...prefs,
  });
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_secureStorageChannel, (call) async => null);
  messenger.setMockStreamHandler(
    _transferEventsChannel,
    MockStreamHandler.inline(onListen: (a, e) {}, onCancel: (a) {}),
  );
  // Settings resolves the download directory through path_provider on first
  // build. Point it at a scratch directory: the alternative is a
  // MissingPluginException, and the real user's Downloads is not a test dir.
  final scratch = Directory.systemTemp.createTempSync('syndro-ui-test');
  messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
    return scratch.path;
  });
}

void uninstallUiChannelStubs() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_secureStorageChannel, null);
  messenger.setMockStreamHandler(_transferEventsChannel, null);
}

/// Collects framework errors (layout overflow, unbounded constraints, bad
/// paint) that a pump would otherwise report through `FlutterError.onError`.
///
/// `tester.takeException()` is NOT a reliable probe here: measured on this
/// toolchain, a genuine `RenderFlex` overflow leaves it `null`, so a check
/// built on it would pass on a visibly broken screen. Swapping the handler for
/// the duration of one pump is the version that actually observes the failure.
class LayoutErrorRecorder {
  LayoutErrorRecorder._(this._previous);

  final void Function(FlutterErrorDetails)? _previous;
  final List<String> messages = <String>[];

  void restore() => FlutterError.onError = _previous;
}

/// One line per error: the headline plus the source pointer for the widget
/// that overflowed, which is the part that makes a failure actionable.
String _describe(FlutterErrorDetails details) {
  final headline = details.exceptionAsString().split('\n').first;
  final cause = details
      .toString()
      .split('\n')
      .firstWhere(
        (l) => l.contains('.dart:') && !l.trim().startsWith('#'),
        orElse: () => '',
      )
      .trim();
  return cause.isEmpty ? headline : '$headline  $cause';
}

/// Pumps [child] at [window], runs [interact] (tab switches, hovers, dialogs),
/// and returns every framework layout error reported while doing so.
///
/// Bounded pumps, not `pumpAndSettle`: the shell keeps a scan spinner alive
/// while discovery runs, which would settle forever.
Future<List<String>> pumpAndCollectLayoutErrors(
  WidgetTester tester,
  WindowSize window,
  Widget child, {
  List<Override> overrides = const [],
  int settleMs = 400,
  Future<void> Function(WidgetTester tester)? interact,
  TransferService? service,
}) async {
  tester.view.physicalSize = window.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // A caller that brings its own service also owns disposing it; injecting a
  // second override for the same provider would leave it ambiguous which one
  // the tree actually reads.
  final ownedService = service ?? TransferService(FileService());

  // Installed before the first pump: RenderFlex reports overflow while it is
  // painting, so a recorder added after `pumpWidget` misses the first frame —
  // which is the only frame many short tests ever see.
  final recorder = LayoutErrorRecorder._(FlutterError.onError);
  FlutterError.onError = (details) {
    recorder.messages.add(_describe(details));
  };
  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transferServiceProvider.overrideWithValue(ownedService),
          ...overrides,
        ],
        child: MaterialApp(theme: AppTheme.darkTheme, home: child),
      ),
    );
    // Two bounded passes after the first frame: an AsyncValue renders its
    // loading branch initially, so a screen that only overflows once real data
    // lands would be missed by a single pump.
    await tester.pump();
    await tester.pump(Duration(milliseconds: settleMs));
    await tester.pump(Duration(milliseconds: settleMs));
    if (interact != null) {
      await interact(tester);
      await tester.pump(Duration(milliseconds: settleMs));
      await tester.pump(Duration(milliseconds: settleMs));
    }
  } finally {
    recorder.restore();
  }
  if (service == null) {
    // Cancelling the service's periodic cleanup needs real async (a
    // platform-channel subscription close), which fake-async never delivers.
    await tester.runAsync(ownedService.dispose);
  }
  return recorder.messages;
}

/// Tears the tree down so every `State.dispose()` runs.
///
/// `flutter_test` fails a test that still owns a pending timer, and it checks
/// before tearing the tree down — so a screen that arms its own periodic timer
/// (the progress page samples speed once a second) needs this called after the
/// last assertion.
Future<void> unmountTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 50));
}

/// [pumpAndCollectLayoutErrors] plus the assertion a layout test is really
/// making: the screen must render without a single framework complaint.
Future<void> pumpAndExpectCleanLayout(
  WidgetTester tester,
  WindowSize window,
  Widget child, {
  List<Override> overrides = const [],
  int settleMs = 400,
  Future<void> Function(WidgetTester tester)? interact,
  TransferService? service,
}) async {
  final messages = await pumpAndCollectLayoutErrors(
    tester,
    window,
    child,
    overrides: overrides,
    settleMs: settleMs,
    interact: interact,
    service: service,
  );
  if (messages.isEmpty) return;
  fail('${window.label} reported ${messages.length} layout error(s):\n'
      '${messages.join('\n---\n')}');
}

/// Provider overrides that pin the shell to a fixed, already-discovered
/// network. Defaults to two online peers with the first one selected.
List<Override> staticNetwork({
  List<Device>? devices,
  Device? selected,
}) {
  final listed = devices ?? twoDevices;
  return [
    currentDeviceProvider.overrideWithValue(testDevice(
      id: 'self',
      name: "Abid's Laptop",
      ip: '192.168.1.10',
    )),
    isDeviceServiceInitializedProvider.overrideWithValue(true),
    localIpsProvider.overrideWithValue(const ['192.168.1.10']),
    discoveredDevicesProvider.overrideWith((ref) => Stream.value(listed)),
    selectedDeviceProvider.overrideWith(
      (ref) => selected ?? (listed.isEmpty ? null : listed.first),
    ),
  ];
}

/// Pumps the app at [window] and lets it come to rest, for
/// `matchesGoldenFile`. Layout errors are printed rather than failing the
/// golden: the picture is still the thing being reviewed, and
/// [pumpAndExpectCleanLayout] already gates those in CI.
Future<void> pumpShellForScreenshot(
  WidgetTester tester,
  WindowSize window, {
  Brightness brightness = Brightness.dark,
  List<Override> overrides = const [],
  Future<void> Function(WidgetTester tester)? interact,
  Widget? child,
}) async {
  tester.view.physicalSize = window.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // The palette the hardcoded AppTheme.* call sites read is a set of mutable
  // statics that main.dart swaps in build(). A screenshot test that only picked
  // ThemeData would render light surfaces with dark-palette text, so swap it
  // the same way and put it back afterwards.
  AppTheme.applyMode(
    brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  );
  addTearDown(() => AppTheme.applyMode(ThemeMode.dark));

  final service = TransferService(FileService());
  final complaints = <String>[];

  final recorder = LayoutErrorRecorder._(FlutterError.onError);
  FlutterError.onError = (details) {
    final message = _describe(details);
    if (!complaints.contains(message)) {
      complaints.add(message);
      debugPrint('GOLDEN layout: $message');
    }
  };
  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transferServiceProvider.overrideWithValue(service),
          ...overrides,
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark
              ? AppTheme.darkTheme
              : AppTheme.lightTheme,
          home: child ?? const MainNavigationScreen(),
        ),
      ),
    );
    // Bounded, not pumpAndSettle: discovery-driven spinners animate forever.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (interact != null) {
      await interact(tester);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
  } finally {
    recorder.restore();
  }
  // Inside the test rather than in addTearDown: the service arms periodic
  // cleanup timers, and `flutter_test` fails any test that still holds one when
  // it checks its invariants — which happens before teardown callbacks run.
  await tester.runAsync(service.dispose);
}

/// A [HistoryNotifier] whose rows come from the test, not from the shared
/// sqflite file the app under test also writes to.
class StubHistoryNotifier extends HistoryNotifier {
  StubHistoryNotifier(this._rows) : super();

  final List<TransferHistoryEntry> _rows;

  @override
  Future<void> load() async {
    state = HistoryState(
      entries: _rows,
      statistics: const {'total': 4, 'completed': 3, 'totalBytes': 1976557568},
      isLoading: false,
    );
  }
}

TransferHistoryEntry historyRow({
  required String id,
  required String device,
  required String status,
  required int bytes,
  required int files,
  required DateTime when,
  String? error,
}) {
  return TransferHistoryEntry(
    id: id,
    senderId: 'peer-$id',
    receiverId: 'self',
    senderName: device,
    receiverName: device,
    status: status,
    totalBytes: bytes,
    bytesTransferred: status == 'completed' ? bytes : (bytes / 3).round(),
    fileCount: files,
    createdAt: when,
    completedAt: status == 'completed' ? when.add(const Duration(seconds: 40)) : null,
    errorMessage: error,
  );
}

/// History rows spanning today, yesterday and an older date, so a grouped log
/// layout is exercised by every size it renders at.
List<Override> seededHistory() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 9, 18);
  return [
    historyProvider.overrideWith(
      (ref) => StubHistoryNotifier([
        historyRow(
          id: 'h-today-1',
          device: "Abid's Laptop",
          status: 'completed',
          bytes: 780 * 1024 * 1024,
          files: 1,
          when: today.add(const Duration(hours: 1, minutes: 24)),
        ),
        historyRow(
          id: 'h-today-2',
          device: "Abid's Phone",
          status: 'completed',
          bytes: 1200 * 1024 * 1024,
          files: 3,
          when: today.add(const Duration(minutes: 18)),
        ),
        historyRow(
          id: 'h-yest-1',
          device: "Abid's Laptop",
          status: 'failed',
          bytes: 186 * 1024 * 1024,
          files: 24,
          when: today.subtract(const Duration(days: 1, hours: 3)),
          error: 'Connection reset by peer',
        ),
        historyRow(
          id: 'h-yest-2',
          device: 'Living Room TV',
          status: 'cancelled',
          bytes: 64 * 1024 * 1024,
          files: 2,
          when: today.subtract(const Duration(days: 1, minutes: 40)),
        ),
        historyRow(
          id: 'h-old-1',
          device: "Aisha's Notebook",
          status: 'completed',
          bytes: 5 * 1024 * 1024 * 1024,
          files: 148,
          when: DateTime(now.year, now.month - 2, 14, 8, 5),
        ),
      ]),
    ),
  ];
}
