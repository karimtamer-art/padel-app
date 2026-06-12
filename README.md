# Padel Egypt — Clay Court (Flutter)

A Flutter scaffold of the **Clay Court** design, generated from the HTML prototype.
This is a **starting point** — it compiles to the same screens/look, with mock data,
ready for you to wire to your real models/API.

## Run it

```bash
cd flutter
flutter pub get
flutter run
```

Requires Flutter 3.27+ and Dart 3.6+ (the code uses the current
`Color.withValues()` and Material 3 `ColorScheme` APIs). The only third-party
package is [`google_fonts`](https://pub.dev/packages/google_fonts) (for Outfit).

## Project structure

```
lib/
  main.dart                         App entry → RootScaffold
  core/
    theme/
      app_colors.dart               Clay palette + tier colors + wash() helper
      app_spacing.dart              Spacing, radii, shadows
      app_text.dart                 Outfit text styles (titles, body, stats, kickers)
      app_theme.dart                ThemeData (ColorScheme + Outfit text theme)
    widgets/
      common.dart                   AppCard, AppTag, TierBadge, AppAvatar,
                                     AppButton, SectionHeader, AppBar2 (progress),
                                     StripedPlaceholder
      screen_bar.dart               ScreenBar app bar + IconChip
      elo_chart.dart                EloChart (CustomPainter sparkline)
  data/
    mock_data.dart                  Models + all mock content (swap for your API)
  screens/
    shell/root_scaffold.dart        Bottom nav with the raised center "Create" FAB
    home/home_screen.dart           Home (greeting, next match, carousels, store)
    tournaments/tournaments_screen.dart  Rankings (podium + leaderboard) + Tournaments
    store/store_screen.dart         Store grid + Trade-In bottom sheet
    profile/profile_screen.dart     Profile + ELO history chart
    create/create_match_sheet.dart  3-step Create-a-Match + Greater-Cairo court map
    detail/match_detail_screen.dart Match lobby + result preview
```

## Navigation

Bottom bar: **Home · Tournaments · ( ⊕ Create ) · Store · You**.
The center **Create** button is a raised FAB that opens the Create-a-Match sheet from
any tab (`showModalBottomSheet`).

## Notes / next steps

- **Colors** all come from `AppColors`. Change the brand by editing `primary` / `accent`.
- **Mock data** lives in `lib/data/mock_data.dart` — replace `MockData` with your
  repository / API models. The widget code only depends on the small model classes.
- **Court map** (`create_match_sheet.dart`) is a stylised preview with hand-placed pins.
  For production, drop in `google_maps_flutter` and feed it the `Court` coordinates.
- **Images** use `StripedPlaceholder`. Swap for `Image.network(...)` / cached images
  when you have real product & court photography.
- Icons use Material's built-in set (close matches to the prototype's custom line icons).
- This scaffold was hand-written from the design. It targets a **current Flutter SDK**:
  it uses `Color.withValues(alpha:)` (not the deprecated `withOpacity`) and a Material 3
  `ColorScheme` without the removed `background`/`onBackground` roles. Run
  `flutter analyze` once and fix any remaining project-specific lint before shipping.

## Where this came from

Generated from `Padel Redesign.html` (the Clay Court prototype). See `Flutter Handoff.md`
in the project root for the full design-token mapping and rationale.
