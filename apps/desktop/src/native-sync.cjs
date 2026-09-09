// Keep the existing app path as well as its identity: macOS privacy grants do
// not reliably follow a signed companion copied inside a different app bundle.
const {app, dialog} = require('electron');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const fs = require('node:fs');
const path = require('node:path');
const run = promisify(execFile);
let launching;

async function isCompanion(bundle) {
  try {
    const identity = await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(bundle, 'Contents/Info.plist')]);
    return identity.stdout.trim() === 'com.maraithon.companion';
  } catch { return false; }
}
async function runningHelper() {
  try {
    const {stdout} = await run('/usr/bin/pgrep', ['-x', 'Maraithon']);
    for (const pid of stdout.trim().split(/\s+/).slice(0, 16)) {
      if (!/^\d+$/.test(pid)) continue;
      const result = await run('/bin/ps', ['-p', pid, '-o', 'comm=']);
      const executable = result.stdout.trim();
      if (!executable.endsWith('/Contents/MacOS/Maraithon')) continue;
      const bundle = executable.slice(0, -'/Contents/MacOS/Maraithon'.length);
      if (await isCompanion(bundle)) return bundle;
    }
  } catch { /* No running companion. */ }
  return null;
}
async function helperPath() {
  if (process.env.MARAITHON_NATIVE_HELPER) return path.resolve(process.env.MARAITHON_NATIVE_HELPER);
  const canonical = path.join(app.getPath('home'), 'Applications/Maraithon.app');
  for (const installed of [canonical, '/Applications/Maraithon.app']) {
    if (await isCompanion(installed)) return installed;
  }
  const bundled = app.isPackaged ? path.join(process.resourcesPath, 'Maraithon.app') : path.join(app.getAppPath(), 'native/Maraithon.app');
  if (!await isCompanion(bundled)) return null;
  // First install only. Never replace an existing companion or reset its grants.
  if (fs.existsSync(canonical)) throw new Error('A different app occupies ~/Applications/Maraithon.app. Set MARAITHON_NATIVE_HELPER to your signed companion.');
  fs.mkdirSync(path.dirname(canonical), {recursive: true});
  await run('/usr/bin/ditto', [bundled, canonical]);
  return canonical;
}
async function launchSources({background = false} = {}) {
  if (process.platform !== 'darwin') {
    if (!background) await dialog.showMessageBox({type: 'info', message: 'Mac sources are available on macOS.', detail: 'Your synced tasks and connected apps are available on every platform.'});
    return;
  }
  const running = await runningHelper();
  if (running) {
    if (!background) await run('/usr/bin/open', ['-a', running]);
    return;
  }
  const helper = await helperPath();
  if (!helper || !fs.existsSync(helper)) {
    if (!background) await dialog.showMessageBox({type: 'info', message: 'Build the Mac source service first.', detail: 'Run npm run build:native in apps/desktop. Your existing Maraithon companion keeps syncing independently.'});
    return;
  }
  await run('/usr/bin/open', [...(background ? ['-g'] : []), '-a', helper, '--args', '--sync-helper', ...(background ? [] : ['--show-sources'])]);
}
async function openSources(options = {}) {
  if (launching) {
    await launching;
    if (options.background) return;
  }
  launching = launchSources(options);
  try { await launching; } finally { launching = undefined; }
}
module.exports = {openSources};
