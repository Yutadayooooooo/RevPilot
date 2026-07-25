// 法務ページ共通の見出し・本文パーツ。Tailwindユーティリティで統一。
import type { ReactNode } from "react";

export function H2({ children }: { children: ReactNode }) {
  return (
    <h2 className="mt-10 mb-3 text-lg font-bold text-slate-900">{children}</h2>
  );
}

export function P({ children }: { children: ReactNode }) {
  return <p className="mb-3 leading-7 text-slate-700">{children}</p>;
}

export function UL({ children }: { children: ReactNode }) {
  return (
    <ul className="mb-3 list-disc space-y-1 pl-6 leading-7 text-slate-700">
      {children}
    </ul>
  );
}

/** 記入が必要な箇所を視覚的に強調するプレースホルダ。 */
export function Fill({ children }: { children: ReactNode }) {
  return (
    <mark className="rounded bg-amber-100 px-1 font-medium text-amber-900">
      {children}
    </mark>
  );
}

/** 事業者による確認・記入を促す注意帯。 */
export function DraftNotice() {
  return (
    <div className="mb-8 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
      <strong>ドラフトです。</strong>{" "}
      <mark className="rounded bg-amber-100 px-1">黄色の箇所</mark>
      を事業者情報で置き換え、公開前に必ず内容をご自身で確認（可能なら専門家のレビュー）してください。
      本ひな型は一般的な構成の参考であり、法的助言ではありません。
    </div>
  );
}

/** 各ページ末尾の相互リンク・更新日。 */
export function LegalFooter({ updated }: { updated: string }) {
  return (
    <div className="mt-12 border-t border-slate-200 pt-6 text-sm text-slate-500">
      最終更新日: {updated}
    </div>
  );
}
