// @no-test-required: vendored shadcn-style presentational primitive with no project logic
import * as React from "react"
import { cn } from "@/lib/utils"

interface CheckboxProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'type' | 'onChange'> {
  onCheckedChange?: (checked: boolean) => void
}

const Checkbox = React.forwardRef<HTMLInputElement, CheckboxProps>(
  ({ className, checked, onCheckedChange, disabled, ...props }, ref) => {
    return (
      <span className="relative inline-flex items-center justify-center">
        <input
          type="checkbox"
          ref={ref}
          checked={checked}
          onChange={(e) => onCheckedChange?.(e.target.checked)}
          disabled={disabled}
          className={cn(
            "peer h-4 w-4 shrink-0 appearance-none rounded-sm border border-primary bg-background",
            "checked:bg-primary checked:border-primary",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
            "disabled:cursor-not-allowed disabled:opacity-50",
            "transition-colors",
            className
          )}
          {...props}
        />
        <svg
          className="absolute inset-0 h-full w-full pointer-events-none opacity-0 peer-checked:opacity-100 transition-opacity text-primary-foreground"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth={3}
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <polyline points="20 6 9 17 4 12" />
        </svg>
      </span>
    )
  }
)
Checkbox.displayName = "Checkbox"

export { Checkbox }
