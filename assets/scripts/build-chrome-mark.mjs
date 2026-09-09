// Compose the existing provider mark with Runner's source vector. No browser bundle is modified.
import {readFileSync, writeFileSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {fileURLToPath} from 'node:url'

const root = fileURLToPath(new URL('../../', import.meta.url))
const chrome = readFileSync(`${root}priv/static/images/connector-logos/chrome.png`).toString('base64')
const runner = readFileSync(`${root}assets/branding/runner-mark.svg`, 'utf8').match(/<path[\s\S]*?\/>/)[0]
const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="128" height="128" viewBox="0 0 128 128"><title>Local Chrome with Runner</title><image width="116" height="116" xlink:href="data:image/png;base64,${chrome}"/><circle cx="97" cy="97" r="29" fill="#242320" stroke="#fff" stroke-width="4"/><g transform="translate(78 82) scale(.48)">${runner}</g></svg>\n`
const output = `${root}priv/static/images/connector-logos/runner-chrome.svg`
writeFileSync(output, svg)
// Native resource bundles need PNG. Render from the same vector used on the web.
for (const path of [
  'apps/companion/Sources/Maraithon/Resources/TodoProviderRunnerChrome.png',
  'apps/mobile/MaraithonMobile/Resources/Assets.xcassets/ProviderChromeLogo.imageset/chrome.png',
]) execFileSync('rsvg-convert', ['-w', '256', '-h', '256', '-o', `${root}${path}`, output])
