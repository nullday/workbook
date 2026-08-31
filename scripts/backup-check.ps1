# backup-check.ps1
# Проверка состояния резервных копий и отправка отчёта администратору
# Использование: .\backup-check.ps1 -ReportEmail "admin@company.ru"
# Запускать через Task Scheduler каждое утро в 08:00

param(
    [string]$ReportEmail = "admin@company.ru",
    [string]$SmtpServer = "smtp.company.ru",
    [int]$SmtpPort = 587,
    [string]$SmtpUser = "backup-monitor@company.ru",
    [string]$SmtpPassword = "ПарольПочты",
    
    # Путь к папке с резервными копиями для проверки
    [string]$BackupRootPath = "\\NAS01\Backups",
    
    # Максимально допустимый возраст бэкапа в часах
    [int]$MaxAgeHours = 26,  # 26 = суточный бэкап с запасом
    
    # Минимально допустимый размер файла бэкапа (в МБ) – защита от пустых файлов
    [int]$MinSizeMB = 100
)

# ─────────────────────────────────────────────
# Конфигурация: что проверять
# ─────────────────────────────────────────────
$BackupTargets = @(
    @{
        Name        = "Active Directory (System State)"
        Path        = "$BackupRootPath\AD"
        Pattern     = "*.bkf"      # Маска файлов бэкапа
        MaxAgeHours = 26
        MinSizeMB   = 500
        Critical    = $true        # Критически важная система
    },
    @{
        Name        = "SQL Server – 1С Бухгалтерия"
        Path        = "$BackupRootPath\SQL\Accounting"
        Pattern     = "*.bak"
        MaxAgeHours = 26
        MinSizeMB   = 200
        Critical    = $true
    },
    @{
        Name        = "SQL Server – 1С Зарплата"
        Path        = "$BackupRootPath\SQL\ZUP"
        Pattern     = "*.bak"
        MaxAgeHours = 26
        MinSizeMB   = 100
        Critical    = $true
    },
    @{
        Name        = "Файловый сервер"
        Path        = "$BackupRootPath\FileServer"
        Pattern     = "*.vbk"
        MaxAgeHours = 26
        MinSizeMB   = 1000
        Critical    = $true
    },
    @{
        Name        = "Почтовый сервер"
        Path        = "$BackupRootPath\Exchange"
        Pattern     = "*.edb"
        MaxAgeHours = 72
        MinSizeMB   = 500
        Critical    = $false
    },
    @{
        Name        = "MikroTik конфигурация"
        Path        = "$BackupRootPath\Network\MikroTik"
        Pattern     = "*.backup"
        MaxAgeHours = 168  # Недельный
        MinSizeMB   = 0.01
        Critical    = $false
    }
)

# ─────────────────────────────────────────────
# Логика проверки
# ─────────────────────────────────────────────
$results = @()
$hasErrors = $false
$hasCriticalErrors = $false
$now = Get-Date

