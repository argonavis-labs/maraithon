// Build a local app using the same development identity as the native helper.
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const args = ['--dir', '--publish', 'never'];
if (process.platform === 'darwin' && !process.env.CSC_NAME) {
  const {spawnSync} = require('node:child_process');
  const result = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', path.join(root, 'native/Maraithon.app')], {encoding: 'utf8'});
  if (result.status !== 0) throw new Error('Build and sign the Mac source service first.');
  const identity = result.stderr.match(/^Authority=(Apple Development: .+)$/m)?.[1];
  if (identity) args.push(`--config.mac.identity=${identity}`, '--config.mac.type=development');
}
execFileSync(path.join(root, 'node_modules/.bin/electron-builder'), args, {cwd: root, stdio: 'inherit'});
