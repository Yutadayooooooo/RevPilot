/// アプリ設定。値は `--dart-define-from-file=config/app_config.json` で注入する。
/// anonキーはクライアント公開前提（RLSで保護）なので埋め込んで問題ない。
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Next.js側のAPIベースURL（AI返信生成などサーバー処理を呼ぶ場合に使用）。
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// 規約・プライバシー・料金など公開ページのベースURL。
  /// 通常は API_BASE_URL と同じだが、開発中にAPIをLANのIPへ向けている場合でも
  /// 法務ページだけは本番ドメインを指せるように分けてある
  /// （リンク切れの規約ページはストア審査で落ちる要因になる）。
  static const _webUrl = String.fromEnvironment('WEB_URL');
  static String get webUrl => _webUrl.isNotEmpty ? _webUrl : apiBaseUrl;

  // --- Firebase Cloud Messaging（リモートpush通知）---
  //
  // GoogleService-Info.plist / google-services.json を置く代わりに、
  // 他の設定と同じ dart-define で渡す。
  //   - 設定の受け渡し口が1つで済む（config/app_config.json だけ見ればよい）
  //   - Firebase未設定でもビルドが通る（値が空なら push を初期化しない）
  // ここに入る値はクライアント公開前提の識別子で、秘密鍵ではない。
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseApiKeyIos = String.fromEnvironment('FIREBASE_API_KEY_IOS');
  static const firebaseAppIdIos = String.fromEnvironment('FIREBASE_APP_ID_IOS');
  static const firebaseApiKeyAndroid =
      String.fromEnvironment('FIREBASE_API_KEY_ANDROID');
  static const firebaseAppIdAndroid =
      String.fromEnvironment('FIREBASE_APP_ID_ANDROID');

  // --- Google ログイン ---
  // Google Cloud の OAuth クライアントID（公開前提の識別子）。
  //   GOOGLE_WEB_CLIENT_ID : 「ウェブアプリケーション」型。Supabase の Google プロバイダにも同じ値を登録する
  //   GOOGLE_IOS_CLIENT_ID : 「iOS」型。ios/Runner/Info.plist の URL スキームに逆順の値を入れる
  // 設定ファイルで空文字を渡すとログイン画面に Google ボタンを出さない（既定値は本番のID）。
  // OAuth クライアントIDは秘密ではない（アプリに埋め込まれ、誰でも取り出せる）ので既定値を置く。
  // iOS の ID を変えたら ios/Runner/Info.plist の GIDClientID と URL スキームも合わせること。
  static const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID',
      defaultValue: '853072258337-9ehbgbofma1r3shid18nt6p7gsaq057u.apps.googleusercontent.com');
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
      defaultValue: '853072258337-89nupbh95o5fujt334dl7kojercar765.apps.googleusercontent.com');

  /// iOSのバンドルID。Firebaseに登録したiOSアプリと一致させる。
  static const iosBundleId = 'jp.revpilot.app';

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get hasApi => apiBaseUrl.isNotEmpty;
  static bool get hasWeb => webUrl.isNotEmpty;
}
