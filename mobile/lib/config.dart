/// アプリ設定。値は `--dart-define-from-file=config/app_config.json` で注入する。
/// anonキーはクライアント公開前提（RLSで保護）なので埋め込んで問題ない。
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Next.js側のAPIベースURL（AI返信生成などサーバー処理を呼ぶ場合に使用）。
  /// 未設定ならAI関連機能はUI上で無効化する。
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get hasApi => apiBaseUrl.isNotEmpty;
}
