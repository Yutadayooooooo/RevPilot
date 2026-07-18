import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "RevPilot — アプリレビュー監視",
  description: "個人開発者向けのレビュー監視・AI返信・分析ツール",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}
