const { app, BrowserWindow, ipcMain, dialog, globalShortcut, Tray, Menu, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');

let mainWindow = null;
let tray = null;
let isQuitting = false;

const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (!mainWindow.isVisible()) mainWindow.show();
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });

  app.whenReady().then(() => {
    createWindow();
    createTray();

    const registered = globalShortcut.register('Super+Alt+Space', () => {
      toggleWindow();
    });

    if (!registered) {
      console.error('No se pudo registrar el atajo global Super+Alt+Space.');
    }
  });
}

function createWindow() {
  const iconPath = path.join(__dirname, 'icon.ico');
  mainWindow = new BrowserWindow({
    width: 680,
    height: 770,
    minWidth: 550,
    minHeight: 600,
    autoHideMenuBar: true,
    alwaysOnTop: false,
    icon: fs.existsSync(iconPath) ? iconPath : undefined,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile('index.html');

  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
}

function toggleWindow() {
  if (!mainWindow) return;
  if (mainWindow.isVisible()) {
    mainWindow.hide();
  } else {
    mainWindow.show();
    mainWindow.focus();
  }
}

function createMemoryIcon() {
  const size = 16;
  const buffer = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const idx = (y * size + x) * 4;
      const isBorder = (x === 0 || x === size - 1 || y === 0 || y === size - 1);
      if (isBorder) {
        buffer[idx] = 55;
        buffer[idx + 1] = 175;
        buffer[idx + 2] = 212;
      } else {
        buffer[idx] = 176;
        buffer[idx + 1] = 243;
        buffer[idx + 2] = 255;
      }
      buffer[idx + 3] = 255;
    }
  }
  return nativeImage.createFromBuffer(buffer, { width: size, height: size });
}

function createTray() {
  const trayIcon = createMemoryIcon();
  tray = new Tray(trayIcon);

  const contextMenu = Menu.buildFromTemplate([
    { label: 'Mostrar / Ocultar (Win+Alt+Espacio)', click: () => toggleWindow() },
    { type: 'separator' },
    {
      label: 'Salir de CliKit',
      click: () => {
        isQuitting = true;
        app.quit();
      }
    }
  ]);

  tray.setToolTip('CliKit by vivica (Win + Alt + Espacio)');
  tray.setContextMenu(contextMenu);

  tray.on('click', () => {
    toggleWindow();
  });
}

app.on('before-quit', () => {
  isQuitting = true;
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  } else if (mainWindow) {
    mainWindow.show();
  }
});

ipcMain.handle('hide-window', () => {
  if (mainWindow) mainWindow.hide();
});

ipcMain.handle('quit-app', () => {
  isQuitting = true;
  app.quit();
});

ipcMain.handle('pick-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory']
  });
  return result.canceled ? null : result.filePaths[0];
});

function getFunctionsPath() {
  if (app.isPackaged) {
    const unpacked = path.join(process.resourcesPath, 'app.asar.unpacked', 'functions.ps1');
    if (fs.existsSync(unpacked)) return unpacked;
  }
  return path.join(__dirname, 'functions.ps1');
}

