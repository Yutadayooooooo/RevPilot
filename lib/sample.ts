/** Supabase未設定でもUIをプレビューできるサンプルデータ。 */
export interface ReviewRow {
  id: string;
  store: "appstore" | "googleplay";
  rating: number;
  title: string | null;
  body: string | null;
  author: string | null;
  app_name: string;
  reviewed_at: string;
  topics?: string[];
}

export const SAMPLE_REVIEWS: ReviewRow[] = [
  {
    id: "s1", store: "appstore", rating: 1, title: "起動しない",
    body: "アップデート後、起動時に必ずクラッシュします。iPhone 15 Pro / iOS18。早く直してほしい。",
    author: "taro_dev", app_name: "MyHabit", reviewed_at: "2026-07-18T02:10:00Z", topics: ["bug"],
  },
  {
    id: "s2", store: "googleplay", rating: 2, title: null,
    body: "ウィジェットが縦画面で崩れる。あと課金の解約導線が分かりにくい。",
    author: "hanako", app_name: "MyHabit", reviewed_at: "2026-07-17T22:41:00Z", topics: ["ux", "price"],
  },
  {
    id: "s3", store: "appstore", rating: 5, title: "毎日使ってます",
    body: "シンプルで続けやすい。ダークモードも綺麗。ダッシュボードのグラフ機能があると嬉しい。",
    author: "kaz", app_name: "MyHabit", reviewed_at: "2026-07-17T12:03:00Z", topics: ["praise", "feature_request"],
  },
  {
    id: "s4", store: "googleplay", rating: 3, title: null,
    body: "通知が来ないことがある。設定は全部オンにしています。",
    author: "mika", app_name: "Focus Timer", reviewed_at: "2026-07-16T08:20:00Z", topics: ["bug"],
  },
  {
    id: "s5", store: "appstore", rating: 4, title: "良いけど惜しい",
    body: "使い勝手は良い。Apple Watch対応してくれたら満点。",
    author: "shin", app_name: "Focus Timer", reviewed_at: "2026-07-15T19:55:00Z", topics: ["feature_request"],
  },
];

/** 星推移サンプル（分析画面用） */
export const SAMPLE_TREND = [
  { date: "7/12", avg: 3.6 },
  { date: "7/13", avg: 3.7 },
  { date: "7/14", avg: 3.5 },
  { date: "7/15", avg: 3.9 },
  { date: "7/16", avg: 3.4 },
  { date: "7/17", avg: 3.8 },
  { date: "7/18", avg: 3.2 },
];
