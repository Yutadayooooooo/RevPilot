import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// 端末の「視差効果を減らす」（iOS）／「アニメーションを削除」（Android）がオンか。
///
/// オンの人には、出てくる・滑る・光るといった飾りの動きを見せず、
/// 終わりの形をはじめから出す。テストで差し替えるときは
/// `MediaQuery(data: ...copyWith(disableAnimations: true))` で包む。
bool reduceMotionOf(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

extension ReduceMotionAnimate on Widget {
  /// `animate()` の代わりに使う。「視差効果を減らす」がオンなら、
  /// 再生せずに終わりの形（value 1）で止めて出す。
  ///
  /// `flutter_animate` は端末の設定を見ないので、そのまま `animate()` を使うと
  /// 設定をオンにしている人にもフェードやスライド、くり返す光が出続けていた。
  /// くり返しの [onPlay]（スケルトンの光など）も、減らす設定では呼ばない。
  Animate motion(
    BuildContext context, {
    Key? key,
    Duration? delay,
    AnimateCallback? onPlay,
  }) {
    final reduce = reduceMotionOf(context);
    return animate(
      key: key,
      delay: reduce ? Duration.zero : delay,
      onPlay: reduce ? null : onPlay,
      autoPlay: !reduce,
      value: reduce ? 1 : null,
    );
  }
}

/// 画面の切り替えなどに渡す長さ。減らす設定なら 0。
Duration motionDuration(BuildContext context, Duration normal) =>
    reduceMotionOf(context) ? Duration.zero : normal;
