/**
 * イベント向けの固定設定（コードにコミットし、開催前に編集してデプロイする想定）。
 * 環境ごとに差し替えたい場合は、後から env や Remote Config へ移行可能。
 */

/** 利用可能なチームの英字ラベル。A から始め、必要な数だけ並べる（例: A〜E の5チーム） */
export const TEAM_LABELS = ["A", "B", "C"] as const;

export type TeamLabel = (typeof TEAM_LABELS)[number];

/** 想定規模（ドキュメント・監視設計の目安。Firestore のクエリ上限とは別） */
export const CAPACITY = {
  /** 同時接続の上限目安 */
  maxConcurrentUsers: 100,
  /** 1日あたりの投稿数の目安 */
  postsPerDay: 300,
} as const;

/** `/screen` のレイアウト目安（一般的な横長・プロジェクター想定） */
export const SCREEN = {
  /** 横長（16:9 前後を想定。実装時は CSS / p5 のキャンバスに反映） */
  aspectRatio: "16:9",
} as const;
