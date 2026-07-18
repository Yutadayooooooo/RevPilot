import Link from "next/link";
import { Inbox, LayoutDashboard, BarChart3, Settings, Plane, LogOut } from "lucide-react";
import { getCurrentUser } from "@/lib/supabase/server";

const nav = [
  { href: "/", label: "概要", icon: LayoutDashboard },
  { href: "/inbox", label: "統合インボックス", icon: Inbox },
  { href: "/analytics", label: "分析", icon: BarChart3 },
  { href: "/settings", label: "設定", icon: Settings },
];

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();

  return (
    <div className="flex min-h-screen">
      <aside className="hidden w-60 shrink-0 flex-col border-r bg-background p-4 md:flex">
        <div className="mb-6 flex items-center gap-2 px-2">
          <Plane className="h-5 w-5 text-primary" />
          <span className="text-lg font-semibold">RevPilot</span>
        </div>
        <nav className="space-y-1">
          {nav.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className="flex items-center gap-2.5 rounded-md px-3 py-2 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              <n.icon className="h-4 w-4" />
              {n.label}
            </Link>
          ))}
        </nav>

        <div className="mt-auto border-t pt-3">
          {user ? (
            <div className="space-y-2">
              <div className="truncate px-2 text-xs text-muted-foreground" title={user.email ?? ""}>
                {user.email}
              </div>
              <form action="/auth/signout" method="post">
                <button
                  type="submit"
                  className="flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
                >
                  <LogOut className="h-4 w-4" /> ログアウト
                </button>
              </form>
            </div>
          ) : (
            <div className="px-2 text-xs text-muted-foreground">未ログイン（サンプル表示）</div>
          )}
        </div>
      </aside>
      <main className="flex-1 p-6 md:p-8">{children}</main>
    </div>
  );
}
