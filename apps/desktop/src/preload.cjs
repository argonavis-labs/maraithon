// Narrow UI bridge. Main validates the sender before every privileged action.
const {contextBridge, ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('maraithonDesktop', Object.freeze({
  platform: process.platform,
  signIn: () => ipcRenderer.invoke('desktop:sign-in'),
  retry: () => ipcRenderer.invoke('desktop:retry'),
  openSources: () => ipcRenderer.invoke('desktop:sources')
}));
window.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.desktop = process.platform; });
