/**
 * 配列を同時実行数を絞って処理する簡易ワーカープール。
 * 取得(cron)と一括返信の両方で使うので共通化してある。
 *
 * deadline(epoch ms)を渡すとその時刻で新規の取り出しをやめる。
 * @returns 実際に処理した件数（残りは呼び出し側で次回に回す）
 */
export async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
  deadline?: number | null
): Promise<number> {
  let cursor = 0;
  let processed = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (cursor < items.length) {
      if (deadline && Date.now() >= deadline) return;
      const item = items[cursor++];
      processed++;
      await worker(item);
    }
  });
  await Promise.all(runners);
  return processed;
}