foreach ($target in $BackupTargets) {
    $result = [PSCustomObject]@{
        Name        = $target.Name
        Status      = "OK"
        StatusIcon  = "✅"
        LastBackup  = "–"
        Age         = "–"
        Size        = "–"
        Issue       = ""
        Critical    = $target.Critical
    }

    try {
        # Проверить доступность пути
        if (-not (Test-Path $target.Path)) {
            $result.Status    = "ERROR"
            $result.StatusIcon = "🔴"
            $result.Issue     = "Папка с бэкапами недоступна: $($target.Path)"
            $hasErrors        = $true
            if ($target.Critical) { $hasCriticalErrors = $true }
            $results += $result
            continue
        }

        # Найти последний файл по маске
        $latestFile = Get-ChildItem -Path $target.Path -Filter $target.Pattern -Recurse |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $latestFile) {
            $result.Status    = "ERROR"
            $result.StatusIcon = "🔴"
            $result.Issue     = "Файлы резервных копий не найдены (маска: $($target.Pattern))"
            $hasErrors        = $true
            if ($target.Critical) { $hasCriticalErrors = $true }
            $results += $result
            continue
        }

        # Возраст бэкапа
        $age        = $now - $latestFile.LastWriteTime
        $ageHours   = [math]::Round($age.TotalHours, 1)
        $sizeMB     = [math]::Round($latestFile.Length / 1MB, 1)

        $result.LastBackup = $latestFile.LastWriteTime.ToString("dd.MM.yyyy HH:mm")
        $result.Age        = "$ageHours ч."
        $result.Size       = "$sizeMB МБ"

        # Проверка возраста
        if ($ageHours -gt $target.MaxAgeHours) {
            $result.Status    = "WARNING"
            $result.StatusIcon = "🟡"
            $result.Issue    += "Бэкап устарел: $ageHours ч. (допустимо $($target.MaxAgeHours) ч.) "
            $hasErrors        = $true
            if ($target.Critical) { $hasCriticalErrors = $true }
        }

        # Проверка размера
        if ($sizeMB -lt $target.MinSizeMB) {
            $result.Status    = "ERROR"
            $result.StatusIcon = "🔴"
            $result.Issue    += "Подозрительно малый размер: $sizeMB МБ (мин. $($target.MinSizeMB) МБ) "
            $hasErrors        = $true
            if ($target.Critical) { $hasCriticalErrors = $true }
        }

    } catch {
        $result.Status    = "ERROR"
        $result.StatusIcon = "🔴"
        $result.Issue     = "Ошибка проверки: $_"
        $hasErrors        = $true
        if ($target.Critical) { $hasCriticalErrors = $true }
    }

    $results += $result
}

# ─────────────────────────────────────────────
# Формирование отчёта
# ─────────────────────────────────────────────
$overallStatus = if ($hasCriticalErrors) {
    "🔴 КРИТИЧЕСКАЯ ОШИБКА – ТРЕБУЕТСЯ НЕМЕДЛЕННОЕ ВНИМАНИЕ"
} elseif ($hasErrors) {
    "🟡 ПРЕДУПРЕЖДЕНИЕ – ЕСТЬ ПРОБЛЕМЫ С РЕЗЕРВНЫМ КОПИРОВАНИЕМ"
} else {
    "✅ ВСЕ РЕЗЕРВНЫЕ КОПИИ В ПОРЯДКЕ"
}

$reportDate = $now.ToString("dd.MM.yyyy HH:mm")
$computerName = $env:COMPUTERNAME

# Текстовый вывод в консоль
Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host " ОТЧЁТ О РЕЗЕРВНЫХ КОПИЯХ" -ForegroundColor Cyan
Write-Host " $reportDate | $computerName" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " $overallStatus" -ForegroundColor $(if ($hasCriticalErrors) {"Red"} elseif ($hasErrors) {"Yellow"} else {"Green"})
Write-Host ""

