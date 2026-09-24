import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/providers/device_provider.dart';
import '../../core/services/update_service.dart';
import '../../core/widgets/update_dialog.dart';
import 'home_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  ConsumerState<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  int _selectedIndex = 0;

  /// Index of the nav item under the mouse cursor (desktop hover feedback).
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    // Silent, non-blocking update check on launch. Any failure is swallowed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    try {
      // At most one automatic check per day (manual Settings check bypasses).
      if (!await UpdateService.shouldAutoCheck()) return;
      final result = await UpdateService.checkForUpdate();
      if (result is! UpdateAvailable || !mounted) return;
      final info = result.info;
      if (await UpdateService.isSkipped(info.version)) return;
      if (!mounted) return;
      await showUpdateDialog(context, info, allowSkip: true);
    } catch (_) {
      // Startup update check is best-effort; never surface errors here.
    }
  }

  final List<Widget> _screens = const [
    HomeScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  final List<NavigationRailDestination> _railDestinations = const [
    NavigationRailDestination(
      icon: Icon(Icons.devices_outlined),
      selectedIcon: Icon(Icons.devices),
      label: Text('Devices'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.history_outlined),
      selectedIcon: Icon(Icons.history),
      label: Text('History'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text('Settings'),
    ),
  ];

  void _onDestinationSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  /// Below this window width the rail drops its labels: a 200px nav column
  /// beside a 400px content area is all chrome and no app.
  static const double _railLabelBreakpoint = 760;

  /// Rail-based desktop chrome; Android/iOS get the floating pill nav.
  ///
  /// macOS counts as desktop here because `HomeScreen` already picks its
  /// two-pane layout on `Platform.isMacOS`; leaving it out gave macOS a phone
  /// pill nav wrapped around a desktop page.
  bool get _isDesktop {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktop) {
      return _wrapDesktopShortcuts(_buildDesktopLayout());
    } else {
      return _buildMobileLayout();
    }
  }

  /// UX: desktop keyboard shortcuts â€” Ctrl+1/2/3 switch between
  /// Devices / History / Settings without touching the mouse.
  Widget _wrapDesktopShortcuts(Widget child) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            () => _onDestinationSelected(0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true):
            () => _onDestinationSelected(1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true):
            () => _onDestinationSelected(2),
      },
      child: Focus(
        autofocus: true,
        child: child,
      ),
    );
  }

  /// Desktop chrome: a full-width brand bar over a navigation rail and the
  /// screen content. App identity and the network summary live in the brand
  /// bar, so no individual screen has to repeat the Syndro logo in its own
  /// app bar.
  Widget _buildDesktopLayout() {
    final labelled = MediaQuery.sizeOf(context).width >= _railLabelBreakpoint;

    return Scaffold(
      body: Column(
        children: [
          const _BrandBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildDesktopRail(labelled),
                // Main content
                Expanded(child: _screens[_selectedIndex]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The left navigation area: 200px with labels, otherwise icon-only.
  Widget _buildDesktopRail(bool labelled) {
    final rail = NavigationRail(
      // A group heading makes three destinations read as navigation rather
      // than orphan icons floating under the brand bar.
      leading: labelled
          ? Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.xs,
                ),
                child: Text(
                  'NAVIGATE',
                  // labelSmall carries the active muted-text colour, so the
                  // heading still reads correctly in the light palette.
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                ),
              ),
            )
          : const SizedBox(height: AppSpacing.md),
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onDestinationSelected,
      backgroundColor: Colors.transparent,
      extended: labelled,
      minExtendedWidth: 200,
      // -1, not 0: NavigationRail feeds this straight into Alignment(0, y), so
      // the default centres the destinations in a window that can be 1000px
      // tall and leaves a gap under the heading.
      groupAlignment: labelled ? -1 : null,
      labelType: labelled
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.selected,
      destinations: _railDestinations,
    );

    return Container(
      width: labelled ? 200 : null,
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: AppTheme.outlineVariant, width: 1),
        ),
      ),
      child: rail,
    );
  }

  /// Mobile layout with Floating Bottom Navigation Bar
  Widget _buildMobileLayout() {
    return Scaffold(
      body: Stack(
        children: [
          // Main content
          _screens[_selectedIndex],

          // Floating Navigation Bar
          Positioned(
            left: 0,
            right: 0,
            // PLATFORM: Android 15 (targetSdk 35) enforces edge-to-edge, so
            // this Stack extends behind the system navigation bar. Anchor the
            // pill above the real inset â€” a fixed margin disappears behind
            // the 3-button nav bar (~48dp).
            bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.sm,
            child: Center(
              child: Container(
                // A11Y: intrinsic height (icon + padding) instead of a fixed
                // 68px box so the pill survives large accessibility text.
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerHigh,
                  borderRadius: AppRadius.pillAll,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                  border: Border.all(
                    color: AppTheme.outlineVariant,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildNavItem(
                      index: 0,
                      icon: Icons.devices_outlined,
                      selectedIcon: Icons.devices,
                      label: 'Devices',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildNavItem(
                      index: 1,
                      icon: Icons.history_outlined,
                      selectedIcon: Icons.history,
                      label: 'History',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildNavItem(
                      index: 2,
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings,
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// FIX: Build individual navigation item with instant state change (no animation).
  /// A11Y: exposed as a button with selection state; UX: hover highlight +
  /// click cursor on desktop instead of a bare [GestureDetector].
  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    final isSelected = _selectedIndex == index;
    final isHovered = _hoveredIndex == index;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!mounted) return;
        setState(() => _hoveredIndex = index);
      },
      onExit: (_) {
        if (!mounted) return;
        if (_hoveredIndex == index) setState(() => _hoveredIndex = null);
      },
      child: Semantics(
        button: true,
        selected: isSelected,
        label: label,
        child: GestureDetector(
          onTap: () => _onDestinationSelected(index),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppTheme.primaryContainer
                  : isHovered
                      ? AppTheme.surfaceContainerHighest
                      : null,
              borderRadius: AppRadius.pillAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isSelected ? selectedIcon : icon,
                  color: isSelected
                      ? AppTheme.onPrimaryContainer
                      : AppTheme.textTertiary,
                  size: 26,
                ),
                if (isSelected) ...[
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: AppTheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The full-width desktop title strip: brand at the left, live network summary
/// at the right.
///
/// Replaces the logo + "Syndro" pair that each desktop screen used to repeat
/// inside its own app bar.
class _BrandBar extends ConsumerWidget {
  const _BrandBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: AppTheme.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          const GradientIconTile(
            icon: Icons.share,
            size: 26,
            iconSize: 15,
            radius: AppRadius.sm,
            glow: false,
          ),
          const SizedBox(width: 10),
          // The wordmark is the one place the brand gradient is always on.
          ShaderMask(
            shaderCallback: (bounds) =>
                AppTheme.logoGradient.createShader(bounds),
            child: Text(
              'Syndro',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
            ),
          ),
          const Spacer(),
          // Its own Consumer, so a discovery tick repaints this badge and not
          // the whole navigation shell.
          const Consumer(builder: _networkSummary),
        ],
      ),
    );
  }

  static Widget _networkSummary(
    BuildContext context,
    WidgetRef ref,
    Widget? child,
  ) {
    final devices = ref.watch(discoveredDevicesProvider).valueOrNull;
    if (devices == null) {
      return const StatusBadge(
        label: 'Looking for devices',
        variant: BadgeVariant.neutral,
        icon: Icons.radar,
      );
    }
    final thisDeviceId = ref.watch(currentDeviceProvider).id;
    // The local device appears in the discovered list but is not something you
    // can send to, so it does not belong in the count.
    final online = devices.where((d) => d.id != thisDeviceId && d.isOnline).length;
    return StatusBadge(
      // A11Y: the words carry the state; the dot colour is decoration.
      label: online == 1 ? '1 device online' : '$online devices online',
      variant: online > 0 ? BadgeVariant.success : BadgeVariant.neutral,
      showDot: true,
    );
  }
}
