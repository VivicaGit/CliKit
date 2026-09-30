# ================================

function extraer {
    <#
    .SYNOPSIS
    Copia al portapapeles el árbol y contenido de una carpeta (para pasar a una IA).
    .EXAMPLE
    extraer "C:\ruta\proyecto" -IncludePdf
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$IncludePdf,
        [string[]]$ExcludeExtensions = @('.png','.jpg','.jpeg','.gif','.mp4','.mov','.avi','.zip','.tar','.gz','.rar','.7z','.exe','.ico','.woff','.woff2','.ttf','.eot','.svg','.bin','.dll','.wasm','.sqlite','.db','.lock'),
        [string[]]$ExcludeFolders = @('node_modules', '.git', 'dist', 'build', '.vscode', '.idea', 'vendor', '__pycache__')
    )

    if (-not (Test-Path $Path)) {
        Write-Host "❌ La ruta no existe: $Path" -ForegroundColor Red
        return
    }

    if ($IncludePdf -and -not (Get-Command pdftotext -ErrorAction SilentlyContinue)) {
        Write-Host "⚠️  pdftotext no está instalado. Instálalo con:" -ForegroundColor Yellow
        Write-Host "   winget install --id oschwartz10612.Poppler" -ForegroundColor Yellow
        Write-Host "   Continuando sin extraer contenido de los PDF..." -ForegroundColor Yellow
    }

    $basePath = (Resolve-Path $Path).Path

    function Get-FolderParts($relParts) {
        if ($relParts.Length -le 1) { return @() }
        return ,@($relParts | Select-Object -First ($relParts.Length - 1))
    }

    $allFiles = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
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

        # Extracción de PDF
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
                    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                }
                [void]$contentSb.AppendLine()
            }
            continue
        }

        # Extracción de Word (.docx)
        if ($file.Extension -eq '.docx') {
            $docxCount++
            [void]$contentSb.AppendLine("===== $rel (DOCX) =====")
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                $entry = $zip.GetEntry("word/document.xml")
                if ($entry) {
                    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
                    $xml = $reader.ReadToEnd()
                    $reader.Close()
                    $text = ($xml -replace '</w:p>', "`r`n") -replace '<[^>]+>', ''
                    $text = [System.Net.WebUtility]::HtmlDecode($text).Trim()
                    [void]$contentSb.AppendLine($text)
                } else {
                    [void]$contentSb.AppendLine("[No se encontró contenido de texto en el documento]")
                }
                $zip.Dispose()
            } catch {
                [void]$contentSb.AppendLine("[No se pudo leer el archivo .docx]")
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
        $finalOutput | Out-File -FilePath $outFile -Encoding UTF8 -Force
        $usedFile = $true
        $outFile | Set-Clipboard
    } else {
        $finalOutput | Set-Clipboard
    }

    Write-Host "✅ Listo" -ForegroundColor Green
    if ($usedFile) {
        Write-Host "   📄 Supera el límite de $charLimit caracteres → guardado como archivo:" -ForegroundColor Yellow
        Write-Host "   $outFile" -ForegroundColor Cyan
        Write-Host "   (la ruta del archivo se copió al portapapeles, no el contenido)"
    } else {
        Write-Host "   Copiado al portapapeles (texto directo)"
    }
    Write-Host "   Total archivos: $($allFiles.Count) | Legibles: $readableCount | PDFs: $pdfCount | Word: $docxCount"
    Write-Host "   Omitidos (extension): $skippedCount | Omitidos (binario detectado): $binarySkipped"
    Write-Host "   Caracteres: $charCount | Tokens aprox: ~$estimatedTokens"
}

# ================================

function yt-video {
    <#
    .SYNOPSIS
    Descarga un vídeo con yt-dlp y notifica con un toast al terminar.
    .EXAMPLE
    yt-video "https://..."
    #>
    param(
        [string]$url,
        [string]$path = "C:\Users\$env:USERNAME\Pictures\yt-dlp\input"
    )

    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force > $null }

    $result = yt-dlp -o "$path\%(title)s.%(ext)s" $url
    $success = $LASTEXITCODE -eq 0

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode("YT-DLP")) > $null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($(if($success){"✅ Completado"}else{"❌ Error"}))) > $null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("YT-DLP").Show($toast)
    } catch { }
}

# ================================

