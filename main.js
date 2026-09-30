const { app, BrowserWindow, ipcMain, dialog, globalShortcut, Tray, Menu, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');

let mainWindow;
let tray = null;
let isQuitting = false;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 680,
    height: 770,
    minWidth: 550,
    minHeight: 600,
    autoHideMenuBar: true,
    alwaysOnTop: false,
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
    return false;
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

// Icono 16x16 color Amarillo Crema (#FFF3B0) con borde dorado en formato BGRA nativo
function createMemoryIcon() {
  const size = 16;
  const buffer = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const idx = (y * size + x) * 4;
      const isBorder = (x === 0 || x === size - 1 || y === 0 || y === size - 1);
      if (isBorder) {
        // Borde dorado suave (#D4AF37 -> B: 55, G: 175, R: 212)
        buffer[idx] = 55;      // B
        buffer[idx + 1] = 175; // G
        buffer[idx + 2] = 212; // R
      } else {
        // Relleno amarillo crema (#FFF3B0 -> B: 176, G: 243, R: 255)
        buffer[idx] = 176;     // B
        buffer[idx + 1] = 243; // G
        buffer[idx + 2] = 255; // R
      }
      buffer[idx + 3] = 255;   // Alpha
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

  tray.setToolTip('CliKit by Vortic (Win + Alt + Espacio)');
  tray.setContextMenu(contextMenu);

  tray.on('click', () => {
    toggleWindow();
  });
}

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

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
  else mainWindow.show();
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

// Ruta exacta de tu perfil de PowerShell 7
const profilePath = '[PROFILE_PATH]';

// Ejecutor usando pwsh.exe (PowerShell 7) cargando explícitamente tu perfil
function runPowerShell(cmd) {
  return new Promise((resolve) => {
    const localFuncs = path.join(__dirname, 'functions.ps1').replace(/\\/g, '/');
    const fullCmd = `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; . '${localFuncs}'; ${cmd}`;
    exec(`pwsh.exe -NoProfile -Command "${fullCmd.replace(/"/g, '\\"')}"`, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
      if (error) resolve(`[ERROR] ${stderr || error.message}`);
      else resolve(stdout.trim() || '[OK] Operacion completada.');
    });
  });
}

ipcMain.handle('run-extraer', async (_, { path: targetPath, includePdf, excludeExt }) => {
  if (!targetPath) return '[ERROR] Ruta no especificada.';
  let cmd = `extraer -Path '${targetPath}'`;
  if (includePdf) cmd += ' -IncludePdf';
  if (excludeExt) cmd += ` -ExcludeExtensions @(${excludeExt.split(',').map(e => `'${e}'`).join(',')})`;
  return await runPowerShell(cmd);
});

ipcMain.handle('run-ytvideo', async (_, url) => {
  if (!url) return '[ERROR] URL no especificada.';
  return await runPowerShell(`yt-video -Url '${url}'`);
});

ipcMain.handle('run-compress-video', async (_, quality) => {
  return await runPowerShell(`compress-video -Quality ${quality || 'medium'}`);
});

ipcMain.handle('run-recuperar-todo', async () => runPowerShell('recuperar-todo'));
ipcMain.handle('run-grabar-todo', async () => runPowerShell('grabar-todo'));
ipcMain.handle('run-parar-todo', async () => runPowerShell('parar-todo'));
ipcMain.handle('run-recuerdame', async () => runPowerShell('recuerdame'));

function scanDir(dir, baseDir = dir) {
  let results = {};
  if (!fs.existsSync(dir)) return results;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    const relPath = path.relative(baseDir, fullPath).replace(/\\/g, '/');
    if (entry.isDirectory()) {
      if (['node_modules', '.git', 'dist', 'vendor'].includes(entry.name)) continue;
      Object.assign(results, scanDir(fullPath, baseDir));
    } else {
      const stats = fs.statSync(fullPath);
      results[relPath] = { size: stats.size, mtime: stats.mtimeMs };
    }
  }
  return results;
}

ipcMain.handle('compare-folders', async (_, { src, dst }) => {
  if (!src || !dst) return '[ERROR] Especifica ambas carpetas.';
  if (!fs.existsSync(src)) return `[ERROR] No existe origen: ${src}`;
  if (!fs.existsSync(dst)) return `[ERROR] No existe destino: ${dst}`;

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
  const body = diffLines.length ? diffLines.join('\n') : 'Directorios identicos.';
  return `${header}\n${'-'.repeat(50)}\n${body}`;
});

ipcMain.handle('sync-folders', async (_, { src, dst }) => {
  if (!src || !dst) return '[ERROR] Especifica ambas carpetas.';
  if (!fs.existsSync(src)) return `[ERROR] No existe origen: ${src}`;
  if (!fs.existsSync(dst)) return `[ERROR] No existe destino: ${dst}`;

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

      fs.mkdirSync(path.dirname(dstFull), { recursive: true });
      fs.copyFileSync(srcFull, dstFull);
      logOutput.push(`[SYNC] Copiado: ${relPath}`);
      copied++;
    }
  }

  const resMsg = `SINCRONIZACION COMPLETADA: ${copied} archivo(s) actualizados en Destino.`;
  return `${resMsg}\n${'-'.repeat(50)}\n${logOutput.length ? logOutput.join('\n') : 'Destino ya estaba al dia.'}`;
});

