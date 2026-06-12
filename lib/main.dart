import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_theme.dart';
import 'package:padel_clay/frontend/screens/auth/auth_gate.dart';
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
      title: 'Padel Egypt',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: AuthGate(authService: auth, profileService: profiles),
    );
  }
}
