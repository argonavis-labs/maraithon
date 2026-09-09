import { type ComponentProps, type MouseEventHandler, type ReactNode, useMemo } from 'react'
import { type Components, defaultRehypePlugins, defaultRemarkPlugins, Streamdown } from 'streamdown'
import { cn } from '@/lib/utils'

// Preserve Runner's sanitization pipeline. Maraithon exposes no file-mount URLs;
// transcript images cannot fetch external resources while rendering a message.
type RehypePlugins = NonNullable<ComponentProps<typeof Streamdown>['rehypePlugins']>
const BASE_REHYPE_PLUGINS = Object.entries(defaultRehypePlugins).map(([name, entry]) => {
  if (name !== 'harden') return entry
  const plugin = Array.isArray(entry) ? entry[0] : entry
  return [plugin, {
    allowedImagePrefixes: [],
    allowedLinkPrefixes: ['*'],
    allowedProtocols: ['http:', 'https:', 'mailto:'],
    defaultOrigin: window.location.origin,
    allowDataImages: false,
  }]
}) as RehypePlugins

/**
 * The standard preview anchor. Overrides that intercept navigation (memory's
 * in-app document links) render through this so link styling stays in one
 * place.
 */
const MARKDOWN_LINK_CLASS =
  'cursor-pointer text-foreground underline decoration-foreground/20 underline-offset-[3px] transition-colors duration-150 hover:decoration-foreground'

export function MarkdownLink({
  children,
  href,
  onClick,
}: {
  children?: ReactNode | undefined
  href?: string | undefined
  onClick?: MouseEventHandler<HTMLAnchorElement> | undefined
}) {
  return (
    <a
      className={MARKDOWN_LINK_CLASS}
      href={href}
      onClick={onClick}
      rel="noreferrer"
      target={href?.startsWith('/') && !href.startsWith('//') ? undefined : '_blank'}
    >
      {children}
    </a>
  )
}

/**
 * Runner-app markdown parity: Streamdown's stock element styles are sized for
 * a document, not a chat column. These values are ported from the desktop
 * app's minimal-mode Markdown — headings as small semibold labels, links as
 * foreground text with a soft underline, outside list markers, quiet tables
 * and dividers. Deliberate deviation: strong is font-medium, one step lighter
 * than the desktop's font-semibold, because Geist's 600 renders visibly
 * heavier than the desktop's system font at 600.
 */
const MARKDOWN_COMPONENTS: Components = {
  a: ({ children, href }) => <MarkdownLink href={href}>{children}</MarkdownLink>,
  // The harden stage blocks images; keep the source element renderer for parity.
  img: ({ alt, src }) => {
    if (typeof src !== 'string' || src === '') return null
    const image = (
      <img
        alt={alt ?? ''}
        className="my-2 inline-block max-h-[360px] max-w-full rounded-ui-md object-contain"
        loading="lazy"
        src={src}
      />
    )
    if (src.startsWith('data:')) return image
    return (
      <a href={src} rel="noreferrer" target="_blank">
        {image}
      </a>
    )
  },
  p: ({ children }) => <p className="my-2 leading-relaxed">{children}</p>,
  ul: ({ children }) => (
    <ul className="my-2 list-disc space-y-1 ps-[16px] pe-2 marker:text-runner-foreground-50">
      {children}
    </ul>
  ),
  ol: ({ children }) => <ol className="my-2 list-decimal space-y-1 pl-6">{children}</ol>,
  li: ({ children }) => <li className="my-0">{children}</li>,
  // Chat headings are labels, not page titles: h1/h2 share a size and differ
  // by position; 16/15px are desktop literals (between ui-md and ui-lg).
  h1: ({ children }) => (
    <h1 className="mt-5 mb-3 font-sans font-semibold text-[16px]">{children}</h1>
  ),
  h2: ({ children }) => (
    <h2 className="mt-4 mb-3 font-sans font-semibold text-[16px]">{children}</h2>
  ),
  h3: ({ children }) => (
    <h3 className="mt-4 mb-2 font-sans font-semibold text-[15px]">{children}</h3>
  ),
  h4: ({ children }) => (
    <h4 className="mt-4 mb-2 font-sans font-semibold text-[15px]">{children}</h4>
  ),
  h5: ({ children }) => (
    <h5 className="mt-4 mb-2 font-sans font-semibold text-[15px]">{children}</h5>
  ),
  h6: ({ children }) => (
    <h6 className="mt-4 mb-2 font-sans font-semibold text-[15px]">{children}</h6>
  ),
  blockquote: ({ children }) => (
    <blockquote className="my-2 border-muted-foreground/30 border-l-2 pl-3 text-muted-foreground italic">
      {children}
    </blockquote>
  ),
  strong: ({ children }) => <strong className="font-medium">{children}</strong>,
  hr: () => <hr className="my-4 border-border border-t" />,
  table: ({ children }) => (
    <div className="my-3 overflow-x-auto rounded-ui-md border border-border">
      <table className="min-w-full text-sm">{children}</table>
    </div>
  ),
  thead: ({ children }) => <thead className="border-b">{children}</thead>,
  tbody: ({ children }) => <tbody>{children}</tbody>,
  th: ({ children }) => (
    <th className="px-3 py-2 text-left font-semibold text-muted-foreground">{children}</th>
  ),
  td: ({ children }) => <td className="px-3 py-2">{children}</td>,
  tr: ({ children }) => <tr className="border-border/50 border-b last:border-b-0">{children}</tr>,
}

