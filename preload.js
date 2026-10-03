const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('api', {
  runExtraer: (options) => ipcRenderer.invoke('run-extraer', options),
  runWhisper: (options) => ipcRenderer.invoke('run-whisper', options),
  runYtVideo: (url) => ipcRenderer.invoke('run-ytvideo', url),
  runCompressVideo: (quality) => ipcRenderer.invoke('run-compress-video', quality),
  runRecuperarTodo: () => ipcRenderer.invoke('run-recuperar-todo'),
  runPararTodo: () => ipcRenderer.invoke('run-parar-todo'),
  pickFolder: (mode) => ipcRenderer.invoke('pick-path', mode || 'folder'),
  pickPath: (mode) => ipcRenderer.invoke('pick-path', mode),
  pickPathMenu: (type) => ipcRenderer.invoke('pick-path-menu', type),
  compareFolders: (src, dst) => ipcRenderer.invoke('compare-folders', { src, dst }),
  syncFolders: (src, dst) => ipcRenderer.invoke('sync-folders', { src, dst }),
  hideWindow: () => ipcRenderer.invoke('hide-window'),
  quitApp: () => ipcRenderer.invoke('quit-app'),
  getPathForFile: (file) => webUtils.getPathForFile(file)
});
