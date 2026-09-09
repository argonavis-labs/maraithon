import {execFileSync} from 'node:child_process'
import {readFileSync, writeFileSync, mkdirSync, rmSync} from 'node:fs'
import postcss from 'postcss'

// Compile Runner's actual Tailwind 4 recipes without changing Phoenix's Tailwind 3 pages.
mkdirSync('../priv/static/assets', {recursive: true})
const temporary = '../priv/static/assets/.runner-unscoped.css'
const theme = postcss.atRule({name: 'theme', params: 'inline'})
postcss.parse(readFileSync('../priv/static/styles/runner-theme.css', 'utf8')).walkRules(':root', rule => {
  if (rule.parent.type !== 'root') return
  rule.walkDecls(/^--(font|text|radius|shadow)-/, declaration => {
    if (/^--text-ui-.*--line-height$/.test(declaration.prop)) return
    theme.append(declaration.clone({value: declaration.prop.startsWith('--text-ui-')
      ? `var(--maraithon-${declaration.prop.slice(2)})` : declaration.value}))
  })
})
// stdin keeps relative @source paths rooted in assets/css without a generated source file.
execFileSync(process.execPath, ['../node_modules/@tailwindcss/cli/dist/index.mjs', '-i', '-', '-o', `../${temporary}`, '--minify'], {
  cwd: 'css', input: readFileSync('css/runner-components.css', 'utf8') + theme, stdio: ['pipe', 'inherit', 'inherit']
})
const css = postcss.parse(readFileSync(temporary, 'utf8'))
css.walkRules(rule => {
  let parent = rule.parent
  while (parent) {
    if (parent.type === 'rule' || (parent.type === 'atrule' && /keyframes$/.test(parent.name))) return
    parent = parent.parent
  }
  rule.selectors = rule.selectors.map(selector =>
    /^(?::root|:host|html|body)$/.test(selector.trim())
      ? '.runner-components'
      : `.runner-components ${selector}`)
})
// Phoenix's stylesheet is unlayered; the scoped rules must participate in that cascade.
css.walkAtRules('layer', rule => rule.nodes ? rule.replaceWith(...rule.nodes) : rule.remove())
writeFileSync('../priv/static/assets/runner-components.css', css.toString())
rmSync(temporary)
