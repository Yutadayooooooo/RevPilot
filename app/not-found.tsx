import Link from "next/link";

/**
 * 404。
 * middleware がWebアプリ画面（ENABLE_WEB_APP 未設定時）をここへ書き換えるので、
 * 「提供していない画面」を踏んだ人がアプリの案内に戻れるようにしておく。
 */
export default function NotFound() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-white p-6">
      <div className="max-w-md text-center">
        <p className="text-sm font-semibold text-indigo-600">404</p>
        <h1 className="mt-2 text-2xl font-bold text-slate-900">ページが見つかりません</h1>
        <p className="mt-3 text-sm leading-7 text-slate-600">
          RevPilot は iOS / Android アプリとして提供しています。
          サービスの内容と料金はトップページをご覧ください。
        </p>
        <div className="mt-6 flex justify-center gap-3">
          <Link
            href="/"
            className="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-700"
          >
            トップへ
          </Link>
          <Link
            href="/pricing"
            className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50"
          >
            料金プラン
          </Link>
        </div>
      </div>
    </div>
  );
}
