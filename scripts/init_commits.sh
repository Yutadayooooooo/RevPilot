#!/usr/bin/env bash
# RevPilot 初回コミットを機能単位で分割して作成するスクリプト。
# サンドボックスからは .git への書き込みが制限されるため、お手元で実行してください。
#
#   cd revpilot
#   rm -f .git/index.lock .git/__probe 2>/dev/null   # 残っていれば掃除
#   bash scripts/init_commits.sh
#
# 各コミットは「機能・関心事」単位で分けています。
set -e

commit () { # commit <message> <path...>
  local msg="$1"; shift
  git add -- "$@"
  git commit -m "$msg"
}

# 1. プロジェクト基盤
commit "chore: scaffold Next.js + Supabase project" \
  package.json package-lock.json tsconfig.json \
  .gitignore .env.example vercel.json postcss.config.mjs tailwind.config.ts \
  app/globals.css app/layout.tsx lib/utils.ts

# 2. DBスキーマ
commit "feat(db): add Supabase schema (apps/reviews/replies/topics/poll_state)" \
  supabase/schema.sql

# 3. ストアAPIクライアント
commit "feat(stores): App Store / Google Play review clients" \
  lib/supabase.ts lib/appstore.ts lib/googleplay.ts lib/notify.ts

# 4. AI返信・分類
commit "feat(ai): Claude reply drafts and topic classification" \
  lib/ai.ts

# 5. 定期取得cron
commit "feat(poll): hourly polling cron with low-rating alerts" \
  lib/poll.ts app/api/cron/poll/route.ts

# 6. 返信API
commit "feat(reply): AI reply generation / Android auto-reply API" \
  app/api/reply/route.ts

# 7. ダッシュボードUI
commit "feat(ui): dashboard — overview, inbox, analytics, shadcn-style components" \
  components/ui/card.tsx components/ui/button.tsx components/ui/badge.tsx \
  components/rating-stars.tsx components/review-inbox.tsx components/trend-chart.tsx \
  lib/sample.ts lib/reviews-data.ts \
  "app/(dashboard)/layout.tsx" "app/(dashboard)/page.tsx" \
  "app/(dashboard)/inbox/page.tsx" "app/(dashboard)/analytics/page.tsx"

# 8. 設定画面
commit "feat(settings): connected apps, notifications, plan settings" \
  components/ui/input.tsx components/settings-form.tsx lib/settings-data.ts \
  "app/(dashboard)/settings/page.tsx" app/api/apps/route.ts app/api/settings/route.ts

# 9. 認証（Supabase Auth）
commit "feat(auth): Supabase email/password auth with RLS-scoped data" \
  lib/supabase/server.ts lib/supabase/browser.ts middleware.ts \
  app/login/page.tsx app/auth/callback/route.ts app/auth/signout/route.ts

# 10. ドキュメント
commit "docs: README, screen-flow diagram, commit script" \
  README.md docs/screen-flow.mermaid scripts/init_commits.sh

echo "✅ 分割コミット完了。'git log --oneline' で確認してください。"
