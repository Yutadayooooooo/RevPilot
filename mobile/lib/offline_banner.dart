import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// 帯の文言（読み上げにも使う）。
const kOfflineMessage = 'インターネットに接続されていません';

/// つながっていないあいだ、画面のいちばん上に細い帯を出す。
///
/// `MaterialApp(builder:)` でアプリ全体を一度だけ包む（画面ごとには置かない）。
/// これまでは通信が切れていても、引っぱって更新したり「AIで生成」を押したりして
/// 失敗するまで気づけなかった。帯は状態を伝えるだけで、再試行は各画面のまま。
/// 帯を出すあいだは、ステータスバーの分の余白を帯が受け持ち、下の画面は帯の下から始まる。
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key, required this.child, this.online});

  final Widget child;

  /// つながっているかの流れ（テストで差し替える）。null なら端末の状態を見る。
  final Stream<bool>? online;

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  /// 切れたと判断するまで待つ時間（Wi-Fi とモバイル通信の切り替わりで帯がちらつかないように）。
  static const offlineDelay = Duration(milliseconds: 1500);

  StreamSubscription<bool>? _sub;
  Timer? _timer;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    final stream = widget.online ?? _deviceOnline();
    _sub = stream.listen(_onChanged, onError: (_) {});
  }

  static Stream<bool> _deviceOnline() async* {
    final c = Connectivity();
    bool isOnline(List<ConnectivityResult> r) =>
        r.any((x) => x != ConnectivityResult.none);
    try {
      yield isOnline(await c.checkConnectivity());
    } catch (_) {
      // 端末の状態を取れないときは、つながっているとみなす（帯を誤って出さない）。
    }
    yield* c.onConnectivityChanged.map(isOnline);
  }

  void _onChanged(bool online) {
    _timer?.cancel();
    if (online) {
      if (_offline) setState(() => _offline = false);
      return;
    }
    _timer = Timer(offlineDelay, () {
      if (mounted) setState(() => _offline = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        AnimatedSize(
          duration: motionDuration(context, const Duration(milliseconds: 220)),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child:
              _offline
                  ? Semantics(
                    liveRegion: true,
                    label: kOfflineMessage,
                    excludeSemantics: true,
                    child: Material(
                      color: dark ? const Color(0xFF334155) : AppTheme.ink,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, top + 6, 16, 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.wifi_off_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                kOfflineMessage,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  : const SizedBox(width: double.infinity),
        ),
        Expanded(
          // 帯の有無で木の形を変えない（変えると下の画面の状態が作り直される）。
          child: MediaQuery(
            data:
                _offline
                    ? media.copyWith(
                      padding: media.padding.copyWith(top: 0),
                      viewPadding: media.viewPadding.copyWith(top: 0),
                    )
                    : media,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
