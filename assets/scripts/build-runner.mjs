import {execFileSync} from 'node:child_process'
import {readFileSync, writeFileSync, mkdirSync, rmSync} from 'node:fs'
import postcss from 'postcss'

// Compile Runner's actual Tailwind 4 recipes without changing Phoenix's Tailwind 3 pages.
mkdirSync('../priv/static/assets', {recursive: true})
const temporary = '../priv/static/assets/.runner-unscoped.css'
execFileSync(process.execPath, ['node_modules/@tailwindcss/cli/dist/index.mjs', '-i', 'css/runner-components.css', '-o', temporary], {stdio: 'inherit'})
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
