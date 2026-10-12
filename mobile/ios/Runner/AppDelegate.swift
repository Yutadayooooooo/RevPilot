import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // ローカル通知をアプリ起動中(フォアグラウンド)でもバナー表示するために必要。
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    // リモートpush用の APNs トークンを要求する。
    // firebase_messaging は自分の didFinishLaunching でこれを呼ぶが、
    // プラグインの登録が didInitializeImplicitFlutterEngine（起動完了の後）に移ったため
    // その呼び出しが走らず、APNs トークンが来ない → FCM トークンも取れない →
    // 端末が通知先に登録されない状態になる（2026-10-11 実機で、許可済みなのに未登録だった）。
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
