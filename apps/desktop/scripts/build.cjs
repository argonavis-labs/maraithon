// Validate the shell and copy the exact web tokens and licensed font assets.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
for (const filename of fs.readdirSync(path.join(root, 'src'))) {
  if (filename.endsWith('.cjs')) execFileSync(process.execPath, ['--check', path.join(root, 'src', filename)]);
}
for (const dir of ['styles/assets', 'fonts/geist']) fs.mkdirSync(path.join(root, dir), {recursive: true});
const staticDir = path.resolve(root, '../../priv/static');
for (const file of ['styles/runner-theme.css', 'styles/shell.css', 'styles/assets/texture-tile.png', 'fonts/geist/GeistVariable.woff2', 'fonts/geist/LICENSE', 'theme.js']) {
  fs.copyFileSync(path.join(staticDir, file), path.join(root, file));
}
fs.copyFileSync(path.join(staticDir, 'images/app-icon-512.png'), path.join(root, 'resources/icon.png'));
console.log('Desktop shell built with the shared web theme.');
