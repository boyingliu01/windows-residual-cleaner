// @no-test-required: vendored shadcn-style presentational primitive with no project logic
import * as React from "react"
import { cn } from "@/lib/utils"

interface ProgressProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number
  max?: number
  variant?: "default" | "success"
}

function Progress({ className, value = 0, max = 100, variant = "default", ...props }: ProgressProps) {
  const pct = Math.min(Math.round((value / max) * 100), 100)
  return (
    <div
      className={cn("h-2 w-full rounded-full bg-secondary overflow-hidden", className)}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={max}
      aria-valuenow={value}
      {...props}
    >
      <div
        className={cn(
          "h-full rounded-full transition-all duration-500 ease-out",
          variant === "success" ? "bg-safe" : "bg-primary"
        )}
        style={{ width: `${pct}%` }}
      />
    </div>
  )
}

export { Progress }
