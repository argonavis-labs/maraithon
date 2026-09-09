// Preserve the signed companion's identity, Keychain and TCC grants. LaunchServices
// reuses a running instance, so Electron never creates a second source poller.
const {app, dialog} = require('electron');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const fs = require('node:fs');
const path = require('node:path');
const run = promisify(execFile);
function helperPath() {
  if (process.env.MARAITHON_NATIVE_HELPER) return path.resolve(process.env.MARAITHON_NATIVE_HELPER);
  return app.isPackaged ? path.join(process.resourcesPath, 'Maraithon.app') : path.join(app.getAppPath(), 'native/Maraithon.app');
}
async function runningHelper() {
  try {
    const {stdout} = await run('/usr/bin/pgrep', ['-x', 'Maraithon']);
    for (const pid of stdout.trim().split(/\s+/).slice(0, 16)) {
      if (!/^\d+$/.test(pid)) continue;
      const process = await run('/bin/ps', ['-p', pid, '-o', 'comm=']);
      const executable = process.stdout.trim();
      if (!executable.endsWith('/Contents/MacOS/Maraithon')) continue;
      const bundle = executable.slice(0, -'/Contents/MacOS/Maraithon'.length);
      const identity = await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(bundle, 'Contents/Info.plist')]);
      if (identity.stdout.trim() === 'com.maraithon.companion') return bundle;
    }
  } catch { /* No running companion. */ }
  return null;
}
async function openSources({background = false} = {}) {
  if (process.platform !== 'darwin') {
    if (!background) await dialog.showMessageBox({type: 'info', message: 'Mac sources are available on macOS.', detail: 'Your synced tasks and connected apps are available on every platform.'});
    return;
  }
  const running = await runningHelper();
  if (running) {
    if (!background) await run('/usr/bin/open', ['-a', running]);
    return;
  }
  const helper = helperPath();
  if (!fs.existsSync(helper)) {
    if (!background) await dialog.showMessageBox({type: 'info', message: 'Build the Mac source service first.', detail: 'Run npm run build:native in apps/desktop. Your existing Maraithon companion keeps syncing independently.'});
    return;
  }
  await run('/usr/bin/open', [...(background ? ['-g'] : []), '-a', helper, '--args', '--sync-helper', ...(background ? [] : ['--show-sources'])]);
}
module.exports = {openSources};
