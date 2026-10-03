function extraer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$IncludePdf,
        [switch]$TreeOnly,
        [string[]]$ExcludeExtensions = @('.png','.jpg','.jpeg','.gif','.mp4','.mov','.avi','.zip','.tar','.gz','.rar','.7z','.exe','.ico','.woff','.woff2','.ttf','.eot','.svg','.bin','.dll','.wasm','.sqlite','.db','.lock'),
        [string[]]$ExcludeFolders = @('node_modules', '.git', 'dist', 'build', '.vscode', '.idea', 'vendor', '__pycache__')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "❌ La ruta no existe: $Path" -ForegroundColor Red
        return
    }

    $item = Get-Item -LiteralPath $Path
    if ($item -isnot [System.IO.DirectoryInfo]) {
        Write-Host "❌ La ruta debe ser una carpeta: $Path" -ForegroundColor Red
        return
    }

    if ($IncludePdf -and -not (Get-Command pdftotext -ErrorAction SilentlyContinue)) {
        Write-Host "⚠️  pdftotext no está instalado. Instálalo con:" -ForegroundColor Yellow
        Write-Host "   winget install --id oschwartz10612.Poppler" -ForegroundColor Yellow
        Write-Host "   Continuando sin extraer contenido de los PDF..." -ForegroundColor Yellow
    }

    $basePath = (Resolve-Path -LiteralPath $Path).Path

    function Get-FolderParts($relParts) {
        if ($relParts.Length -le 1) { return @() }
        return ,@($relParts | Select-Object -First ($relParts.Length - 1))
    }

    $allFiles = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $relParts = $_.FullName.Substring($basePath.Length).TrimStart('\', '/') -split '[\\/]'
        $folderParts = Get-FolderParts $relParts
        $excluded = $false
        foreach ($ef in $ExcludeFolders) {
            if ($folderParts -contains $ef) { $excluded = $true; break }
        }
        -not $excluded
    } | Sort-Object FullName

    if ($allFiles.Count -eq 0) {
        Write-Host "⚠️  No se encontraron archivos válidos." -ForegroundColor Yellow
        return
    }

    function Get-RelativePath($fullPath) {
        return $fullPath.Substring($basePath.Length).TrimStart('\', '/')
    }

    function Is-Omitted($file) {
        if ($file.Name -in @('package-lock.json', 'composer.lock')) { return $true }
        if ($file.Extension -eq '.pdf' -or $file.Extension -eq '.docx') { return -not $IncludePdf }
        return $ExcludeExtensions -contains $file.Extension.ToLower()
    }

    function Test-IsBinary($filePath) {
        try {
            $stream = [System.IO.File]::OpenRead($filePath)
            try {
                $sampleSize = [Math]::Min(8000, $stream.Length)
                if ($sampleSize -eq 0) { return $false }
                $buffer = New-Object byte[] $sampleSize
                [void]$stream.Read($buffer, 0, $sampleSize)
                foreach ($b in $buffer) {
                    if ($b -eq 0) { return $true }
                }
                return $false
            } finally {
                $stream.Dispose()
            }
        } catch {
            return $true
        }
    }

    $treeSb = [System.Text.StringBuilder]::new()
    [void]$treeSb.AppendLine("ÁRBOL DE ARCHIVOS")
    $lastFolderParts = @()

    foreach ($file in $allFiles) {
        $rel = Get-RelativePath $file.FullName
        $parts = $rel -split '[\\/]'
        $folderParts = Get-FolderParts $parts

        $common = 0
        while ($common -lt $folderParts.Length -and $common -lt $lastFolderParts.Length -and $folderParts[$common] -eq $lastFolderParts[$common]) {
            $common++
        }

        for ($k = $common; $k -lt $folderParts.Length; $k++) {
            $indent = "  " * $k
            [void]$treeSb.AppendLine("$indent📁 $($folderParts[$k])/")
        }

        $lastFolderParts = $folderParts
        $indent = "  " * $folderParts.Length
        $marker = if (Is-Omitted $file) { " [omitido]" } else { "" }
        [void]$treeSb.AppendLine("$indent📄 $($file.Name)$marker")
    }
    [void]$treeSb.AppendLine()

    $contentSb = [System.Text.StringBuilder]::new()
    $readableCount = 0
    $pdfCount = 0
    $docxCount = 0
    $skippedCount = 0
    $binarySkipped = 0

    if (-not $TreeOnly) {
        $knownTextExtensions = @('.txt','.md','.js','.ts','.jsx','.tsx','.html','.htm','.css','.scss','.json','.xml','.yml','.yaml','.py','.java','.c','.cpp','.h','.cs','.php','.rb','.go','.rs','.sql','.sh','.ps1','.bat','.ini','.cfg','.env','.gitignore','.csv','.log')

        foreach ($file in $allFiles) {
            $rel = Get-RelativePath $file.FullName

            if (Is-Omitted $file) {
                $skippedCount++
                continue
            }

            if ($file.Extension -eq '.pdf') {
                if (Get-Command pdftotext -ErrorAction SilentlyContinue) {
                    $pdfCount++
                    [void]$contentSb.AppendLine("===== $rel (PDF) =====")
                    $tmpFile = [System.IO.Path]::GetTempFileName()
                    try {
                        & pdftotext -layout -enc UTF-8 $file.FullName $tmpFile 2>$null
                        [void]$contentSb.AppendLine((Get-Content -LiteralPath $tmpFile -Raw -Encoding UTF8))
                    } catch {
                        [void]$contentSb.AppendLine("[No se pudo extraer el texto del PDF]")
                    } finally {
                        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
                    }
                    [void]$contentSb.AppendLine()
                } else {
                    [void]$contentSb.AppendLine("===== $rel (PDF) =====")
                    [void]$contentSb.AppendLine("[pdftotext no está instalado - no se pudo extraer el texto]")
                    [void]$contentSb.AppendLine()
                }
                continue
            }

            if ($file.Extension -eq '.docx') {
                $docxCount++
                [void]$contentSb.AppendLine("===== $rel (DOCX) =====")
                $zip = $null
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                    $entry = $zip.GetEntry("word/document.xml")
                    if ($entry) {
                        $stream = $entry.Open()
                        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
                        $xml = $reader.ReadToEnd()
                        $reader.Dispose()
                        $stream.Dispose()
                        $text = ($xml -replace '</w:p>', "`r`n") -replace '<[^>]+>', ''
                        $text = [System.Net.WebUtility]::HtmlDecode($text).Trim()
                        [void]$contentSb.AppendLine($text)
                    } else {
                        [void]$contentSb.AppendLine("[No se encontró contenido de texto en el documento]")
                    }
                } catch {
                    [void]$contentSb.AppendLine("[No se pudo leer el archivo .docx]")
                } finally {
                    if ($zip) { $zip.Dispose() }
                }
                [void]$contentSb.AppendLine()
                continue
            }

            $ext = $file.Extension.ToLower()
            if ($knownTextExtensions -notcontains $ext) {
                if (Test-IsBinary $file.FullName) {
                    $binarySkipped++
                    continue
                }
            }

            $readableCount++
            [void]$contentSb.AppendLine("===== $rel =====")
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            [void]$contentSb.AppendLine($content)
            [void]$contentSb.AppendLine()
        }
    }

    $finalOutput = if ($TreeOnly) { $treeSb.ToString() } else { $treeSb.ToString() + $contentSb.ToString() }
    $charCount = $finalOutput.Length
    $estimatedTokens = [math]::Round($charCount / 4)

    $charLimit = 100000
    $usedFile = $false

    if ($charCount -gt $charLimit) {
        $outFile = Join-Path $basePath "_extraccion.txt"
        $finalOutput | Out-File -LiteralPath $outFile -Encoding UTF8 -Force
        $usedFile = $true
        Set-Clipboard -Value $outFile
    } else {
        Set-Clipboard -Value $finalOutput
    }

    Write-Host "✅ Listo" -ForegroundColor Green
    if ($usedFile) {
        Write-Host "   📄 Supera el límite de $charLimit caracteres → guardado como archivo:" -ForegroundColor Yellow
        Write-Host "   $outFile" -ForegroundColor Cyan
        Write-Host "   (la ruta del archivo se copió al portapapeles)"
    } else {
        Write-Host "   Copiado al portapapeles (texto directo)"
    }
    if ($TreeOnly) {
        Write-Host "   (Modo Solo Árbol - sin contenido de archivos)"
        Write-Host "   Total archivos en árbol: $($allFiles.Count)"
    } else {
        Write-Host "   Total archivos: $($allFiles.Count) | Legibles: $readableCount | PDFs: $pdfCount | Word: $docxCount"
        Write-Host "   Omitidos (extensión): $skippedCount | Omitidos (binario): $binarySkipped"
    }
    Write-Host "   Caracteres: $charCount | Tokens aprox: ~$estimatedTokens"
}

