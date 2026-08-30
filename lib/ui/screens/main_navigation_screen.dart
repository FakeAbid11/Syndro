import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
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
      final info = await UpdateService.checkForUpdate();
      if (info == null || !mounted) return;
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

  /// Check if we should use desktop layout
  bool _isDesktop() {
    return Platform.isWindows || Platform.isLinux;
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktop()) {
      return _wrapDesktopShortcuts(_buildDesktopLayout());
    } else {
      return _buildMobileLayout();
    }
  }

  /// UX: desktop keyboard shortcuts — Ctrl+1/2/3 switch between
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

  /// Desktop layout with NavigationRail (side navigation)
  Widget _buildDesktopLayout() {
    return Scaffold(
      body: Row(
        children: [
          // Side Navigation Rail — styled by the global NavigationRailTheme.
          Container(
            decoration: BoxDecoration(
              color: AppTheme.surfaceContainerLow,
              border: Border(
                right: BorderSide(color: AppTheme.outlineVariant, width: 1),
              ),
            ),
            child: NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _onDestinationSelected,
              backgroundColor: Colors.transparent,
              // Responsive: collapse the labels when the window is narrow so
              // a half-screen desktop window doesn't get a cramped rail.
              extended: MediaQuery.of(context).size.width >= 1000,
              minExtendedWidth: 200,
              leading: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.xl,
                  horizontal: AppSpacing.lg,
                ),
                child: Row(
                  children: [
                    const GradientIconTile(
                      icon: Icons.share,
                      size: 44,
                      radius: AppRadius.md,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    ShaderMask(
                      shaderCallback: (bounds) =>
                          AppTheme.logoGradient.createShader(bounds),
                      child: Text(
                        'Syndro',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              destinations: _railDestinations,
            ),
          ),
          // Main content
          Expanded(
            child: _screens[_selectedIndex],
          ),
        ],
      ),
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
            // pill above the real inset — a fixed margin disappears behind
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
