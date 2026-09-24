# Syndro UI Documentation

## Design Direction

Syndro is a utility. Interaction speed matters more than visual spectacle, so
glow and gradient are accents, not a surface treatment.

- Gradients belong to the wordmark, the primary CTA, and small accents such as
  a section bar. `GradientIconTile`'s purple halo is off by default; a tile
  that glows is a tile that has to earn it.
- Cards are flat tonal surfaces with a hairline border. Selection is carried by
  fill plus border weight, never by a shadow.
- Body panes sit on the scaffold's flat base colour. The three-stop background
  gradient is no longer painted under the largest surface in the app.
- Animation is 150–250 ms and ends. Nothing loops while the user reads — the
  drop zone's perpetual pulse and the transfer screen's breathing icon are gone.
- State is never colour alone: every transfer status pairs an icon with a word,
  and an online peer pairs a dot with "Online".

`test/ui/` enforces the layout half of this. The shell and both home layouts are
pumped at three desktop and two phone window sizes, at a 1.4x text scaler, and
any framework-reported layout error fails the build — neither target can be
built on the author's machine, so that harness is the substitute for opening the
app. Run `SYNDRO_GOLDENS=1 flutter test test/ui/desktop_goldens_test.dart
--update-goldens` to render screenshots for review; the PNGs are deliberately not
committed.

## Theme & Design Language

### Color Palette (from `lib/ui/theme/app_theme.dart`)

**Primary Colors (Logo Gradient)**
| Name | Hex | Usage |
|------|-----|-------|
| `primaryColor` | `#7B5EF2` | Purple — primary actions, selected states, buttons, indicators |
| `secondaryColor` | `#5B8DEF` | Blue — secondary actions, logo gradient start |
| `accentColor` | `#06B6D4` | Cyan — highlights, speed indicators |

**Background Colors**
| Name | Hex | Usage |
|------|-----|-------|
| `backgroundColor` | `#0A0A0F` | Near-black — scaffold background |
| `surfaceColor` | `#141420` | Dark purple-gray — cards, sheets, navigation bar background |
| `cardColor` | `#1E1E2E` | Card background, dividers, unselected nav items |

**Status Colors**
| Name | Hex | Usage |
|------|-----|-------|
| `successColor` | `#22C55E` | Green — online indicators, completed transfers, save actions |
| `errorColor` | `#EF4444` | Red — failed transfers, delete actions, cancel buttons |
| `warningColor` | `#F59E0B` | Amber — pending states, large file warnings |

**Text Colors**
| Name | Hex | Usage |
|------|-----|-------|
| `textPrimary` | `#F8FAFC` | White — headings, primary labels |
| `textSecondary` | `#CBD5E1` | Light gray — body text, secondary labels |
| `textTertiary` | `#94A3B8` | Muted gray — captions, hints, timestamps |

**Other**
| Name | Hex | Usage |
|------|-----|-------|
| `borderColor` | `#2D2D3D` | Subtle borders on cards and containers |

### Typography Scale

| Text Theme Key | Size | Weight | Color | Usage |
|---------------|------|--------|-------|-------|
| `displayLarge` | 32px | Bold | `textPrimary` | Screen titles |
| `displayMedium` | 28px | Bold | `textPrimary` | Section headers |
| `displaySmall` | 24px | w600 | `textPrimary` | Card headings |
| `headlineMedium` | 20px | w600 | `textPrimary` | AppBar titles, device names |
| `titleLarge` | 18px | w600 | `textPrimary` | "Nearby Devices", section labels |
| `titleMedium` | 16px | w500 | `textPrimary` | List item titles, button labels |
| `bodyLarge` | 16px | Regular | `textSecondary` | Descriptions |
| `bodyMedium` | 14px | Regular | `textSecondary` | Body text, subtitles |
| `bodySmall` | 12px | Regular | `textTertiary` | Captions, timestamps, badges |

### Border Radius Values

| Context | Radius |
|---------|--------|
| Cards | `16px` (`BorderRadius.circular(16)`) |
| Elevated/Outlined buttons | `12px` |
| Dialogs | `20px` |
| Bottom sheets | `24px` (top corners only) |
| Chips | `8px` |
| Navigation items (mobile) | `24px` |
| FABs / Circular buttons | `32px` (half of 64px height) |
| Onboarding icon containers | `32px` outer, `20px` inner |
| Permission list container | `20px` |
| QR code card | `24px` |
| Input fields | `12px` |
| Snackbar | `12px` |

### Gradients & Effects

- **Logo Gradient**: Linear gradient from `#5B8DEF` (blue, top-left) → `#7B5EF2` (purple, bottom-right). Used by the brand mark, the wordmark and `GradientIconTile`.
- **Primary Gradient**: Same stops, horizontal. Reserved for primary CTAs.
- **Gradient Shader**: `AppTheme.gradientShader` applies the logo gradient to text via `ShaderMask` — the wordmark in the desktop brand bar.
- **Background Gradient**: Still defined (`AppTheme.backgroundGradient`, three-stop `#0A0A0F` → `#141420` → `#1E1E2E`) but no longer painted under a page body; the desktop and history/settings bodies use the flat scaffold base.
- **Card Shadows**: None. Cards are `AppTheme.surfaceContainer` with a 1px `outlineVariant` border.
- **Selected Card Glow**: Removed. A selected device card gets `primaryContainer` fill and a 1.6px `primaryColor` border; keyboard focus gets 2.5px so Tab is visible.
- **Mobile Navigation Bar**: Floating pill, `surfaceContainerHigh`, 1px `outlineVariant` border, one black shadow for elevation. No gradient fill and no purple glow.
- **Glassmorphism**: `AppTheme.glassmorphicDecoration()` remains available but is not used by the desktop or mobile shells.

### Dark/Light Mode