function compress-video {
    <#
    .SYNOPSIS
    Comprime todos los vídeos de una carpeta con ffmpeg (calidad low/medium/high).
    .EXAMPLE
    compress-video -quality low
    #>
    param(
        [string]$inputPath = "C:\Users\$env:USERNAME\Pictures\yt-dlp\input",
        [string]$outputPath = "C:\Users\$env:USERNAME\Pictures\yt-dlp\outputs",
        [ValidateSet("low", "medium", "high")]
        [string]$quality = "medium"
    )

    $crf = @{ low = 28; medium = 23; high = 18 }[$quality]

    if (!(Test-Path $outputPath)) { New-Item -ItemType Directory -Path $outputPath -Force > $null }

    $videos = Get-ChildItem $inputPath -File | Where-Object { '.mp4','.avi','.mkv','.mov','.wmv' -contains $_.Extension.ToLower() }

    if ($videos.Count -eq 0) {
        Write-Host "⚠️ No se encontraron videos en: $inputPath" -ForegroundColor Yellow
        return
    }

    $videos | ForEach-Object {
        $outFile = Join-Path $outputPath "$($_.BaseName)_compressed.mp4"
        Write-Host "Comprimiendo: $($_.Name)..." -ForegroundColor Cyan

        ffmpeg -i $_.FullName -c:v libx264 -crf $crf -preset medium -c:a aac -b:a 128k $outFile -y 2>&1 | Out-Null
        $success = $LASTEXITCODE -eq 0

        if ($success) {
            $originalSize = [math]::Round($_.Length / 1MB, 2)
            $newSize = [math]::Round((Get-Item $outFile).Length / 1MB, 2)
            $saved = [math]::Round((1 - $newSize/$originalSize) * 100, 1)
            Write-Host "✅ $($_.Name): $originalSize MB → $newSize MB ($saved% reducido)" -ForegroundColor Green
        }
    }

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode("Compress-Video")) > $null
        $textNodes.Item(1).AppendChild($template.CreateTextNode("✅ Compresión completada")) > $null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Compress-Video").Show($toast)
    } catch { }
}

# ================================

function grabar-todo {
    <#
    .SYNOPSIS
    Lee el portapapeles y lanza en segundo plano una descarga (yt-video) por cada URL encontrada de un dominio concreto.
    #>
    $d = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(">[REMOVED]"))
    Get-Clipboard | Where-Object { $_ -match $d } | ForEach-Object {
        $nombre = ($_ -split '/')[-2]
        Start-Job -Name $nombre -ScriptBlock {
            . $using:PROFILE
            yt-video $using:_
        }
    }
}

# ================================

function parar-todo {
    <#
    .SYNOPSIS
    Mata todos los procesos yt-dlp en marcha.
    #>
    Get-Process yt-dlp -ErrorAction SilentlyContinue | ForEach-Object { taskkill /PID $_.Id }
}

# ================================

function recuperar-todo {
    <#
    .SYNOPSIS
    Repara archivos .part (descargas incompletas) con ffmpeg.
    #>
    Get-ChildItem "C:\Users\$env:USERNAME\Pictures\yt-dlp\input" -Filter "*.part" | ForEach-Object {
        $salida = $_.FullName -replace '\.part$', '_ok.mp4'
        ffmpeg -i $_.FullName -c copy $salida -y
    }
}

# ================================

function recuerdame {
    <#
    .SYNOPSIS
    Lista todas las funciones del perfil con su descripción.
    #>
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PROFILE, [ref]$null, [ref]$null)
    $allFunctions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    $topLevel = $allFunctions | Where-Object {
        $parent = $_.Parent
        while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parent = $parent.Parent
        }
        $null -eq $parent
    }

    Write-Host "`n📋 FUNCIONES DISPONIBLES`n" -ForegroundColor Cyan

    foreach ($fn in $topLevel) {
        if ($fn.Name -eq 'recuerdame') { continue }
        $help = Get-Help $fn.Name -ErrorAction SilentlyContinue
        $synopsis = if ($help -and $help.Synopsis -and $help.Synopsis -ne $fn.Name) {
            $help.Synopsis.Trim()
        } else {
            "(sin descripción todavía)"
        }
        Write-Host $fn.Name -ForegroundColor Green
        Write-Host "  $synopsis`n"
    }
}

# ================================

function clikit {
    <#
    .SYNOPSIS
    Abre la herramienta visual CliKit en segundo plano.
    .EXAMPLE
    clikit
    #>
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c npm start" -WorkingDirectory "[APP_PATH]" -WindowStyle Hidden
}