function yt-video {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Url,
        [string]$path = "$env:USERPROFILE\Pictures\yt-dlp\input"
    )

    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    if ($Url.Count -eq 1) {
        $singleUrl = $Url[0]
        Write-Host "Descargando vídeo: $singleUrl" -ForegroundColor Cyan
        $output = yt-dlp -o "$path\%(title)s.%(ext)s" --no-playlist $singleUrl 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Vídeo descargado con éxito en: $path" -ForegroundColor Green
        } else {
            Write-Host "❌ Error al descargar el vídeo." -ForegroundColor Red
            if ($output) {
                $output | Select-Object -Last 5 | ForEach-Object { Write-Host "   $_" }
            }
        }
    } else {
        $total = $Url.Count
        Write-Host "Iniciando descarga de $total vídeos en segundo plano..." -ForegroundColor Cyan
        $count = 0
        foreach ($u in $Url) {
            $outPattern = "$path\%(title)s.%(ext)s"
            Start-Process -FilePath "yt-dlp" -ArgumentList @("-o", "`"$outPattern`"", "`"$u`"") -WindowStyle Hidden
            Write-Host "▶ Descarga lanzada: $u" -ForegroundColor Cyan
            $count++
        }
        Write-Host "✅ Se han lanzado $count descargas en segundo plano hacia $path" -ForegroundColor Green
    }
}

