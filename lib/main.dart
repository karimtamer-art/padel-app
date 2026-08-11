import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_theme.dart';
import 'package:padel_clay/frontend/screens/auth/auth_gate.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'package:padel_clay/backend/services/push_service.dart';
import 'package:padel_clay/frontend/navigation/push_router.dart';

/// This project's Supabase URL. Lives here because `Supabase.initialize` needs
/// it, but it's a const so anything else that must build a project URL by hand
/// — the weekly-report share link, say — uses the same string rather than
/// repeating the project ref.
const String kSupabaseUrl = 'https://lxihwifpcufhieppfeza.supabase.co';

/// Google OAuth client ids for the NATIVE sign-in sheet. Public identifiers,
/// not secrets — same reasoning as the anon key below.
///
/// [kGoogleWebClientIdFallback] is the **"Web application"** client from Google
/// Cloud Console, and must be the very same one configured under Supabase →
/// Authentication → Google, because that is the audience Supabase validates the
/// ID token against. Android additionally needs an **"Android"** OAuth client
/// (package `com.padelegypt.app` + your signing SHA-1) to exist in the same
/// project — its id is never typed anywhere, it just has to be there.
///
/// Leave these empty and Google sign-in silently falls back to the slower
/// browser flow, which still works — that fallback is what shipped in every
/// build up to 1.2.0+5, because this constant was empty. "It opens a browser"
/// is the symptom of that, not of Android.
///
/// The Android OAuth clients must be in the SAME Cloud project as this Web
/// client (its numeric prefix is that project's number). Across projects
/// Google will not mint a token with this audience and `authenticate()`
/// returns a null idToken. Three SHA-1s are registered — Play App Signing,
/// upload, and debug; see the Google sign-in notes in CLAUDE.md.
///
/// A `--dart-define` of the same name wins over the fallback, so CI can
/// override without editing the file.
const String kGoogleWebClientIdFallback =
    '260262268929-6tu57339u99hv13bbvli5h4i3k454bh1.apps.googleusercontent.com';
const String kGoogleIosClientIdFallback = '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  // Portrait only. Every screen is laid out for an upright phone; iOS is also
  // locked in Info.plist, but Android has no manifest lock so this is what
  // stops it rotating there.
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp]);
  await Supabase.initialize(
    url: kSupabaseUrl,
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4aWh3aWZwY3VmaGllcHBmZXphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMzAzOTEsImV4cCI6MjA5NTkwNjM5MX0.7afCxV225wcNDa5njZz4KAIRTo3eOeMj0099NPF94oQ',
  );
  // Android push (FCM). No-op on iOS/web; never blocks startup.
  await PushService.init();
  runApp(const PadelApp());
}

class PadelApp extends StatelessWidget {
  const PadelApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Google client ids — a --dart-define wins, otherwise the constants at the
    // top of this file. Empty means the browser fallback; see their doc.
    const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID',
        defaultValue: kGoogleWebClientIdFallback);
    const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
        defaultValue: kGoogleIosClientIdFallback);

    final auth = AuthService(
      googleWebClientId: webClientId,
      googleIosClientId: iosClientId.isEmpty ? null : iosClientId,
    );
    final profiles = ProfileService();

    return MaterialApp(
      title: 'Padel Rivals',
      debugShowCheckedModeBanner: false,
      // Lets PushRouter navigate from a notification tap (background/terminated).
      navigatorKey: PushRouter.navigatorKey,
      theme: AppTheme.light,
      // Tap anywhere outside a text field to dismiss the keyboard — covers
      // every screen and bottom sheet in the app.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      home: AuthGate(authService: auth, profileService: profiles),
    );
  }
}
