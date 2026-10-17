import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Webダッシュボードと世界観を合わせたブランドテーマ（ライト／ダーク対応）。
class AppTheme {
  static const primary = Color(0xFF6366F1); // indigo-500（ダークでも見やすいトーン）
  static const primaryLight = Color(0xFF4F46E5); // indigo-600（ライト時のアクセント）

  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFCA8A04);
  static const danger = Color(0xFFDC2626);

  // ライト
  static const bg = Color(0xFFF8FAFC); // slate-50
  static const surface = Colors.white;
  static const ink = Color(0xFF0F172A); // slate-900
  static const border = Color(0xFFE2E8F0); // slate-200

  // ダーク
  static const bgDark = Color(0xFF0B1120); // slate-950寄り
  static const surfaceDark = Color(0xFF1E293B); // slate-800
  static const inkDark = Color(0xFFE2E8F0); // slate-200
  static const borderDark = Color(0xFF334155); // slate-700

  // 補助テキスト。小さい文字でも背景とのコントラスト 4.5:1 を満たす濃さにしてある
  // （ライトは白・薄い面・12%の色付きバッジ上でも 4.6 以上）。
  static const subtle = Color(0xFF5B6B80);
  static const subtleDark = Color(0xFF94A3B8); // slate-400

  // 文字・バッジ用のアクセント（primary のままだと小さい文字で 4.5:1 に届かない）。
  static const accentText = primaryLight; // indigo-600
  static const accentTextDark = Color(0xFFA5B4FC); // indigo-300

  static const _overlayLight = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: surface,
    systemNavigationBarIconBrightness: Brightness.dark,
  );
  static const _overlayDark = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: surfaceDark,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  /// 初期表示用（システム設定に合わせる）。
  static SystemUiOverlayStyle overlayFor(Brightness platform) =>
      platform == Brightness.dark ? _overlayDark : _overlayLight;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final bgC = dark ? bgDark : bg;
    final surfaceC = dark ? surfaceDark : surface;
    final inkC = dark ? inkDark : ink;
    final borderC = dark ? borderDark : border;
    final subtle = dark ? subtleDark : AppTheme.subtle;
    final accent = dark ? accentTextDark : accentText;
    final overlay = dark ? _overlayDark : _overlayLight;

    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: b,
    ).copyWith(
      primary: primary,
      surface: bgC,
      onSurface: inkC,
    );

    // iOS は左端からのスワイプで戻れる Cupertino の遷移にする
    // （FadeForwards には戻るジェスチャーが無く、毎回左上の戻るボタンを押す必要があった）。
    const transitions = PageTransitionsTheme(builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    });

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgC,
      pageTransitionsTheme: transitions,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: borderC,
      textTheme: _textTheme(inkC),
      appBarTheme: AppBarTheme(
        backgroundColor: bgC,
        foregroundColor: inkC,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        systemOverlayStyle: overlay,
        titleTextStyle: TextStyle(
          color: inkC,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceC,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.04),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderC),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(backgroundColor: surfaceC),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: surfaceC),
      listTileTheme: ListTileThemeData(iconColor: subtle, textColor: inkC),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceC,
        selectedColor: primary.withValues(alpha: 0.16),
        side: BorderSide(color: borderC),
        labelStyle: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: inkC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        showCheckmark: false,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceC,
        indicatorColor: primary.withValues(alpha: 0.16),
        elevation: 3,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? accent : subtle,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? accent : subtle);
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFF334155) : ink,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        // 操作ボタン（「元に戻す」「再試行」など）の文字色。既定の inversePrimary は
        // ダークの背景上で約 1.6:1 しかなく読めないので、どちらの背景でも 4.5:1 以上の色にする。
        actionTextColor: accentTextDark,
        closeIconColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.all(16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceC,
        hintStyle: TextStyle(color: subtle),
        border: _inputBorder(borderC),
        enabledBorder: _inputBorder(borderC),
        focusedBorder: _inputBorder(primary, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: inkC,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: borderC),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  static TextTheme _textTheme(Color ink) => TextTheme(
        headlineSmall: TextStyle(
            fontWeight: FontWeight.bold, letterSpacing: -0.5, color: ink),
        titleLarge: TextStyle(
            fontWeight: FontWeight.bold, letterSpacing: -0.3, color: ink),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, color: ink),
        bodyMedium: TextStyle(height: 1.45, color: ink),
      );

  /// 星評価の色分け（Web分析画面と同系統）。
  static Color ratingColor(int rating) {
    if (rating >= 4) return success;
    if (rating == 3) return warning;
    return danger;
  }
}

/// ライト／ダークで切り替わるセマンティックカラー。
/// カスタム描画（ボトムシート・ピル・バナー・バー等）で使用する。
extension AppColors on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get surfaceC => isDark ? AppTheme.surfaceDark : Colors.white;
  Color get bgC => isDark ? AppTheme.bgDark : AppTheme.bg;
  Color get inkC => isDark ? AppTheme.inkDark : AppTheme.ink;
  Color get borderC => isDark ? AppTheme.borderDark : AppTheme.border;

  /// 補助テキスト（旧 Colors.grey / grey.shade500 / grey.shade600 の置き換え先）。
  /// 日付・状態・注意書きなど、意味のある小さい文字はこれを使う（4.5:1 以上）。
  Color get subtleC => isDark ? AppTheme.subtleDark : AppTheme.subtle;

  /// 装飾専用の薄い色（区切り・飾りのアイコン）。
  /// 白地で約 2.6:1 しかないので、読ませたい文字やアイコンには使わず subtleC を使う。
  Color get faintC =>
      isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

  /// 文字・バッジ用の状態色。AppTheme.success / warning / danger は塗り・アイコン向けで、
  /// 小さい文字に使うと 4.5:1 に届かない。こちらは面（surface / bg）上でも、
  /// 同じ色を 12% 重ねたバッジの背景上でも読める濃さにしてある。
  Color get successTextC =>
      isDark ? const Color(0xFF4ADE80) : const Color(0xFF166534);
  Color get warningTextC =>
      isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
  Color get dangerTextC =>
      isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);

  /// 文字・バッジ用のアクセント（リンク風の文字、トピックのチップなど）。
  Color get accentTextC =>
      isDark ? AppTheme.accentTextDark : AppTheme.accentText;

  /// 星評価の色を文字に使うとき（「★3」のような小さい文字）。
  Color ratingTextC(int rating) {
    if (rating >= 4) return successTextC;
    if (rating == 3) return warningTextC;
    return dangerTextC;
  }

  /// プログレスバー等のトラック色。
  Color get trackC =>
      isDark ? const Color(0xFF334155) : const Color(0xFFEEF2F7);

  /// スケルトンのベース色。
  Color get skeletonC =>
      isDark ? const Color(0xFF273449) : const Color(0xFFE9EEF5);

  /// 薄いカード内背景（旧 grey.shade100）。
  Color get subtleSurfaceC =>
      isDark ? const Color(0xFF273449) : const Color(0xFFF1F5F9);
}
