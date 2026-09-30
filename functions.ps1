function extraer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$IncludePdf,
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

    $finalOutput = $treeSb.ToString() + $contentSb.ToString()
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
    Write-Host "   Total archivos: $($allFiles.Count) | Legibles: $readableCount | PDFs: $pdfCount | Word: $docxCount"
    Write-Host "   Omitidos (extensión): $skippedCount | Omitidos (binario): $binarySkipped"
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