// Electron owns the task window. Phoenix owns data; the signed Mac helper owns sync.
const {app, BrowserWindow, Menu, ipcMain, session, shell, dialog, screen} = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {origin, partition, sameOrigin} = require('./config.cjs');
const {startSignIn, cancelSignIn} = require('./sign-in.cjs');
const {openSources} = require('./native-sync.cjs');
app.setName('Maraithon Desktop');
if (process.env.MARAITHON_DESKTOP_USER_DATA) app.setPath('userData', path.resolve(process.env.MARAITHON_DESKTOP_USER_DATA));
const localPages = new Set(['welcome', 'offline'].map(name => pathToFileURL(path.join(__dirname, `../pages/${name}.html`)).href));
let window;
let quitting = false;
let lastPath = '/todos';

function report(error) { dialog.showErrorBox('Maraithon', error.message || 'Could not complete this action.'); }
function trusted(event, localOnly = false) {
  const frame = event.senderFrame;
  return window && event.sender === window.webContents && frame === window.webContents.mainFrame &&
    (localPages.has(frame.url) || (!localOnly && sameOrigin(frame.url)));
}
function openExternal(value) {
  try {
    const url = new URL(value);
    if (['https:', 'http:', 'mailto:', 'sms:'].includes(url.protocol) && !/[\r\n]/.test(value)) shell.openExternal(value).catch(report);
  } catch {}
}
const navigationInterrupted = error => error.code === 'ERR_ABORTED' || error.errno === -3;
async function showLocal(name) {
  try {
    if (window && !window.isDestroyed()) await window.loadFile(path.join(__dirname, `../pages/${name}.html`));
  } catch (error) { if (!navigationInterrupted(error)) throw error; }
}
async function loadWorkspace(route = lastPath) {
  if (!window || window.isDestroyed()) createWindow();
  window.show();
  window.focus();
  try { await window.loadURL(`${origin}${route}`); }
  catch (error) { if (!navigationInterrupted(error)) await showLocal('offline'); }
}
function navigation(event, url) {
  if (localPages.has(url)) return;
  if (!sameOrigin(url)) { event.preventDefault(); openExternal(url); return; }
  // OAuth connector consent belongs to the system browser's cookie session.
  if (/^\/auth\/(google|github|slack|linear|notion|notaui)(\/|$)/.test(new URL(url).pathname)) {
    event.preventDefault(); openExternal(url);
  }
}
function readBounds() {
  try {
    const value = JSON.parse(fs.readFileSync(path.join(app.getPath('userData'), 'window.json'), 'utf8'));
    const valid = ['x', 'y', 'width', 'height'].every(key => Number.isFinite(value[key]));
    if (valid && value.width >= 900 && value.height >= 620 && screen.getAllDisplays().some(({workArea: area}) =>
      value.x < area.x + area.width && value.x + value.width > area.x && value.y < area.y + area.height && value.y + value.height > area.y)) return value;
  } catch {}
  return {width: 1380, height: 900};
}
function createWindow() {
  window = new BrowserWindow({
    ...readBounds(), title: 'Maraithon', minWidth: 900, minHeight: 620,
    backgroundColor: '#fcfcfa', show: false, icon: path.join(__dirname, '../resources/icon.png'),
    ...(process.platform === 'darwin' ? {titleBarStyle: 'hiddenInset', trafficLightPosition: {x: 18, y: 18}} : {}),
    webPreferences: {preload: path.join(__dirname, 'preload.cjs'), partition, contextIsolation: true, nodeIntegration: false, sandbox: true, webviewTag: false, spellcheck: true}
  });
  window.once('ready-to-show', () => window?.show());
  window.webContents.setWindowOpenHandler(({url}) => { openExternal(url); return {action: 'deny'}; });
  window.webContents.on('will-navigate', navigation);
  window.webContents.on('will-redirect', navigation);
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('page-title-updated', event => event.preventDefault());
  const trackNavigation = (_event, url) => {
    if (!sameOrigin(url)) return;
    const parsed = new URL(url);
    if (parsed.pathname === '/' || parsed.pathname === '/login') { showLocal('welcome').catch(report); return; }
    if (!parsed.pathname.startsWith('/auth') && !parsed.pathname.startsWith('/desktop')) lastPath = parsed.pathname + parsed.search;
  };
  window.webContents.on('did-navigate', trackNavigation);
  window.webContents.on('did-navigate-in-page', trackNavigation);
  window.webContents.on('did-fail-load', (_event, code, _description, url, mainFrame) => {
    if (mainFrame && code !== -3 && sameOrigin(url)) showLocal('offline').catch(report);
  });
  window.webContents.on('render-process-gone', () => showLocal('offline').catch(report));
  window.on('close', event => {
    try {
      fs.mkdirSync(app.getPath('userData'), {recursive: true});
      fs.writeFileSync(path.join(app.getPath('userData'), 'window.json'), JSON.stringify(window.getNormalBounds()));
    } catch {}
    if (!quitting && process.platform === 'darwin') { event.preventDefault(); window.hide(); }
  });
  window.on('closed', () => { window = undefined; });
}
function createMenu() {
  const route = to => () => loadWorkspace(to).catch(report);
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{label: 'Maraithon', submenu: [
      {role: 'about'}, {type: 'separator'},
      {label: 'Mac sources…', accelerator: 'Cmd+,', click: () => openSources().catch(report)},
      {type: 'separator'}, {role: 'hide'}, {role: 'hideOthers'}, {role: 'unhide'}, {type: 'separator'}, {role: 'quit'}
    ]}] : []),
    {label: 'Workspace', submenu: [
      {label: 'Tasks', accelerator: 'CmdOrCtrl+1', click: route('/todos')},
      {label: 'Daily brief', accelerator: 'CmdOrCtrl+2', click: route('/briefing')},
      {label: 'People', accelerator: 'CmdOrCtrl+3', click: route('/operator/people')},
      {label: 'Apps', click: route('/connectors')}, {type: 'separator'},
      {label: 'Open in browser', click: () => openExternal(`${origin}${lastPath}`)},
      {role: 'close'}
    ]},
    {role: 'editMenu'},
    {label: 'View', submenu: [
      {label: 'Reload workspace', accelerator: 'CmdOrCtrl+R', click: () => loadWorkspace().catch(report)},
      ...(!app.isPackaged ? [{role: 'forceReload'}, {role: 'toggleDevTools'}] : []),
      {type: 'separator'}, {role: 'resetZoom'}, {role: 'zoomIn'}, {role: 'zoomOut'}, {type: 'separator'}, {role: 'togglefullscreen'}
    ]},
    {role: 'windowMenu'},
    {role: 'help', submenu: [{label: 'Maraithon support', click: () => openExternal(`${origin}/support`)}]}
  ]));
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); } });
  app.whenReady().then(async () => {
    const browserSession = session.fromPartition(partition);
    if (!app.isPackaged) await browserSession.clearCache();
    // Draft cards can write text to the clipboard; no clipboard read or other
    // device permission is granted to remote content or subframes.
    const canWriteClipboard = (contents, permission, url, isMainFrame) => Boolean(
      window && contents === window.webContents && permission === 'clipboard-sanitized-write' &&
      isMainFrame && sameOrigin(url) && sameOrigin(contents.getURL())
    );
    browserSession.setPermissionRequestHandler((contents, permission, callback, details) => {
      callback(canWriteClipboard(contents, permission, details.requestingUrl, details.isMainFrame));
    });
    browserSession.setPermissionCheckHandler((contents, permission, requestingOrigin, details) =>
      canWriteClipboard(contents, permission, details.requestingUrl || requestingOrigin, details.isMainFrame)
    );
    ipcMain.handle('desktop:sign-in', async event => {
      if (!trusted(event, true)) throw new Error('Untrusted sign-in request.');
      await startSignIn(browserSession, () => loadWorkspace('/todos').catch(report), report);
    });
    ipcMain.handle('desktop:retry', async event => {
      if (!trusted(event, true)) throw new Error('Untrusted retry request.');
      await loadWorkspace();
    });
    ipcMain.handle('desktop:sources', async event => {
      if (!trusted(event)) throw new Error('Untrusted source request.');
      await openSources();
    });
    createWindow();
    createMenu();
    await loadWorkspace('/todos');
    // Native sync intentionally outlives closing or quitting the task window.
    if (process.env.MARAITHON_START_NATIVE !== '0' && (app.isPackaged || process.env.MARAITHON_START_NATIVE === '1')) openSources({background: true}).catch(report);
  }).catch(report);
  app.on('activate', () => { if (window) { window.show(); window.focus(); } else loadWorkspace().catch(report); });
  app.on('before-quit', () => { quitting = true; cancelSignIn(); });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}
