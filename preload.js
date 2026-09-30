const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('api', {
  runExtraer: (options) => ipcRenderer.invoke('run-extraer', options),
  runYtVideo: (url) => ipcRenderer.invoke('run-ytvideo', url),
  runCompressVideo: (quality) => ipcRenderer.invoke('run-compress-video', quality),
  runRecuperarTodo: () => ipcRenderer.invoke('run-recuperar-todo'),
  runGrabarTodo: () => ipcRenderer.invoke('run-grabar-todo'),
  runPararTodo: () => ipcRenderer.invoke('run-parar-todo'),
  runRecuerdame: () => ipcRenderer.invoke('run-recuerdame'),
  pickFolder: () => ipcRenderer.invoke('pick-folder'),
  compareFolders: (src, dst) => ipcRenderer.invoke('compare-folders', { src, dst }),
  syncFolders: (src, dst) => ipcRenderer.invoke('sync-folders', { src, dst }),
  hideWindow: () => ipcRenderer.invoke('hide-window'),
  quitApp: () => ipcRenderer.invoke('quit-app'),
  getPathForFile: (file) => webUtils.getPathForFile(file)
});