function compress-video {
    param(
        [string]$inputPath = "$env:USERPROFILE\Pictures\yt-dlp\input",
        [string]$outputPath = "$env:USERPROFILE\Pictures\yt-dlp\outputs",
        [ValidateSet("low", "medium", "high")]
        [string]$quality = "medium"
    )

    if (-not (Test-Path -LiteralPath $inputPath)) {
        Write-Host "⚠️ La carpeta de entrada no existe: $inputPath" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $outputPath)) {
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    }

    $crf = @{ low = 28; medium = 23; high = 18 }[$quality]

    $videos = Get-ChildItem -LiteralPath $inputPath -File -ErrorAction SilentlyContinue | Where-Object {
        '.mp4','.avi','.mkv','.mov','.wmv' -contains $_.Extension.ToLower()
    }

    if (-not $videos -or $videos.Count -eq 0) {
        Write-Host "⚠️ No se encontraron vídeos en: $inputPath" -ForegroundColor Yellow
        return
    }

    $compressedCount = 0
    foreach ($video in $videos) {
        $outFile = Join-Path $outputPath "$($video.BaseName)_compressed.mp4"
        Write-Host "Comprimiendo: $($video.Name)..." -ForegroundColor Cyan

        ffmpeg -i $video.FullName -c:v libx264 -crf $crf -preset medium -c:a aac -b:a 128k $outFile -y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $originalSize = [math]::Round($video.Length / 1MB, 2)
            $newSize = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 2)
            $saved = if ($originalSize -gt 0) { [math]::Round((1 - $newSize / $originalSize) * 100, 1) } else { 0 }
            Write-Host "✅ $($video.Name): $originalSize MB → $newSize MB ($saved% reducido)" -ForegroundColor Green
            $compressedCount++
        } else {
            Write-Host "❌ Error al comprimir $($video.Name)" -ForegroundColor Red
        }
    }

    Write-Host "Completado: $compressedCount vídeo(s) comprimido(s)."
}