/**
 * The app's one markdown surface: session transcripts, memory documents, and
 * file previews all render through this. Callers may override individual
 * elements via `components`; overrides merge over the standard map.
 */
export function MarkdownPreview({
  children,
  className,
  components,
  onLinkClick,
  rehypePlugins,
  remarkPlugins,
  ...props
}: ComponentProps<typeof Streamdown> & {
  onLinkClick?: MouseEventHandler<HTMLAnchorElement> | undefined
}) {
  const linkComponents = useMemo<Components | undefined>(
    () =>
      onLinkClick
        ? {
            a: ({ children, href }) => (
              <MarkdownLink href={href} onClick={onLinkClick}>
                {children}
              </MarkdownLink>
            ),
          }
        : undefined,
    [onLinkClick],
  )
  const mergedComponents = useMemo(
    () =>
      components || linkComponents
        ? { ...MARKDOWN_COMPONENTS, ...linkComponents, ...components }
        : MARKDOWN_COMPONENTS,
    [components, linkComponents],
  )
  return (
    <Streamdown
      // Streamdown replaces its default remark pipeline (GFM included) when
      // remarkPlugins is set; append caller plugins to the defaults instead.
      remarkPlugins={
        remarkPlugins
          ? [...Object.values(defaultRemarkPlugins), ...remarkPlugins]
          : Object.values(defaultRemarkPlugins)
      }
      // Runner's default sanitize pipeline, with automatic image requests blocked.
      rehypePlugins={rehypePlugins ? [...BASE_REHYPE_PLUGINS, ...rehypePlugins] : BASE_REHYPE_PLUGINS}
      // w-full, never h-full (upstream ships size-full): a bubble holds many
      // response parts, and height:100% stretches each one to the whole
      // bubble's height — short parts become giant blanks and later parts
      // clip under the bubble's overflow-hidden.
      className={cn('w-full [&>*:first-child]:mt-0 [&>*:last-child]:mb-0', className)}
      components={mergedComponents}
      // Links must be real anchors. Streamdown's linkSafety defaults to
      // enabled, which renders every link as an underlined <button> behind a
      // confirmation modal — text that looks like a link but never navigates.
      // The Runner app opens links directly; so does this preview.
      linkSafety={{ enabled: false }}
      // Documents paint in one static pass; the session transcript opts back
      // into streaming per message part.
      mode="static"
      {...props}
      // Spread, not a JSX child: under exactOptionalPropertyTypes an
      // undefined child is not an optional `children`.
      {...(children === undefined ? {} : { children: children })}
    />
  )
}
