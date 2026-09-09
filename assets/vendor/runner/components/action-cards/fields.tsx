import type { ComponentProps, ReactNode } from 'react'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { cn } from '@/lib/utils'

export function humanizeKey(key: string): string {
  const spaced = key
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .toLowerCase()
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

function displayValue(value: unknown): string {
  if (typeof value === 'string') return value
  const text = JSON.stringify(value, null, 1)
  return text === undefined ? String(value) : text
}

// Fields sit borderless on the card surface so the form reads as one continuous sheet.
const BARE_CONTROL =
  'h-auto min-h-0 rounded-none border-0 bg-transparent px-0 py-0 text-ui-base shadow-none focus-visible:border-0 focus-visible:ring-0 disabled:bg-transparent'

// Borderless inline row styling shared by every composer row (desktop-app parity).
export const FIELD_LABEL_CLASS = 'shrink-0 pr-3 font-normal text-muted-foreground text-ui-base'

export function ReadOnlyRow({
  label,
  labelClassName,
  secondary,
  trailing,
  value,
}: {
  label: string
  labelClassName?: string | undefined
  secondary?: string | undefined
  trailing?: ReactNode | undefined
  value: unknown
}) {
  return (
    <div className="flex items-baseline">
      <div className={cn(FIELD_LABEL_CLASS, labelClassName)}>{label}</div>
      <div className="flex min-w-0 flex-1 items-baseline gap-2">
        <div className="min-w-0 flex-1 whitespace-pre-wrap break-words text-ui-base">
          {displayValue(value)}
          {secondary !== undefined && (
            <span className="ml-2 break-all text-runner-foreground-50">{secondary}</span>
          )}
        </div>
        {trailing}
      </div>
    </div>
  )
}

/** Args the family body didn't claim, minus plumbing keys — still shown so every reviewed argument stays visible. */
export function extraArgEntries(
  args: Record<string, unknown>,
  except: readonly string[],
): [string, unknown][] {
  return Object.entries(args).filter(([key]) => !except.includes(key) && key !== 'connectionId')
}

export function ExtraArgRows({
  args,
  except,
}: {
  args: Record<string, unknown>
  except: readonly string[]
}) {
  return (
    <>
      {extraArgEntries(args, except).map(([key, value]) => (
        <ReadOnlyRow key={key} label={humanizeKey(key)} value={value} />
      ))}
    </>
  )
}

export function FieldRow({
  id,
  label,
  labelClassName,
  locked,
  multiline,
  onChange,
  placeholder,
  step,
  trailing,
  type,
  value,
}: {
  id: string
  label: string
  labelClassName?: string | undefined
  locked: boolean
  multiline?: boolean | undefined
  onChange: (value: string) => void
  placeholder?: string | undefined
  step?: ComponentProps<'input'>['step'] | undefined
  trailing?: ReactNode | undefined
  type?: ComponentProps<'input'>['type'] | undefined
  value: string
}) {
  const control = multiline ? (
    <Textarea
      className={`${BARE_CONTROL} max-h-44 min-h-12`}
      disabled={locked}
      id={id}
      onChange={(event) => onChange(event.currentTarget.value)}
      placeholder={placeholder}
      value={value}
    />
  ) : (
    <Input
      className={BARE_CONTROL}
      disabled={locked}
      id={id}
      onChange={(event) => onChange(event.currentTarget.value)}
      placeholder={placeholder}
      step={step}
      type={type}
      value={value}
    />
  )
  return (
    <div className={`flex ${multiline ? 'items-start pt-1' : 'items-center'}`}>
      <label className={cn(FIELD_LABEL_CLASS, labelClassName)} htmlFor={id}>
        {label}
      </label>
      <div className="flex min-w-0 flex-1 items-center gap-2">
        <div className="min-w-0 flex-1">{control}</div>
        {trailing}
      </div>
    </div>
  )
}
