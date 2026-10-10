import { defineCloudflareConfig } from "@opennextjs/cloudflare";

/**
 * Cloudflare Workers 向けのビルド設定。
 *
 * incrementalCache は設定していない。
 * RevPilot のページは「完全な静的（ランディング・料金・法務）」か
 * 「force-dynamic（ダッシュボード系・APIルート）」のどちらかで、
 * ISR を使っていないため R2 バケットを用意する意味がない。
 * （R2を足すと無料枠の管理対象が1つ増えるだけになる）
 */
export default defineCloudflareConfig();