- **Dark Theme** (primary): Full implementation with `Brightness.dark`, Material 3 enabled. Uses `ColorScheme.dark` with primary/secondary/surface/error.
- **Light Theme**: Complete mirror of the dark theme — same `ColorScheme` roles, tonal surface scale, container roles and text theme, on a `#F6F7FB` scaffold.
- The app defaults to dark mode. Theme choice (Dark / Light / System) is exposed in Settings → General → Appearance and persisted in `SharedPreferences` under `app_theme_mode`.
- Both palettes are also reachable through mutable statics (`AppTheme.backgroundColor`, `textTertiary`, …) that `AppTheme.applyMode()` swaps; `main.dart` calls it during build. Any new widget should prefer `Theme.of(context).colorScheme` over those statics.

---

## Navigation Structure

### Mobile (Android)

**Floating Bottom Navigation Bar** — positioned at bottom center, 24px from bottom edge.

- Container: 68px height, horizontal padding 12px, vertical padding 8px
- Background: Gradient from `surfaceColor` 95% opacity → 85% opacity
- Border radius: 34px (pill shape)
- Shadow: `primaryColor` at 15% opacity, blur 30px, offset (0, 15)
- Border: 1.5px `primaryColor` at 20% opacity

**Navigation Items (3):**

| Index | Unselected Icon | Selected Icon | Label |
|-------|----------------|---------------|-------|
| 0 | `Icons.devices_outlined` | `Icons.devices` | Devices |
| 1 | `Icons.history_outlined` | `Icons.history` | History |
| 2 | `Icons.settings_outlined` | `Icons.settings` | Settings |

- **Unselected**: `textSecondary` color, 26px icon
- **Selected**: `primaryColor` icon, gradient background (`primaryColor` 20% → 10%), border at 40% opacity, purple glow shadow. Label shown: 15px, w700, `primaryColor`, letterSpacing 0.3
- **Tap behavior**: Instant state change (no animation), `GestureDetector` with `HitTestBehavior.opaque`
- **Layout**: Row with 8px spacing between items

### Desktop (Windows / Linux / macOS)

Two parts: a full-width brand bar, then a navigation rail beside the content.

**Brand bar** — 52px, `surfaceContainerLow`, 1px bottom border.

- Left: 26px `GradientIconTile` (no glow) + "Syndro" wordmark in the logo gradient.
- Right: live network summary — a `StatusBadge` reading "N devices online" with a
  status dot, counting discovered peers that are online and excluding this device.
  While discovery has not produced a list it reads "Looking for devices".
- The brand bar owns the app identity, so no screen repeats the logo in its own
  `AppBar`: the desktop home header reads "Devices" with the subtitle "Your
  devices on this network".

**Navigation Rail** — 200px with labels, 80px icon-only below a 760px window.

- Heading "NAVIGATE" above the destinations, and destinations pinned to the top
  (`groupAlignment: -1`; the NavigationRail default centres them and leaves a
  gap under the heading).
- Background `surfaceContainerLow`, 1px right border `outlineVariant`, selected
  indicator `primaryContainer` — all from `navigationRailTheme`.
- Ctrl+1 / Ctrl+2 / Ctrl+3 switch Devices / History / Settings.
- macOS uses this chrome too; it previously got the mobile pill nav around a
  two-pane desktop page.

**Rail Destinations (3):**

| Index | Unselected Icon | Selected Icon | Label |
|-------|----------------|---------------|-------|
| 0 | `Icons.devices_outlined` | `Icons.devices` | Devices |
| 1 | `Icons.history_outlined` | `Icons.history` | History |
| 2 | `Icons.settings_outlined` | `Icons.settings` | Settings |

**Leading (Logo):**
- 12px padding container with logo gradient background, 14px border radius
- Share icon: 26px, white, with purple glow shadow (blur 10px)
- "Syndro" text: `ShaderMask` with logo gradient, 20px, bold, white base color
- 14px spacing between logo icon and text

**Vertical Divider**: 1px wide, vertical linear gradient from `primaryColor` 10% → 30% → 10%

### ASCII Flow Diagram

```
                    ┌─────────────────┐
                    │ OnboardingScreen│
                    │  (3 pages)      │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │ Platform.isAndroid?          │
              │ YES                          │ NO
              ▼                              ▼
  ┌───────────────────────┐    ┌─────────────────────────┐
  │PermissionsOnboarding  │    │   MainNavigationScreen   │
  │  Screen               │    │  ┌───────────────────┐  │
  └───────────┬───────────┘    │  │  HomeScreen (0)   │  │
              │                │  ├───────────────────┤  │
              ▼                │  │  HistoryScreen (1) │  │
  ┌─────────────────────────┐ │  ├───────────────────┤  │
  │   MainNavigationScreen  │ │  │  SettingsScreen (2)│  │
  │  ┌───────────────────┐  │ │  └───────────────────┘  │
  │  │  HomeScreen (0)   │  │ └─────────────────────────┘
  │  ├───────────────────┤  │
  │  │  HistoryScreen (1) │  │
  │  ├───────────────────┤  │
  │  │  SettingsScreen (2)│  │
  │  └───────────────────┘  │
  └────────────┬────────────┘
               │
    ┌──────────┼──────────────────────────────┐
    │          │                              │
    ▼          ▼                              ▼
┌────────┐ ┌──────────────┐  ┌──────────────────────────────┐
│FilePick│ │BrowserShare  │  │    BrowserReceiveScreen       │
│erScreen│ │Screen        │  │  (QR code to receive files)   │
└───┬────┘ └──────────────┘  └──────────────────────────────┘
    │
    ├────────────────────────┐
    │                        │
    ▼                        ▼
┌─────────────────┐  ┌──────────────────────────┐
│TransferProgress │  │MultiTransferProgress      │
│Screen           │  │Screen                     │
└─────────────────┘  └──────────────────────────┘
```

**Entry Points:**
- App start → `OnboardingScreen` (if first launch) or `MainNavigationScreen`
- Onboarding → Permissions (Android only) → Main
- Home → Tap device → FilePickerScreen
- Home → Browser Share FAB → Bottom sheet → BrowserShareScreen / BrowserReceiveScreen
- FilePicker → Send → TransferProgressScreen or MultiTransferProgressScreen
- Right-click send (desktop) → QuickSendScreen → FilePickerScreen

---

## Screens

