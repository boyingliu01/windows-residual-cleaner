// @no-test-required: vendored shadcn-style presentational primitive with no project logic
import * as React from "react"
import { cn } from "@/lib/utils"

interface TabsProps {
  value: string
  onValueChange: (value: string) => void
  children: React.ReactNode
  className?: string
}

function Tabs({ value, onValueChange, children, className }: TabsProps) {
  return (
    <div className={className} data-value={value}>
      {React.Children.map(children, (child) => {
        if (React.isValidElement(child)) {
          return React.cloneElement(child as React.ReactElement<any>, { _value: value, _onValueChange: onValueChange })
        }
        return child
      })}
    </div>
  )
}

interface TabsListProps {
  children: React.ReactNode
  className?: string
  _value?: string
  _onValueChange?: (value: string) => void
}

function TabsList({ children, className, _value, _onValueChange }: TabsListProps) {
  return (
    <div className={cn("inline-flex items-center gap-1 p-1 bg-muted rounded-lg", className)}>
      {React.Children.map(children, (child) => {
        if (React.isValidElement(child)) {
          return React.cloneElement(child as React.ReactElement<any>, { _value, _onValueChange })
        }
        return child
      })}
    </div>
  )
}

interface TabsTriggerProps {
  value: string
  children: React.ReactNode
  className?: string
  disabled?: boolean
  _value?: string
  _onValueChange?: (value: string) => void
}

function TabsTrigger({ value, children, className, disabled, _value, _onValueChange }: TabsTriggerProps) {
  const isActive = _value === value
  return (
    <button
      onClick={() => _onValueChange?.(value)}
      disabled={disabled}
      className={cn(
        "inline-flex items-center justify-center whitespace-nowrap rounded-md px-3 py-1.5 text-sm font-medium transition-all",
        isActive ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
        disabled && "opacity-50 cursor-not-allowed",
        className
      )}
    >
      {children}
    </button>
  )
}

interface TabsContentProps {
  value: string
  children: React.ReactNode
  className?: string
  _value?: string
}

function TabsContent({ value, children, className, _value }: TabsContentProps) {
  if (_value !== value) return null
  return <div className={cn("mt-4", className)}>{children}</div>
}

export { Tabs, TabsList, TabsTrigger, TabsContent }