function parar-todo {
    $procs = Get-Process yt-dlp -ErrorAction SilentlyContinue
    if ($procs) {
        $count = $procs.Count
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "⏹ Detenidos $count proceso(s) de yt-dlp." -ForegroundColor Green
    } else {
        Write-Host "ℹ️ No hay descargas activas de yt-dlp." -ForegroundColor Yellow
    }
}

function recuperar-todo {
    $searchDirs = @(
        "$env:USERPROFILE\Videos",
        "$env:USERPROFILE\Pictures\yt-dlp\input"
    )

    $partFiles = @()
    foreach ($dir in $searchDirs) {
        if (Test-Path -LiteralPath $dir) {
            $partFiles += Get-ChildItem -LiteralPath $dir -Filter "*.part" -File -ErrorAction SilentlyContinue
        }
    }

    if (-not $partFiles -or $partFiles.Count -eq 0) {
        Write-Host "ℹ️ No se encontraron archivos .part en Videos o Pictures\yt-dlp\input." -ForegroundColor Yellow
        return
    }

    $recovered = 0
    foreach ($file in $partFiles) {
        $salida = $file.FullName -replace '\.part$', '_ok.mp4'
        Write-Host "Reparando: $($file.Name)..." -ForegroundColor Cyan
        ffmpeg -i $file.FullName -c copy $salida -y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Reparado: $salida" -ForegroundColor Green
            $recovered++
        } else {
            Write-Host "❌ Error al reparar: $($file.Name)" -ForegroundColor Red
        }
    }

    Write-Host "Finalizado: $recovered de $($partFiles.Count) archivo(s) recuperado(s)."
}

function transcribir-whisper {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [ValidateSet("tiny", "base", "small")]
        [string]$Model = "base",
        [ValidateSet("cuda", "cpu")]
        [string]$Device = "cpu",
        [switch]$NotesMode,
        [double]$SceneThreshold = 0.4,
        [int]$SceneInterval = 30,
        [switch]$NotifyToast,
        [string]$OutputDir = "$env:USERPROFILE\Pictures\yt-dlp\outputs"
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Host "❌ La ruta no existe: $FilePath" -ForegroundColor Red
        return
    }

    $mediaExtensions = @('.mp3','.wav','.m4a','.mp4','.mkv','.flac','.aac','.ogg','.avi','.mov','.wmv')
    $item = Get-Item -LiteralPath $FilePath
    $isFolder = $item -is [System.IO.DirectoryInfo]

    if ($isFolder) {
        $filesToProcess = Get-ChildItem -LiteralPath $FilePath -File -ErrorAction SilentlyContinue | Where-Object {
            $mediaExtensions -contains $_.Extension.ToLower()
        }
        if (-not $filesToProcess -or $filesToProcess.Count -eq 0) {
            Write-Host "⚠️ No se encontraron archivos multimedia (.mp4, .mkv, .mp3, etc.) en la carpeta:" -ForegroundColor Yellow
            Write-Host "   $FilePath" -ForegroundColor Cyan
            return
        }
    } else {
        $filesToProcess = @($item)
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $safeFilePath = $FilePath.Replace("'", "''")
    $safeOutputDir = $OutputDir.Replace("'", "''")
    $toastFlag = if ($NotifyToast) { '$true' } else { '$false' }
    $notesFlag = if ($NotesMode) { '$true' } else { '$false' }
    $threshStr = $SceneThreshold.ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $scriptContent = @"
`$Host.UI.RawUI.WindowTitle = 'CliKit - Transcribiendo con Whisper ($Model - $Device)'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8')
`$env:PYTHONIOENCODING = 'utf-8'
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  CliKit - Transcripción con Whisper' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host "Origen:       $safeFilePath"
Write-Host "Modelo:       $Model"
Write-Host "Aceleración:  $Device"
if ($notesFlag) {
    Write-Host "Modo Apuntes: ACTIVO (Sensibilidad: $threshStr, Intervalo: ${SceneInterval}s)" -ForegroundColor Magenta
}
Write-Host "Destino:      $safeOutputDir"
Write-Host '-----------------------------------------------------'

`$targetPath = '$safeFilePath'
`$outputDir = '$safeOutputDir'
`$model = '$Model'
`$device = '$Device'
`$notifyToast = $toastFlag
`$notesMode = $notesFlag
`$sceneThreshold = '$threshStr'
`$sceneInterval = $SceneInterval
`$mediaExts = @('.mp3','.wav','.m4a','.mp4','.mkv','.flac','.aac','.ogg','.avi','.mov','.wmv')
`$videoExts = @('.mp4','.mkv','.avi','.mov','.wmv')

`$targetItem = Get-Item -LiteralPath `$targetPath
`$isDir = `$targetItem -is [System.IO.DirectoryInfo]

`$files = if (`$isDir) {
    Get-ChildItem -LiteralPath `$targetPath -File -ErrorAction SilentlyContinue | Where-Object {
        `$mediaExts -contains `$_.Extension.ToLower()
    }
} else {
    @(`$targetItem)
}