### OnboardingScreen
- **File**: `lib/ui/screens/onboarding_screen.dart`
- **Route/entry**: First app launch (checked via `SharedPreferences` key `onboarding_complete`)
- **Mobile layout**: Full-width PageView with 3 pages, centered content, bottom button
- **Desktop layout**: Constrained to max 450px width, centered on screen
- **Key UI elements**:
  - **Skip button**: Top-right, `TextButton`, `textTertiary` color, 14px, w500, label "Skip"
  - **Page content** (3 pages):
    - Page 1: `Icons.wifi_rounded`, title "CONNECT", `primaryColor` (#7B5EF2)
    - Page 2: `Icons.swap_horiz_rounded`, title "APP TO APP", `secondaryColor` (#5B8DEF)
    - Page 3: `Icons.language_rounded`, title "BROWSER SHARE", `accentColor` (#06B6D4)
  - **Icon container**: 140x140px, gradient background (iconColor 25% → 10%), 32px border radius, 2px border at 40%, shadow blur 30px offset (0, 15). Inner container: 16px margin, 20px border radius. Icon: 64px
  - **Title**: 26px, w700, `ShaderMask` with gradient text (iconColor → 70% opacity), letterSpacing 1.5
  - **Description**: 16px, `textSecondary`, textAlign center, lineHeight 1.6, horizontal padding 16px
  - **Decorative bar**: 80x4px, gradient from iconColor 30% → 80% → 30%, 2px border radius
  - **Page indicators**: Row of animated containers. Active: 24x8px, `primaryColor`, 4px border radius. Inactive: 8x8px, `cardColor`. 4px horizontal margin each. Animation: 300ms
  - **Next/Start button**: 52px height, 180px width on desktop / full-width on mobile. `primaryColor` background, white text, 16px w600, 12px border radius. Label: "NEXT" or "GET STARTED". Loading state: 20x20px white `CircularProgressIndicator`
- **User interactions**: Swipe between pages, tap Next/Get Started, tap Skip
- **Special effects**: Page transition with `Curves.easeInOut`, 300ms. Haptic feedback (`HapticFeedback.lightImpact`) on tap. `AnimatedContainer` for page indicators.

### PermissionsOnboardingScreen
- **File**: `lib/ui/screens/permissions_onboarding_screen.dart`
- **Route/entry**: Android only — reached after OnboardingScreen completes
- **Mobile layout**: Full-width, single-page layout
- **Desktop layout**: Constrained to 450px width
- **Key UI elements**:
  - **Skip button**: Same as OnboardingScreen
  - **Icon container**: 140x140px, `Icons.security_rounded`, `primaryColor`, same gradient treatment as OnboardingScreen
  - **Title**: "PERMISSIONS", 26px w700, `ShaderMask` with `logoGradient`
  - **Description**: "Syndro needs a few permissions to share files seamlessly", 16px, `textSecondary`
  - **Permissions list container**: Gradient background (cardColor 90% → surfaceColor 70%), 20px border radius, 1px border at 15%, shadow blur 20px
  - **3 Permission Tiles**:
    - Storage: `Icons.folder_rounded`, `primaryColor`, "Save received files to your device"
    - WiFi Access: `Icons.wifi_rounded`, `secondaryColor`, "Discover devices on local network"
    - Notifications: `Icons.notifications_rounded`, `accentColor`, "Show transfer progress & requests"
  - **Tile layout**: 48x48px icon container (14px border radius, gradient background), 16px spacing, title 16px w600, description 13px `textSecondary`
  - **Status indicator** (Android only): 28x28px circle. Granted: green gradient background, green border, check icon. Ungranted: surface color, gray border, dash icon. AnimatedContainer 300ms
  - **Dividers**: Between tiles, 1px, `primaryColor` at 10% opacity, indent 70px from start
  - **Action button**: "GRANT PERMISSIONS" or "GET STARTED", 52px height, full-width on mobile / 220px on desktop
  - **Missing permissions text**: 13px, `textTertiary`, shown below button when permissions missing
  - **Decorative bar**: 60x4px, same gradient as OnboardingScreen
- **User interactions**: Tap Skip, tap Grant Permissions, tap Continue (if all granted), Open Settings if denied
- **Special effects**: `AnimatedContainer` 300ms for permission status indicator transitions

### MainNavigationScreen
- **File**: `lib/ui/screens/main_navigation_screen.dart`
- **Route/entry**: Root screen after onboarding/permissions
- **Mobile layout**: Scaffold with Stack — main content + floating bottom nav
- **Desktop layout**: Scaffold with Row — NavigationRail + vertical divider + Expanded content
- **Key UI elements**:
  - **Mobile floating nav bar**: Described in Navigation Structure section above
  - **Desktop rail**: Described in Navigation Structure section above
- **User interactions**: Tap nav items to switch between Home/History/Settings
- **Special effects**: None beyond standard navigation transitions

### HomeScreen
- **File**: `lib/ui/screens/home_screen.dart` (facade) + `lib/ui/screens/home/home_desktop.dart`, `home_mobile.dart`, `home_device_views.dart`
- The facade owns incoming-request and received-text handling, the share-mode and text-compose dialogs, and the platform split; each family renders its own layout file.
- **Desktop layout**: `AppBar` reading "Devices / Your devices on this network" with Browser Share and Send Text actions (icon-only under 720px), then a two-pane body at ≥700px content width — master device column clamped to 300–380px, hairline divider, send pane capped at 860px. Below 700px the master column takes the window and the send actions become contextual FABs at `AppSpacing.xl` from the bottom (the desktop shell has no bottom bar to clear).
- **Whole page is a drop target**: entering the window lights the send zone; releasing anywhere on the page opens the recipient confirmation rather than only when the cursor was inside the frame.
- **Mobile layout**: unchanged single column with the floating pill nav and FAB stack, and its own logo-bearing app bar.
- Shared views in `home_device_views.dart`: "This Device" card, the Nearby Devices header with a live count badge and scanning spinner, skeleton list, empty/scanning state and error state.
- Transfer request approval is a non-dismissable bottom sheet on Android and an equally modal centered dialog elsewhere.
### HistoryScreen
- **File**: `lib/ui/screens/history_screen.dart`
- A transfer log, not a stack of cards. Rows are two lines — device and `N files • size` on the left, time and status word on the right — grouped under `TODAY` / `YESTERDAY` / dated headings.
- Status leads with an icon and repeats itself as a word; cancelled is amber and failed is red, so the two are not the same colour with a different name.
- Statistics are a flat strip (transfers / completed / data moved) instead of three gradient tiles.
- Content is capped at 860px so a maximised window does not stretch every row across the screen.
- Swipe-to-dismiss still deletes a record, and now confirms first; the delete affordance behind the row is drawn at the leading edge, which is where `endToStart` actually reveals it.
- Empty state: `EmptyState` with "No transfer history".
### SettingsScreen
- **File**: `lib/ui/screens/settings_screen.dart`
- Grouped General / Transfer / Network / Security / About, each group one flat `Material` holding rows split by hairlines (a plain `Container` makes `ListTile` warn that its own ink may be invisible).
- **General**: device name (edit dialog), appearance as a `SegmentedButton` of Dark / Light / System.
- **Transfer**: auto-accept from trusted devices; download location, read-only, resolved through `FileService.getDownloadDirectory()`.
- **Network**: IP address with a copy button; transfer port range, read-only, from `AppConfig.defaultTransferPort`.
- **Security**: encryption state as reported by the running `TransferService`; trusted devices with count, per-device pin status, reset-trust and revoke.
- **About**: version, check for updates, and the repository link.
- Only controls the app actually backs are rendered. There is no discovery switch, no preferred-interface picker and no download-location picker, because none of them exist.
- Content capped at 760px.
### FilePickerScreen
- **File**: `lib/ui/screens/file_picker_screen.dart`
- **Route/entry**: From HomeScreen — tap device card then Send Files, or from QuickSendScreen
- **Mobile layout**: AppBar + recipient card + file picker/list + bottom action bar
- **Desktop layout**: Same + DropTarget wrapper for drag-and-drop
- **Key UI elements**:
  - **AppBar**: "Select Files" title, Clear All button (`Icons.clear_all`)
  - **Recipient Info Card**: `_AnimatedCard` with 100ms delay. Gradient (cardColor 90% → surfaceColor 70%), 20px border radius, 1.5px border at 20%. Shows:
    - Device icon: `_AnimatedIcon` (200ms delay, elastic scale) in logo gradient container, 32px icon
    - "Sending to" label, device name (titleLarge w700), IP address
    - Online badge: green dot (8px) with glow + "Online" text, 12px
  - **Empty State with Drop Zone**: `_AnimatedEmptyStateWithDrop`
    - Animated folder icon: `TweenAnimationBuilder` with elastic curve, 800ms. Icon: `Icons.folder_open_rounded` 64px or `Icons.file_download_rounded` (when dragging)
    - "No files selected" / "Drop files here!" title
    - Subtitle: "Drag & drop files here, or use the buttons below" (desktop) or "Select files or folders to send"
    - Three action buttons (animated, staggered):
      - "Select Files": `Icons.insert_drive_file_rounded`, primary
      - "Select Media": `Icons.photo_library_rounded`, outlined
      - "Select Folder": `Icons.folder_rounded`, outlined
    - Drag overlay: `primaryColor` at 10% background, 3px `primaryColor` border, 24px border radius
  - **File list header**: "N file(s)" + total size badge (primaryColor at 20%, 12px) + "Add More" text button
  - **File list tiles**: `_AnimatedListItem` (staggered 50ms per item). Each tile:
    - Container: gradient, 16px border radius, 1px border at 10%
    - File preview: `FilePreviewWidget` in gradient container (color based on file type)
    - File name: `titleSmall` w600
    - File type badge: colored background at 15%, 6px border radius, 10px uppercase text
    - File size: `textTertiary`
    - Remove button: `Icons.close` 20px in `errorColor` at 10% background
    - Uses `Hero` tag `file_preview_{path}`
  - **Bottom action bar**: `_AnimatedCard` (200ms delay, slides up). `cardColor` background, 24px top border radius. Shows "Total Size" label + value + "Send N file(s)" `ElevatedButton` (or loading spinner)
  - **Desktop drag overlay**: When files being dragged over list, shows purple-tinted overlay with `Icons.add_rounded` 48px + "Drop to add more files" text
- **User interactions**: Tap file buttons, drag-and-drop (desktop), tap files for details, remove files, clear all, send
- **Special effects**: Staggered list animations (50ms per item). `_AnimatedCard` fade+slide. `_AnimatedIcon` elastic scale. `_AnimatedButton` scale+fade with stagger. `_AnimatedSendButton` with loading state transition. `FadeThroughTransition` when navigating to transfer progress.

### BrowserShareScreen
- **File**: `lib/ui/screens/browser_share_screen.dart`
- **Route/entry**: From HomeScreen → Browser Share bottom sheet → "Share Media" or "Send Files"
- **Mobile/Desktop layout**: Same — AppBar + scrollable content
- **Key UI elements**:
  - **AppBar**: "Share Media" or "Share via Browser" depending on mode. Actions: viewer count badge (clickable), Copy Link button
  - **Viewer count badge**: Green pill when connected (green background at 20%, green border, "N" count + chevron). Gray when no connections
  - **QR Code Card**: Gradient (surfaceColor 90% → cardColor 70%), 24px border radius, accent-colored border at 30%. Contains:
    - Connection status banner: Green gradient when connected, "N people connected" with pulsing green dot (10px with glow)
    - QR code: 200x200px, white background, 20px border radius, shadow blur 25px. Eye style: square, `#7B5EF2`. Data modules: square, `#1a1a2e`
    - "Scan to download files/media" title: `ShaderMask` with accent gradient, 18px w700
    - "No app needed on the other device" subtitle
    - URL display bar: gradient (cardColor 90% → surfaceColor 70%), 14px border radius. Link icon + monospace URL + copy button
  - **File count section**: Row with folder icon + "Sharing N files" + total size
  - **File list**: Surface background, 16px border radius. Each item:
    - Image files: Thumbnail preview (56x56, 10px border radius) or file type icon
    - Video files: Video icon + play circle overlay
    - Other files: Type-colored icon (56x56, 10px border radius)
    - File name, type badge (uppercase, 10px, colored), size
    - Remove button: `Icons.close` in `errorColor` at 10%
  - **"Add More Files/Media" button**: Outlined, full-width, accent-colored
  - **Timer notice**: `Icons.timer_outlined` 16px + "Link active while this screen is open", 12px `textTertiary`
  - **"Stop Sharing" button**: Outlined, `errorColor`, full-width
  - **File type colors**: Image=#F472B6 (pink), Video=#FB923C (orange), Audio=#A78BFA (purple), Document=#60A5FA (blue), Spreadsheet=#34D399 (green), Presentation=#FBBF24 (yellow), Archive=#F87171 (red), Code=#2DD4BF (cyan), APK=#A3E635 (lime), Executable=#818CF8 (indigo)
  - **Connection confirmation dialog**: AlertDialog with `_accentColor` border. Shows device OS (parsed from user agent), IP address. Approve/Deny buttons
  - **Viewers dialog**: Lists connected clients with OS icon (Android/iPhone/Windows/macOS/Linux), IP address in monospace
- **User interactions**: Copy link, add more files, remove files, stop sharing, approve/deny connections, view connected clients
- **Special effects**: None significant

### BrowserReceiveScreen
- **File**: `lib/ui/screens/browser_receive_screen.dart`
- **Route/entry**: From HomeScreen → Browser Share bottom sheet → "Receive Files"
- **Mobile/Desktop layout**: Same
- **Key UI elements**:
  - **AppBar**: "Receive Files" title, Copy Link action button
  - **Instructions banner**: `Icons.info_outline` 16px `primaryColor` + "Open the link on any device to send files to this device", 14px
  - **Download location**: `Icons.folder` 20px + path text, 12px `textSecondary`, surface container with border
  - **QR Code Card**: Same style as BrowserShareScreen — gradient container, white QR code box, "Scan to send files" title with `ShaderMask`, URL display
  - **Pending Files Section** (appears when files received):
    - Header: `Icons.hourglass_empty` / `Icons.check_circle` + "Received N file(s)" + pending/saved count badges
    - Action buttons: "Save All" (green elevated) + "Discard All" (red outlined)
    - File list: Each item has thumbnail (48x48), name, size, status badge (PENDING/SAVING/SAVED/DISCARDED/ERROR), Save/Discard buttons
    - Status badges: PENDING=warning, SAVING=primary, SAVED=success, DISCARDED=textTertiary, ERROR=error
  - **Image gallery preview**: Full-screen overlay with PageView, pinch-to-zoom (InteractiveViewer), swipe navigation, top bar with file info, bottom bar with Save/Discard buttons for pending files
  - **"Stop Receiving" button**: Outlined, `errorColor`, full-width. Shows "Unsaved Files" dialog if pending files exist
  - **Error states**: Permission error with "Open Settings" button, generic error with "Try Again"
- **User interactions**: Copy link, save/discard individual files, save all, discard all, stop receiving, tap images for gallery preview
- **Special effects**: Fade transition for image gallery opening. InteractiveViewer for pinch-to-zoom.

### QuickSendScreen
- **File**: `lib/ui/screens/quick_send_screen.dart`
- **Route/entry**: From right-click context menu (desktop) when files are pre-selected
- **Mobile/Desktop layout**: Same
- **Key UI elements**:
  - **Header**: Logo icon (28px, white, logo gradient, 16px border radius) + "Quick Send" (`ShaderMask` gradient, 24px bold) + "Select a device to send your files" (14px `textSecondary`)
  - **File Summary Card**: Gradient container, 20px border radius, 20px padding. Shows file thumbnail (for single image/video) or gradient icon (folder/file). Name, size (`Icons.storage_rounded` 14px + formatted size). File count badge (logo gradient, 20px border radius)
  - **Device List**: "Available Devices" label (16px w600 `textSecondary`) + scanning indicator. Uses `DeviceCard` widgets. Empty state: scanning/no devices icons, "Scan Again" button
  - **Cancel button**: Outlined, full-width, `borderColor` at 50%, 12px border radius, 16px w600
- **User interactions**: Tap device to select and navigate to FilePickerScreen, tap Cancel
- **Special effects**: None

### TransferProgressScreen
- **File**: `lib/ui/screens/transfer_progress_screen.dart`
- Header card: 34px tonal direction glyph, "Sending to" / "Receiving from" plus the peer name, and a status badge.
- One compact progress card while transferring: current file and `File i of n`, percentage, a 6px bar, then bytes / rate / estimate as three icon-labelled figures on one line. This replaces a file card plus two separate stat cards.
- Rate and estimate report honestly: speed shows "Calculating…" until its sample window fills, and the estimate shows `--:--` while the speed is zero.
- Below it, the per-file list with completed / current / pending markers.
- Waiting, paused, completed, failed and cancelled are centred status columns wrapped in `_StatusColumn`, which gains a scroll axis when the window is shorter than the message — they overflowed by ~50px at 915x412 before that.
- Nothing pulses: the waiting and paused glyphs used to breathe on a 1500ms loop that a 30-second timer existed to stop.
- Content capped at 720px. Back navigation is guarded by a `PopScope` that confirms before cancelling a live transfer.
### MultiTransferProgressScreen
- **File**: `lib/ui/screens/multi_transfer_progress_screen.dart`
- **Route/entry**: After FilePickerScreen sends files to multiple devices
- **Mobile/Desktop layout**: Same
- **Key UI elements**:
  - **Header**: Logo icon (24px, logo gradient, 12px border radius) + "Sending to N devices" (titleLarge bold) + "M file(s)" subtitle + status badge
  - **Status badge**: "Sending..." (primary), "Complete" (success), "Partial" (warning), "All Failed" (error). Colored pill with icon
  - **Overall Progress**: "Overall Progress" label + percentage, `LinearProgressIndicator` 8px height. Count chips: "Completed" (green), "Failed" (red), "Remaining" (textTertiary)
  - **Transfer cards** (`_TransferProgressCard`): For each recipient:
    - Device icon (20px, colored by platform) + device name + file count
    - Status icon: colored circle with icon
    - Progress bar (6px) when active
    - Status text + bytes transferred/total
    - Error container if failed
  - **Done button**: Full-width, `primaryColor`, shown when all complete
- **User interactions**: Tap Done to dismiss
- **Special effects**: None beyond live progress updates

---

## Widgets

### DropRecipientDialog
- **File**: `lib/ui/widgets/drop_send_sheet.dart`
- Shown after files are dropped on the desktop home page. Reports how many files and their total size, then asks which online peers should receive them via `FilterChip`s with a checkmark, a selected state and a semantics label — so the choice is not carried by colour.
- Opened by `pickDropRecipients(context, items)`; returns the chosen `List<Device>` or null. Send stays disabled until at least one peer is picked, and the dialog says so plainly when nothing else is reachable.
- The chosen recipients then go through `FilePickerScreen` with `preselectedFiles`, the same path a hand-picked send uses.

### DeviceCard
- **File**: `lib/ui/widgets/device_card.dart`
- Three-line hierarchy: device name (titleMedium w700), then `Platform • ip address` on one line, then connection state.
- Leading 36px tonal platform tile (`platform.iconColor` at 12%), no gradient.
- `● Online` / `● Offline` — dot plus the word, so state is never colour alone.
- Hover (pointer devices only): background lifts to `surfaceContainerHigh` over `AppMotion.fast` and the trailing slot cross-fades from the status label to a `Send files` arrow button. The slot keeps a stable width so nothing reflows under the cursor.
- Right-click (pointer devices only): Send files, Rename device, View details, and Remove trust when the peer is already trusted. There is deliberately no "Trust device" entry — trust is granted during a transfer approval, with a key pin, and cannot be created from a browse result. `Quick Send` is likewise absent: the quick-send screen is reached from the shell's right-click "Send with Syndro" file hand-off, not from a peer row.
- Keyboard: Tab reaches the card and Enter activates it; focus draws a 2.5px `primaryColor` border, heavier than the 1.6px selection border.
- `onTap` selects (single- or multi-select depending on mode), `onLongPress` enters multi-select or opens the rename dialog — unchanged from before the redesign.
- **Params**: `device`, `onTap`, `onLongPress`, `onSendFiles`, `isSelected`
### DeviceNicknameDialog
- **File**: `lib/ui/widgets/device_nickname_dialog.dart`
- **Purpose**: AlertDialog for editing a device's display nickname
- **Visual description**: Standard AlertDialog with "Edit Device Name" title, original name text (bodySmall), TextField with 30 char max, word capitalization. Buttons: Reset (if nickname exists), Cancel, Save (FilledButton, disabled when no changes)
- **States**:
  - Has changes: Save button enabled
  - No changes: Save button disabled
  - Empty input: Save clears nickname
- **Used in**: DeviceCard long-press, SettingsScreen device name edit

### DropZoneWidget
- **File**: `lib/ui/widgets/drop_zone_widget.dart`
- Wrapper that turns a subtree into a desktop drop target with a scale-and-fade overlay. Desktop-only: returns `child` untouched on Android/iOS.
- File/folder decoding is shared with `EmptyDropZone` through `transferItemsFromDrop()`, which walks a dropped directory once to total its size.
### EmptyDropZone
- **File**: `lib/ui/widgets/drop_zone_widget.dart`
- The framed drop target in the desktop send pane: circular tonal glyph, "Drop files to send" / "No files selected", supporting line, and a `Wrap` of Files / Folder buttons (a Row overflowed in a narrow detail pane).
- `dragOverWindow` lights the zone while a drag is anywhere over the page; `handlesOwnDrop: false` stops it registering a second DropTarget when an ancestor already owns the window.
- No looping animation. The 1500ms pulse that used to scale the glyph forever is gone.
### FilePreviewWidget
- **File**: `lib/ui/widgets/file_preview_widgets.dart`
- **Purpose**: Shows file thumbnail (image/video) or type-colored icon for any file
- **Visual description**: Sized container (default 56x56) with background color from FileTypeHelper. Images: `Image.file` with cacheWidth. Videos: thumbnail (Android only via VideoThumbnail) or video_file icon + play overlay. Other types: colored icon at 50% of container size
- **States**:
  - **Image**: Photo thumbnail, rounded corners
  - **Video**: Loading spinner → thumbnail with play icon overlay (black circle at 60% opacity) OR generic video icon
  - **Other**: File type icon with colored background
  - **Error**: Falls back to type icon
- **Used in**: FilePickerScreen file list, QuickSendScreen file summary, FilePreviewCard

### LargeFilePreview
- **File**: `lib/ui/widgets/file_preview_widgets.dart`
- **Purpose**: Larger file preview for detail views (up to 300px height)
- **Visual description**: Constrained box with image/video/icon. Images: `Image.file` with `BoxFit.contain`, 16px border radius. Videos: thumbnail or video icon with play button overlay (48px play icon in black circle). Others: 150px tall container with 64px icon + extension text
- **Used in**: File detail bottom sheets

### FilePreviewCard
- **File**: `lib/ui/widgets/file_preview_widgets.dart`
- **Purpose**: Card showing file preview thumbnail alongside file info
- **Visual description**: Card with Row layout: 48x8px FilePreviewWidget + Column (file name w500, extension badge + file size). Extension badge: colored background, 4px border radius, 10px uppercase text
- **Used in**: FileSummaryWidget file list

### FileTypeHelper
- **File**: `lib/ui/widgets/file_preview_widgets.dart`
- **Purpose**: Static utility class for file type detection, icons, and colors
- **File type colors**:
  - Image: `#4CAF50` (green)
  - Video: `#E91E63` (pink)
  - Audio: `#9C27B0` (purple)
  - Document: `#2196F3` (blue)
  - PDF: `#FF5722` (deep orange)
  - Archive: `#FF9800` (orange)
  - Code: `#00BCD4` (cyan)
  - Unknown: `textTertiary`
- **Icons**: `image_rounded`, `video_file_rounded`, `audio_file_rounded`, `description_rounded`, `picture_as_pdf_rounded`, `folder_zip_rounded`, `code_rounded`, `insert_drive_file_rounded`

### FileSummaryWidget
- **File**: `lib/ui/widgets/file_summary_widget.dart`
- **Purpose**: Shows summary of selected files with type breakdown
- **Visual description**: Card with folder icon + "N files selected" + total size. Below: Wrap of Chips (one per file type, colored icon + count + type name). Optional file list (up to 5) using FilePreviewCard, or "+X more" card if >5 files
- **Used in**: FilePickerScreen, QuickSendScreen (as informational widget)

### FullScreenImageViewer
- **File**: `lib/ui/widgets/full_screen_image_viewer.dart`
- **Purpose**: Full-screen gallery with pinch-to-zoom and swipe between images
- **Visual description**: Black background, extend behind AppBar. AppBar: transparent, close button, image counter pill ("1 / N"), share button. Body: PhotoViewGallery with BouncingScrollPhysics. Pinch-to-zoom (contained to 3x covered). Hero transitions.
- **States**:
  - **Loading**: `CircularProgressIndicator` with progress
  - **Error**: Broken image icon + "Cannot load image"
- **Used in**: As a standalone viewer, called via `FullScreenImageViewer.show()`

### ImageGalleryGrid
- **File**: `lib/ui/widgets/full_screen_image_viewer.dart`
- **Purpose**: Grid of image thumbnails that open full-screen viewer on tap
- **Visual description**: GridView with configurable crossAxisCount (default 3), 4px spacing. Each cell: ClipRRect 8px border radius, Image.file with cacheWidth 200. Hero tag per image.
- **Used in**: Potential gallery views

### ShareIntentDialog
- **File**: `lib/ui/widgets/share_intent_dialog.dart`
- **Purpose**: Dialog shown when receiving share intent from Android system
- **Visual description**: AlertDialog with `surfaceColor`, 20px border radius. Header: 40px share icon in primaryColor circle. "Share with Syndro" title (titleLarge bold). "N files selected" subtitle. Two option rows:
  - App to App: `Icons.phone_android`, "Direct transfer to nearby devices"
  - Browser Share: `Icons.language`, "Share via web browser"
  - Each option: 24px icon in primaryColor container + title/subtitle + chevron
  - Cancel text button
- **States**:
  - **Processing**: Shows `CircularProgressIndicator` + "Preparing files..." + "Please wait"
- **Used in**: Android share intent handler

### ShimmerLoading
- **File**: `lib/ui/widgets/shimmer_loading.dart`
- **Purpose**: Shimmer skeleton loading effect
- **Visual description**: Wraps child with `Shimmer.fromColors`. Dark mode: base `#1E1E2E`, highlight `#2A2A3E`. Light mode: base `#E0E0E0`, highlight `#F5F5F5`
- **Used in**: DeviceCardSkeleton, HistoryItemSkeleton (skeleton loading placeholders)

### DeviceCardSkeleton
- **File**: `lib/ui/widgets/shimmer_loading.dart`
- **Purpose**: Skeleton placeholder for device cards during loading
- **Visual description**: Card with Row: 56x56px rounded square (icon placeholder) + Column of 3 rounded rectangles (name 20px, platform 14px, IP 12px) + 12px circle (status indicator)
- **Used in**: HomeScreen loading state

### HistoryItemSkeleton
- **File**: `lib/ui/widgets/shimmer_loading.dart`
- **Purpose**: Skeleton placeholder for history items during loading
- **Visual description**: Card with Row: 48x48px rounded square + Column of 2 rounded rectangles (name 16px, details 12px)
- **Used in**: HistoryScreen loading state

### SuccessAnimation
- **File**: `lib/ui/animations/status_animations.dart`
- **Purpose**: Animated success checkmark with scale-in effect
- **Visual description**: 80x80px circle (successColor at 20%). Animation: 600ms total. First 300ms: scale from 0→1 with `elasticOut` curve. Last 300ms: check_circle icon scales from 0→1 with `easeOut`. Calls `onComplete` when done.
- **Used in**: Transfer completion states

### ErrorAnimation
- **File**: `lib/ui/animations/status_animations.dart`
- **Purpose**: Animated error icon with shake effect
- **Visual description**: 80x80px circle (errorColor at 20%). Animation: 600ms total. First 200ms: scale 0→1. Last 400ms: horizontal shake (-8→8px, elasticIn). Error icon 60px. Calls `onComplete` when done.
- **Used in**: Transfer failure states

### PulseAnimation (Widget)
- **File**: `lib/ui/animations/status_animations.dart`
- **Purpose**: Continuous pulsing scale effect for loading/scanning states
- **Visual description**: Wraps child, scales 1.0→1.1 continuously (1500ms, repeat, reverse, easeInOut). Can be toggled on/off via `animate` parameter.
- **Used in**: Scanning indicators, loading states

### FadeInAnimation
- **File**: `lib/ui/animations/status_animations.dart`
- **Purpose**: Fade-in + slide-up animation for new items appearing
- **Visual description**: Wraps child. 400ms animation (configurable delay). Opacity 0→1 (easeOut) + slide from (0, 0.1) to (0, 0) (easeOut).
- **Used in**: List items appearing, new content

### TransferProgressWidget
- **File**: `lib/ui/widgets/transfer_progress_widget.dart`
- **Purpose**: Compact transfer progress card for inline display
- **Visual description**: Card with: status text (titleMedium), file names (bodyMedium), `LinearProgressIndicator` (8px, primaryColor), progress info (bytes + percentage), speed (accentColor) + ETA. Completed: green check + "Transfer completed". Failed: red error + message + "Retry Transfer" button. Cancelled: warning icon + "Try Again" button.
- **States**: Pending, Connecting, Transferring, Completed, Failed, Cancelled
- **Used in**: Inline transfer status displays

### TransferRequestSheet
- **File**: built inline in `lib/ui/screens/home_screen.dart` (`_showTransferRequestSheet`)
- **Purpose**: Bottom sheet for incoming transfer requests with accept/reject/trust options
- **Visual description**: `surfaceColor` background, 24px top border radius. Handle bar (40x4px). Download icon (48px) in primaryColor container. "Incoming Transfer" title. Sender name + "wants to send you:" + optional "Trusted" badge (green pill with verified_user icon). File details card. Scrollable file list (max 150px height) if multiple files. Buttons: Decline (red outlined), Accept (green elevated), "Accept & Always Trust This Device" (primaryColor text button)
- **Used in**: Transfer request handling

### TransferRequestStrings
- **File**: `lib/ui/screens/home_screen_strings.dart` (shared strings for the sheet)
- **Purpose**: Localization constants for transfer request UI
- **Strings**: "Incoming Transfer", "wants to send you:", "Decline", "Accept", "Accept & Always Trust This Device", "Transfer accepted", "Transfer rejected"

---

## Animations

### FadeAnimation
- **File**: `lib/ui/animations/fade_animation.dart`
- **What animates**: Opacity from 0→1
- **Duration**: Default 400ms, configurable
- **Delay**: Configurable (default zero)
- **Curve**: `Curves.easeOut` (configurable)
- **Usage**: General fade-in wrapper

### SlideAnimation
- **File**: `lib/ui/animations/slide_animation.dart`
- **What animates**: Slide from offset to zero + fade in
- **Duration**: Default 400ms, configurable
- **Delay**: Configurable
- **Curve**: `Curves.easeOutCubic` (configurable)
- **Directions**: up/down/left/right (default up, 30px offset)
- **Usage**: Content sliding into view

### ScaleAnimation
- **File**: `lib/ui/animations/scale_animation.dart`
- **What animates**: Scale from 0.8→1.0 + fade in
- **Duration**: Default 400ms
- **Delay**: Configurable
- **Curve**: `Curves.easeOutBack` (configurable)
- **Usage**: Elements popping into view with slight overshoot

### StaggeredListItem
- **File**: `lib/ui/animations/staggered_list_animation.dart`
- **What animates**: Fade in + slide up (0.2 offset) per list item
- **Duration**: Default 400ms per item
- **Stagger delay**: 50ms between items (configurable)
- **Curve**: `Curves.easeOutCubic`
- **Usage**: List items appearing sequentially

### PulseAnimation (Animation)
- **File**: `lib/ui/animations/pulse_animation.dart`
- **What animates**: Continuous scale oscillation (default 0.95→1.05)
- **Duration**: Default 1000ms per cycle
- **Behavior**: Repeats in reverse automatically
- **Usage**: Scanning indicators, breathing effects

### Page Transitions
- **File**: `lib/ui/animations/page_transitions.dart`
- **SlidePageRoute**: Slide from direction (right/left/up/down) + fade. Duration 300ms, `easeOutCubic` curve
- **FadePageRoute**: Simple fade transition. Duration 300ms
- **ScalePageRoute**: Scale from 0.9→1.0 + fade. Duration 300ms, `easeOutCubic`
- **Usage**: Custom navigation transitions between screens

### Transfer Animations
- **File**: `lib/ui/animations/transfer_animations.dart`
- **FadeInAnimation**: Opacity 0→1, 500ms, `easeIn` curve. Delay configurable
- **SlideInAnimation**: Slide from configurable offset (default 0, 0.3) to zero, 500ms, `easeOutCubic`
- **PulseAnimation**: Scale 0.95→1.05, 1000ms, repeat reverse
- **ShakeAnimation**: Horizontal shake sequence (0→10→-10→10→-10→0), 500ms total. Uses `TweenSequence` with 5 steps
- **SuccessCheckAnimation**: Scale from 0→1 with `elasticOut` curve, 600ms. Displays check_circle icon with configurable size and color

### Status Animations (in animations/)
- **File**: `lib/ui/animations/status_animations.dart`
- **SuccessAnimation**: Same as widget version — 80x80 circle, elastic scale + check icon fade, 600ms
- **ErrorAnimation**: Same as widget version — 80x80 circle, scale + horizontal shake, 600ms
- **PulseAnimation**: Same — 1.0→1.1 scale, 1500ms repeat
- **FadeInAnimation**: Opacity + slide up (0.1 offset), 400ms

---

## Layout verification

`test/ui/` is the layout contract for everything above. It pumps the real
`MainNavigationScreen`, both home layouts, `DeviceCard` and both progress screens
at 900x600, 1280x800 and 1920x1080, plus 412x915 and 915x412, and at a 1.4x text
scaler, and fails on any framework-reported layout error.

Two things make it more than an absence of crashes. One test asserts it catches a
deliberately overflowing tree, so a clean pass means something. The progress
screen's tests drive a real `TransferService` over loopback, so the screen is
opened against a transfer the service was actually offered. `takeException()` is
not used: measured on this toolchain it returns null for a genuine `RenderFlex`
overflow, so the harness installs its own `FlutterError.onError` recorder.

## Summary of Screen-to-Screen Navigation

```
App Launch
    │
    ├── [First Launch] ──→ OnboardingScreen (3 pages)
    │                           │
    │                           ├── [Android] ──→ PermissionsOnboardingScreen
    │                           │                       │
    │                           │                       └──→ MainNavigationScreen
    │                           │
    │                           └── [Desktop] ──→ MainNavigationScreen
    │
    └── [Returning] ──→ MainNavigationScreen
                            │
            ┌───────────────┼───────────────┐
            │               │               │
         [Tab 0]         [Tab 1]         [Tab 2]
      HomeScreen      HistoryScreen   SettingsScreen
            │
            ├── Tap device → FilePickerScreen
            │                    │
            │                    ├── [Single device] → TransferProgressScreen
            │                    │
            │                    └── [Multi device] → MultiTransferProgressScreen
            │
            ├── Browser Share FAB → Bottom Sheet
            │       ├── Share Media → BrowserShareScreen
            │       ├── Send Files → BrowserShareScreen
            │       └── Receive Files → BrowserReceiveScreen
            │
            └── [Desktop right-click] → QuickSendScreen → FilePickerScreen
```