function validatePath(p) {
  if (!p || typeof p !== 'string') return false;
  const trimmed = p.trim();
  if (!trimmed) return false;
  if (/[\x00-\x1f<>"|?*]/.test(trimmed)) return false;
  return fs.existsSync(trimmed);
}

function validateUrl(u) {
  if (!u || typeof u !== 'string') return false;
  try {
    const parsed = new URL(u.trim());
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

function runPowerShell(cmd) {
  return new Promise((resolve) => {
    try {
      const funcsPath = getFunctionsPath().replace(/\\/g, '/').replace(/'/g, "''");
      const fullCmd = `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; . '${funcsPath}'; ${cmd}`;
      const encoded = Buffer.from(fullCmd, 'utf16le').toString('base64');
      exec(`pwsh.exe -NoProfile -OutputFormat Text -EncodedCommand ${encoded}`, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
        if (error) {
          const errMsg = stderr || error.message || '';
          if (errMsg.includes('pwsh.exe') || error.code === 'ENOENT') {
            resolve('[ERROR] PowerShell 7 (pwsh.exe) no está instalado o no se encuentra en el PATH.\nPuedes instalarlo desde "Antes de usar".');
          } else {
            resolve(`[ERROR] ${errMsg.trim()}`);
          }
        } else {
          resolve(stdout.trim() || '[OK] Operación completada.');
        }
      });
    } catch (err) {
      resolve(`[ERROR] ${err.message}`);
    }
  });
}

ipcMain.handle('run-extraer', async (_, { path: targetPath, includePdf, excludeExt }) => {
  if (!targetPath || typeof targetPath !== 'string') return '[ERROR] Ruta no especificada.';
  const trimmedPath = targetPath.trim();
  if (!validatePath(trimmedPath)) return '[ERROR] La ruta no existe o contiene caracteres no permitidos.';
  const safePath = trimmedPath.replace(/'/g, "''");
  let cmd = `extraer -Path '${safePath}'`;
  if (includePdf) cmd += ' -IncludePdf';
  if (typeof excludeExt === 'string') {
    const list = excludeExt.split(',').map(e => e.trim()).filter(Boolean);
    cmd += ` -ExcludeExtensions @(${list.map(e => `'${e}'`).join(',')})`;
  }
  return await runPowerShell(cmd);
});

ipcMain.handle('run-ytvideo', async (_, input) => {
  if (!input || typeof input !== 'string') return '[ERROR] URL no especificada.';
  const matches = input.match(/https?:\/\/[^\s,;"'<>]+/g);
  if (!matches || matches.length === 0) {
    return '[ERROR] No se encontraron URLs válidas. Deben empezar por http:// o https://';
  }
  const safeUrls = matches.map(u => `'${u.replace(/'/g, "''")}'`).join(',');
  return await runPowerShell(`yt-video -Url @(${safeUrls})`);
});

ipcMain.handle('run-compress-video', async (_, quality) => {
  const safeQuality = ['low', 'medium', 'high'].includes(quality) ? quality : 'medium';
  return await runPowerShell(`compress-video -Quality ${safeQuality}`);
});

ipcMain.handle('run-recuperar-todo', async () => runPowerShell('recuperar-todo'));
ipcMain.handle('run-parar-todo', async () => runPowerShell('parar-todo'));

function scanDir(dir, baseDir = dir) {
  let results = {};
  if (!fs.existsSync(dir)) return results;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return results;
  }

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    const relPath = path.relative(baseDir, fullPath).replace(/\\/g, '/');
    if (entry.isDirectory()) {
      if (['node_modules', '.git', 'dist', 'build', '.vscode', '.idea', 'vendor', '__pycache__'].includes(entry.name.toLowerCase())) {
        continue;
      }
      Object.assign(results, scanDir(fullPath, baseDir));
    } else if (entry.isFile()) {
      try {
        const stats = fs.statSync(fullPath);
        results[relPath] = { size: stats.size, mtime: stats.mtimeMs };
      } catch {}
    }
  }
  return results;
}

ipcMain.handle('compare-folders', async (_, { src, dst }) => {
  if (!src || !dst) return '[ERROR] Especifica ambas carpetas.';
  if (!fs.existsSync(src)) return `[ERROR] No existe origen: ${src}`;
  if (!fs.existsSync(dst)) return `[ERROR] No existe destino: ${dst}`;
  if (path.resolve(src).toLowerCase() === path.resolve(dst).toLowerCase()) {
    return '[ERROR] Origen y destino son la misma carpeta.';
  }

  const srcFiles = scanDir(src);
  const dstFiles = scanDir(dst);

  const allKeys = Array.from(new Set([...Object.keys(srcFiles), ...Object.keys(dstFiles)])).sort();
  let diffLines = [];
  let counts = { onlySrc: 0, onlyDst: 0, modified: 0, identical: 0 };

  for (const key of allKeys) {
    const inSrc = key in srcFiles;
    const inDst = key in dstFiles;

    if (inSrc && !inDst) {
      diffLines.push(`[+] Solo Origen:  ${key}`);
      counts.onlySrc++;
    } else if (!inSrc && inDst) {
      diffLines.push(`[-] Solo Destino: ${key}`);
      counts.onlyDst++;
    } else {
      const s = srcFiles[key];
      const d = dstFiles[key];
      if (s.size !== d.size) {
        diffLines.push(`[~] Modificado:   ${key} (${s.size}B vs ${d.size}B)`);
        counts.modified++;
      } else {
        counts.identical++;
      }
    }
  }

  const header = `DIFF: =${counts.identical} | +${counts.onlySrc} (solo orig) | -${counts.onlyDst} (solo dest) | ~${counts.modified} (cambiados)`;
  const body = diffLines.length ? diffLines.join('\n') : 'Directorios idénticos.';
  return `${header}\n${'-'.repeat(50)}\n${body}`;
});

ipcMain.handle('sync-folders', async (_, { src, dst }) => {
  if (!src || !dst) return '[ERROR] Especifica ambas carpetas.';
  if (!fs.existsSync(src)) return `[ERROR] No existe origen: ${src}`;
  if (!fs.existsSync(dst)) return `[ERROR] No existe destino: ${dst}`;
  if (path.resolve(src).toLowerCase() === path.resolve(dst).toLowerCase()) {
    return '[ERROR] Origen y destino son la misma carpeta.';
  }

  const srcFiles = scanDir(src);
  const dstFiles = scanDir(dst);

  let copied = 0;
  let logOutput = [];

  for (const relPath of Object.keys(srcFiles)) {
    const inDst = relPath in dstFiles;
    const needsCopy = !inDst || (srcFiles[relPath].size !== dstFiles[relPath].size);

    if (needsCopy) {
      const srcFull = path.join(src, relPath);
      const dstFull = path.join(dst, relPath);
      try {
        fs.mkdirSync(path.dirname(dstFull), { recursive: true });
        fs.copyFileSync(srcFull, dstFull);
        logOutput.push(`[SYNC] Copiado: ${relPath}`);
        copied++;
      } catch (e) {
        logOutput.push(`[ERROR] No se pudo copiar: ${relPath} (${e.message})`);
      }
    }
  }

  const resMsg = `SINCRONIZACIÓN COMPLETADA: ${copied} archivo(s) actualizados en Destino.`;
  return `${resMsg}\n${'-'.repeat(50)}\n${logOutput.length ? logOutput.join('\n') : 'Destino ya estaba al día.'}`;
});
