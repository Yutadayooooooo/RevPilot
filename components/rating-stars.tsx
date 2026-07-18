import { Star } from "lucide-react";
import { cn } from "@/lib/utils";

export function RatingStars({ rating }: { rating: number }) {
  return (
    <span className="inline-flex" aria-label={`${rating} / 5`}>
      {[1, 2, 3, 4, 5].map((i) => (
        <Star
          key={i}
          className={cn("h-3.5 w-3.5", i <= rating ? "fill-amber-400 text-amber-400" : "text-gray-300")}
        />
      ))}
    </span>
  );
}
