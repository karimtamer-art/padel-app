/// App configuration — fill these from your Supabase + Google Cloud consoles.
///
/// In production, prefer `--dart-define` over hardcoding:
///   flutter run \
///     --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJ... \
///     --dart-define=GOOGLE_WEB_CLIENT_ID=....apps.googleusercontent.com \
///     --dart-define=GOOGLE_IOS_CLIENT_ID=....apps.googleusercontent.com
class AppConfig {
  AppConfig._();

  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://YOUR-PROJECT.supabase.co');
  static const supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'YOUR-ANON-KEY');

  /// Supabase → Authentication → Providers → Google → "Web client ID".
  /// On Android this is also the `serverClientId` for google_sign_in.
  static const googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: 'YOUR-WEB-CLIENT-ID.apps.googleusercontent.com');

  /// iOS OAuth client id (from GoogleService-Info.plist). Leave empty on Android.
  static const googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: '');
}
