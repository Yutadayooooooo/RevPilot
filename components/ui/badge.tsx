import * as React from "react";
import { cn } from "@/lib/utils";

export function Badge({
  className,
  tone = "default",
  ...props
}: React.HTMLAttributes<HTMLSpanElement> & { tone?: "default" | "danger" | "success" | "muted" }) {
  const tones: Record<string, string> = {
    default: "bg-primary/10 text-primary",
    danger: "bg-red-100 text-red-700",
    success: "bg-green-100 text-green-700",
    muted: "bg-muted text-muted-foreground",
  };
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        tones[tone],
        className
      )}
      {...props}
    />
  );
}