$results | ForEach-Object {
    $color = if ($_.Status -eq "OK") {"Green"} elseif ($_.Status -eq "WARNING") {"Yellow"} else {"Red"}
    Write-Host "$($_.StatusIcon) $($_.Name)" -ForegroundColor $color
    Write-Host "   Последний бэкап: $($_.LastBackup) | Возраст: $($_.Age) | Размер: $($_.Size)" -ForegroundColor Gray
    if ($_.Issue) {
        Write-Host "   ⚠ $($_.Issue)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ─────────────────────────────────────────────
# HTML-отчёт для email
# ─────────────────────────────────────────────
$tableRows = $results | ForEach-Object {
    $rowColor = switch ($_.Status) {
        "OK"      { "#0a1a0a" }
        "WARNING" { "#1a1a0a" }
        "ERROR"   { "#1a0a0a" }
    }
    $textColor = switch ($_.Status) {
        "OK"      { "#00dd88" }
        "WARNING" { "#ffcc00" }
        "ERROR"   { "#ff4444" }
    }
    "
    <tr style='background:$rowColor;'>
        <td style='padding:10px;color:$textColor;font-size:1.2em;'>$($_.StatusIcon)</td>
        <td style='padding:10px;color:#eee;font-weight:bold;'>$($_.Name)$(if ($_.Critical) {'&nbsp;<span style="color:#ff4444;font-size:0.7em;">КРИТИЧНО</span>'})</td>
        <td style='padding:10px;color:#aaa;'>$($_.LastBackup)</td>
        <td style='padding:10px;color:#aaa;'>$($_.Age)</td>
        <td style='padding:10px;color:#aaa;'>$($_.Size)</td>
        <td style='padding:10px;color:#ffcc00;'>$($_.Issue)</td>
    </tr>"
}

$subjectPrefix = if ($hasCriticalErrors) { "[КРИТИЧНО]" } elseif ($hasErrors) { "[ВНИМАНИЕ]" } else { "[OK]" }

$htmlBody = @"
<!DOCTYPE html><html><body style='background:#06090f;font-family:Courier New,monospace;color:#eee;padding:20px;'>
<div style='max-width:900px;margin:0 auto;'>
<div style='background:#0a1020;border:1px solid #102040;padding:20px;margin-bottom:20px;'>
    <div style='font-size:0.75em;color:#00c8ff;letter-spacing:3px;'>BACKUP MONITOR // NULLDAY.RU</div>
    <div style='font-size:1.5em;font-weight:bold;margin-top:8px;'>$overallStatus</div>
    <div style='color:#5a7a9a;margin-top:6px;'>$reportDate · $computerName</div>
</div>
<table style='width:100%;border-collapse:collapse;background:#0a1020;'>
<thead><tr style='background:#0d1830;'>
    <th style='padding:10px;color:#00c8ff;text-align:left;'></th>
    <th style='padding:10px;color:#00c8ff;text-align:left;'>Система</th>
    <th style='padding:10px;color:#00c8ff;text-align:left;'>Последний бэкап</th>
    <th style='padding:10px;color:#00c8ff;text-align:left;'>Возраст</th>
    <th style='padding:10px;color:#00c8ff;text-align:left;'>Размер</th>
    <th style='padding:10px;color:#00c8ff;text-align:left;'>Проблема</th>
</tr></thead>
<tbody>$($tableRows -join '')</tbody>
</table>
<div style='margin-top:20px;color:#5a7a9a;font-size:0.8em;'>
    Автоматический отчёт сформирован скриптом backup-check.ps1<br>
    Вопросы: sos@nullday.ru · nullday.ru
</div>
</div>
</body></html>
"@

# ─────────────────────────────────────────────
# Отправка email (если настроен SMTP)
# ─────────────────────────────────────────────
if ($SmtpServer -and $ReportEmail) {
    try {
        $credential = New-Object System.Management.Automation.PSCredential(
            $SmtpUser,
            (ConvertTo-SecureString $SmtpPassword -AsPlainText -Force)
        )
        
        Send-MailMessage `
            -To $ReportEmail `
            -From $SmtpUser `
            -Subject "$subjectPrefix Резервные копии – $reportDate" `
            -Body $htmlBody `
            -BodyAsHtml `
            -SmtpServer $SmtpServer `
            -Port $SmtpPort `
            -UseSsl `
            -Credential $credential

        Write-Host "📧 Отчёт отправлен на $ReportEmail" -ForegroundColor Cyan
    } catch {
        Write-Warning "Не удалось отправить email: $_"
    }
}

# ─────────────────────────────────────────────
# Возвращаем код выхода для Task Scheduler
# ─────────────────────────────────────────────
if ($hasCriticalErrors) {
    exit 2   # Критическая ошибка
} elseif ($hasErrors) {
    exit 1   # Предупреждение
} else {
    exit 0   # Всё в порядке
}
