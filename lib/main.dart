import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_theme.dart';
import 'package:padel_clay/frontend/screens/auth/auth_gate.dart';
import 'package:padel_clay/frontend/screens/splash/splash_screen.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'package:padel_clay/backend/services/profile_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  await Supabase.initialize(
    url: 'https://lxihwifpcufhieppfeza.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4aWh3aWZwY3VmaGllcHBmZXphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMzAzOTEsImV4cCI6MjA5NTkwNjM5MX0.7afCxV225wcNDa5njZz4KAIRTo3eOeMj0099NPF94oQ',
  );
  runApp(const PadelApp());
}

class PadelApp extends StatelessWidget {
  const PadelApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Google client IDs — supply via --dart-define=GOOGLE_WEB_CLIENT_ID=... etc.
    // or set GOOGLE_WEB_CLIENT_ID / GOOGLE_IOS_CLIENT_ID in your build env.
    const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
    const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

    final auth = AuthService(
      googleWebClientId: webClientId,
      googleIosClientId: iosClientId.isEmpty ? null : iosClientId,
    );
    final profiles = ProfileService();

    return MaterialApp(
      title: 'Padel Rivals',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // Tap anywhere outside a text field to dismiss the keyboard — covers
      // every screen and bottom sheet in the app.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      home: _SplashGate(authService: auth, profileService: profiles),
    );
  }
}

/// Shows the animated splash on cold start, then hands off to [AuthGate].
/// Auth/session restore already happened in `main()` before `runApp`, so the
/// splash is a fixed-duration intro rather than a real loading gate.
class _SplashGate extends StatefulWidget {
  final AuthService authService;
  final ProfileService profileService;

  const _SplashGate({required this.authService, required this.profileService});

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _showSplash = true;

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return SplashScreen(onDone: () => setState(() => _showSplash = false));
    }
    return AuthGate(
      authService: widget.authService,
      profileService: widget.profileService,
    );
  }
}