Write-Host "Total archivos a transcribir: `$(`$files.Count)" -ForegroundColor Cyan
Write-Host '-----------------------------------------------------'

`$completedCount = 0
`$lastTranscribedText = ""
`$allOutputs = [System.Collections.Generic.List[string]]::new()
`$notesDirs = [System.Collections.Generic.List[string]]::new()

`$whisperCmd = if (Get-Command whisper -ErrorAction SilentlyContinue) {
    "whisper"
} elseif (Get-Command whisper.exe -ErrorAction SilentlyContinue) {
    "whisper.exe"
} else {
    "python"
}

`$total = `$files.Count
`$idx = 0

foreach (`$file in `$files) {
    `$idx++
    Write-Host ""
    Write-Host "[$idx/`$total] Procesando: `$(`$file.Name)..." -ForegroundColor Yellow
    `$tempWav = Join-Path ([System.IO.Path]::GetTempPath()) ("clikit_whisper_" + [System.Guid]::NewGuid().ToString() + ".wav")
    `$tempOutDir = Join-Path ([System.IO.Path]::GetTempPath()) ("whisper_out_" + [System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path `$tempOutDir -Force | Out-Null

    `$isVideo = `$videoExts -contains `$file.Extension.ToLower()
    `$targetDest = `$outputDir

    if (`$notesMode -and `$isVideo) {
        `$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        `$notesDirName = "Apuntes_" + `$file.BaseName + "_" + `$timestamp
        `$currentNotesDir = Join-Path `$outputDir `$notesDirName
        New-Item -ItemType Directory -Path `$currentNotesDir -Force | Out-Null
        `$targetDest = `$currentNotesDir
        `$notesDirs.Add(`$currentNotesDir)
        Write-Host "   📁 Carpeta de apuntes creada: `$currentNotesDir" -ForegroundColor Magenta

        Write-Host "   📸 Extrayendo diapositivas y código de pantalla con FFmpeg..." -ForegroundColor Cyan
        `$slidePattern = Join-Path `$currentNotesDir "slide_%03d.jpg"
        ffmpeg -i `$file.FullName -vf "select='isnan(prev_selected_t)+gt(scene,`$sceneThreshold)*gte(t-prev_selected_t,`$sceneInterval)'" -vsync vfr `$slidePattern -y 2>&1 | Out-Null
        `$slideItems = Get-ChildItem -LiteralPath `$currentNotesDir -Filter "slide_*.jpg" -File -ErrorAction SilentlyContinue
        `$slideCount = if (`$slideItems) { `$slideItems.Count } else { 0 }
        Write-Host "   ✅ Diapositivas capturadas: `$slideCount fotograma(s)" -ForegroundColor Green
    }

    try {
        Write-Host "   ▶ Extrayendo y optimizando audio con FFmpeg (16kHz mono)..." -ForegroundColor Gray
        ffmpeg -i `$file.FullName -vn -ar 16000 -ac 1 -c:a pcm_s16le `$tempWav -y 2>&1 | Out-Null
        if (`$LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath `$tempWav)) {
            Write-Host "   ❌ Error al procesar audio con FFmpeg de `$(`$file.Name)" -ForegroundColor Red
            continue
        }

        Write-Host "   ▶ Transcribiendo con OpenAI Whisper (`$model, device: `$device)..." -ForegroundColor Cyan
        if (`$whisperCmd -eq "python") {
            python -m whisper `$tempWav --model `$model --device `$device --output_dir `$tempOutDir --output_format all
        } else {
            & `$whisperCmd `$tempWav --model `$model --device `$device --output_dir `$tempOutDir --output_format all
        }

        `$generatedTxt = Get-ChildItem -LiteralPath `$tempOutDir -Filter "*.txt" | Select-Object -First 1
        `$generatedSrt = Get-ChildItem -LiteralPath `$tempOutDir -Filter "*.srt" | Select-Object -First 1
        `$generatedVtt = Get-ChildItem -LiteralPath `$tempOutDir -Filter "*.vtt" | Select-Object -First 1

        if (`$generatedTxt -and (Test-Path -LiteralPath `$generatedTxt.FullName)) {
            `$finalTxtPath = Join-Path `$targetDest "`$(`$file.BaseName)_transcripcion.txt"
            Copy-Item -LiteralPath `$generatedTxt.FullName -Destination `$finalTxtPath -Force
            `$lastTranscribedText = Get-Content -LiteralPath `$finalTxtPath -Raw -Encoding UTF8
            `$allOutputs.Add(`$finalTxtPath)

            if (`$generatedSrt -and (Test-Path -LiteralPath `$generatedSrt.FullName)) {
                `$finalSrtPath = Join-Path `$targetDest "`$(`$file.BaseName)_timestamps.srt"
                Copy-Item -LiteralPath `$generatedSrt.FullName -Destination `$finalSrtPath -Force
            }
            if (`$generatedVtt -and (Test-Path -LiteralPath `$generatedVtt.FullName)) {
                `$finalVttPath = Join-Path `$targetDest "`$(`$file.BaseName)_timestamps.vtt"
                Copy-Item -LiteralPath `$generatedVtt.FullName -Destination `$finalVttPath -Force
            }

            if (`$notesMode -and `$generatedSrt -and (Test-Path -LiteralPath `$generatedSrt.FullName)) {
                try {
                    `$srtContent = Get-Content -LiteralPath `$generatedSrt.FullName -Raw -Encoding UTF8
                    `$structuredSb = [System.Text.StringBuilder]::new()
                    [void]`$structuredSb.AppendLine("=====================================================")
                    [void]`$structuredSb.AppendLine("  CliKit - Apuntes de Clase con Marcas de Tiempo")
                    [void]`$structuredSb.AppendLine("  Archivo: `$(`$file.Name)")
                    [void]`$structuredSb.AppendLine("  Fecha:   `$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
                    [void]`$structuredSb.AppendLine("=====================================================")
                    [void]`$structuredSb.AppendLine()

                    `$blocks = `$srtContent -split "(?:\r?\n){2,}"
                    foreach (`$b in `$blocks) {
                        `$lines = (`$b -split "\r?\n") | Where-Object { `$_.Trim().Length -gt 0 }
                        if (`$lines.Count -ge 2) {
                            `$timeLine = `$lines | Where-Object { `$_ -match '\d{2}:\d{2}:\d{2}' } | Select-Object -First 1
                            if (`$timeLine -and `$timeLine -match '(\d{2}:\d{2}:\d{2})') {
                                `$stamp = `$matches[1]
                                `$textLines = `$lines | Where-Object { `$_ -ne `$timeLine -and `$_ -notmatch '^\d+$' }
                                if (`$textLines) {
                                    [void]`$structuredSb.AppendLine("[`$stamp] " + (`$textLines -join ' '))
                                }
                            }
                        }
                    }
                    `$notesTxtFile = Join-Path `$targetDest "`$(`$file.BaseName)_apuntes_timestamps.txt"
                    [System.IO.File]::WriteAllText(`$notesTxtFile, `$structuredSb.ToString(), [System.Text.Encoding]::UTF8)
                    Write-Host "   📝 Documento con marcas de tiempo [HH:MM:SS] guardado." -ForegroundColor Green
                } catch {}
            }

            `$completedCount++
            Write-Host "   ✅ Transcripción guardada en: `$targetDest" -ForegroundColor Green
        } else {
            Write-Host "   ❌ Error: No se pudo generar la transcripción de `$(`$file.Name)" -ForegroundColor Red
        }
    } finally {
        Remove-Item -LiteralPath `$tempWav -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath `$tempOutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "🎉 Transcripción completada: `$completedCount de `$total archivo(s) procesado(s)." -ForegroundColor Green
Write-Host "📂 Guardados en: `$outputDir" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Green

if (`$completedCount -gt 0) {
    if (`$total -eq 1) {
        Set-Clipboard -Value `$lastTranscribedText
        Write-Host "📋 El texto transcrito se ha copiado al portapapeles." -ForegroundColor Cyan
    } else {
        Set-Clipboard -Value (`$allOutputs -join "`r`n")
        Write-Host "📋 La lista de archivos transcritos se ha copiado al portapapeles." -ForegroundColor Cyan
    }

    if (`$notifyToast) {
        try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            `$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            `$textNodes = `$template.GetElementsByTagName("text")
            `$textNodes.Item(0).AppendChild(`$template.CreateTextNode("CliKit - Transcripción finalizada")) | Out-Null
            `$msg = if (`$notesMode) { "Apuntes y transcripción generados con éxito." } elseif (`$total -eq 1) { "Se ha guardado la transcripción y copiado al portapapeles." } else { "Se han transcrito `$completedCount archivo(s) con éxito." }
            `$textNodes.Item(1).AppendChild(`$template.CreateTextNode(`$msg)) | Out-Null
            `$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("CliKit")
            `$notification = [Windows.UI.Notifications.ToastNotification]::new(`$template)
            `$notifier.Show(`$notification)
        } catch {
            try {
                `$wscript = New-Object -ComObject WScript.Shell
                `$wscript.Popup("Transcripción completada: `$completedCount archivo(s) procesados.", 5, "CliKit - Whisper", 64) | Out-Null
            } catch {}
        }
    }

    if (`$notesMode -and `$notesDirs.Count -gt 0) {
        foreach (`$nd in `$notesDirs) {
            if (Test-Path -LiteralPath `$nd) {
                Write-Host "📂 Abriendo carpeta de apuntes en el Explorador de Windows..." -ForegroundColor Cyan
                Start-Process explorer.exe -ArgumentList "`"`$nd`""
            }
        }
    }
}

Write-Host ""
Write-Host "Presiona cualquier tecla para cerrar esta ventana..." -ForegroundColor Gray
[void][System.Console]::ReadKey()
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("clikit_run_whisper_" + [System.Guid]::NewGuid().ToString() + ".ps1")
    [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)

    Start-Process pwsh.exe -ArgumentList @("-NoExit", "-File", "`"$tempScript`"")

    $notesNotice = if ($NotesMode) { " (Modo Apuntes: umbral $SceneThreshold, intervalo ${SceneInterval}s)" } else { "" }
    if ($isFolder) {
        Write-Host "🚀 Transcripción por lotes iniciada para $($filesToProcess.Count) archivo(s) en PowerShell$notesNotice." -ForegroundColor Green
        Write-Host "   Carpeta:     $FilePath" -ForegroundColor Cyan
        Write-Host "   Modelo:      $Model" -ForegroundColor Cyan
        Write-Host "   Dispositivo: $Device" -ForegroundColor Cyan
        Write-Host "   Destino:     $OutputDir" -ForegroundColor Cyan
    } else {
        Write-Host "🚀 Transcripción iniciada en una ventana independiente de PowerShell$notesNotice." -ForegroundColor Green
        Write-Host "   Archivo:     $FilePath" -ForegroundColor Cyan
        Write-Host "   Modelo:      $Model" -ForegroundColor Cyan
        Write-Host "   Dispositivo: $Device" -ForegroundColor Cyan
        Write-Host "   Destino:     $OutputDir" -ForegroundColor Cyan
    }
    Write-Host "   (Puedes seguir usando CliKit sin bloqueos mientras Whisper procesa en segundo plano)"
}