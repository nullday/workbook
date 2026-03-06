# network-isolation.ps1
# Экстренная изоляция заражённого компьютера от сети
# Запускать локально или удалённо через PSRemoting
# ВНИМАНИЕ: После выполнения машина будет недоступна по сети

param(
    [switch]$Remote,                # Режим: удалённое выполнение
    [string]$TargetComputer = "",   # Имя компьютера (для удалённого режима)
    [switch]$Force,                 # Без подтверждения
    [switch]$LogOnly                # Только логирование, без изоляции
)

$LogPath = "C:\Windows\Temp\isolation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) {
        "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Gray"}
    })
    Add-Content -Path $LogPath -Value $line
}

function Get-NetworkInfo {
    Write-Log "=== СЕТЕВАЯ ИНФОРМАЦИЯ ПЕРЕД ИЗОЛЯЦИЕЙ ===" "INFO"
    
    # Активные сетевые адаптеры
    $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
    foreach ($adapter in $adapters) {
        $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Write-Log "Адаптер: $($adapter.Name) | IP: $($ip.IPAddress) | MAC: $($adapter.MacAddress)" "INFO"
    }
    
    # Активные соединения (подозрительные)
    Write-Log "=== АКТИВНЫЕ СЕТЕВЫЕ СОЕДИНЕНИЯ ===" "INFO"
    $connections = Get-NetTCPConnection -State Established |
        Where-Object {$_.RemoteAddress -ne "0.0.0.0" -and $_.RemoteAddress -ne "::"} |
        Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort,
                      @{N="Process"; E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}}
    
    foreach ($conn in $connections) {
        Write-Log "  $($conn.LocalAddress):$($conn.LocalPort) → $($conn.RemoteAddress):$($conn.RemotePort) [$($conn.Process)]" "INFO"
    }
    
    # Подозрительные процессы (запущенные из нестандартных мест)
    Write-Log "=== ПОДОЗРИТЕЛЬНЫЕ ПРОЦЕССЫ ===" "INFO"
    $suspiciousPaths = @("*\AppData\*", "*\Temp\*", "*\Downloads\*", "*\Public\*")
    Get-Process | Where-Object {$_.Path} | ForEach-Object {
        foreach ($pattern in $suspiciousPaths) {
            if ($_.Path -like $pattern) {
                Write-Log "  ПОДОЗРИТЕЛЬНЫЙ: $($_.Name) | PID: $($_.Id) | Путь: $($_.Path)" "WARN"
            }
        }
    }
}

function Invoke-Isolation {
    Write-Log "=== НАЧАЛО ИЗОЛЯЦИИ ===" "WARN"
    
    if ($LogOnly) {
        Write-Log "Режим LogOnly — изоляция не выполняется" "WARN"
        return
    }
    
    # 1. Отключить все сетевые адаптеры
    $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
    foreach ($adapter in $adapters) {
        try {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false
            Write-Log "Адаптер отключён: $($adapter.Name)" "SUCCESS"
        } catch {
            Write-Log "Ошибка отключения адаптера $($adapter.Name): $_" "ERROR"
        }
    }
    
    # 2. Заблокировать весь трафик через Windows Firewall
    # Сначала включаем файрвол
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
    
    # Удаляем все разрешающие правила входящего трафика
    Get-NetFirewallRule -Direction Inbound -Action Allow |
        Where-Object {$_.Profile -ne "Any"} |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    
    # Создаём правило "блокировать всё"
    New-NetFirewallRule -DisplayName "ISOLATION_BLOCK_ALL_IN" `
        -Direction Inbound -Action Block -Enabled True -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    
    New-NetFirewallRule -DisplayName "ISOLATION_BLOCK_ALL_OUT" `
        -Direction Outbound -Action Block -Enabled True -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    
    Write-Log "Правила блокировки файрвола установлены" "SUCCESS"
    
    # 3. Остановить SMB-сервис (не давать распространяться по сети)
    try {
        Stop-Service -Name LanmanServer -Force
        Set-Service -Name LanmanServer -StartupType Disabled
        Write-Log "Служба SMB (LanmanServer) остановлена" "SUCCESS"
    } catch {
        Write-Log "Не удалось остановить SMB: $_" "ERROR"
    }
    
    # 4. Остановить службу рабочей станции (исходящие SMB)
    try {
        Stop-Service -Name LanmanWorkstation -Force -ErrorAction SilentlyContinue
        Write-Log "Служба LanmanWorkstation остановлена" "SUCCESS"
    } catch {
        Write-Log "Не удалось остановить LanmanWorkstation" "WARN"
    }
    
    Write-Log "=== ИЗОЛЯЦИЯ ЗАВЕРШЕНА ===" "SUCCESS"
    Write-Log "Компьютер $env:COMPUTERNAME изолирован от сети" "SUCCESS"
    Write-Log "Лог сохранён: $LogPath" "INFO"
}

function Invoke-RemoteIsolation {
    param([string]$Computer)
    
    Write-Host "Выполнение удалённой изоляции: $Computer" -ForegroundColor Yellow
    
    # Копируем скрипт на удалённую машину и выполняем
    $scriptContent = Get-Content $PSCommandPath -Raw
    
    Invoke-Command -ComputerName $Computer -ScriptBlock {
        param($script)
        $tempScript = "C:\Windows\Temp\isolate_temp.ps1"
        $script | Set-Content $tempScript
        & powershell.exe -ExecutionPolicy Bypass -File $tempScript -Force
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    } -ArgumentList $scriptContent -ErrorAction Stop
}

# ─────────────────────────────────────────────
# Основная логика
# ─────────────────────────────────────────────

# Проверка прав администратора
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]"Administrator"
)
if (-not $isAdmin) {
    Write-Host "ОШИБКА: Скрипт требует прав администратора" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║   ИЗОЛЯЦИЯ ЗАРАЖЁННОГО КОМПЬЮТЕРА    ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

if ($Remote -and $TargetComputer) {
    Write-Host "Целевой компьютер: $TargetComputer" -ForegroundColor Yellow
} else {
    Write-Host "Целевой компьютер: $env:COMPUTERNAME (локально)" -ForegroundColor Yellow
}

if ($LogOnly) {
    Write-Host "Режим: ТОЛЬКО СБОР ИНФОРМАЦИИ (без изоляции)" -ForegroundColor Cyan
} else {
    Write-Host "Режим: ПОЛНАЯ ИЗОЛЯЦИЯ" -ForegroundColor Red
    Write-Host ""
    Write-Host "⚠️  ВНИМАНИЕ: После выполнения компьютер будет отключён от сети!" -ForegroundColor Red
    Write-Host "    Убедитесь, что у вас есть физический доступ к машине." -ForegroundColor Red
}

Write-Host ""

if (-not $Force -and -not $LogOnly) {
    $confirm = Read-Host "Продолжить? (введите ДА для подтверждения)"
    if ($confirm -ne "ДА") {
        Write-Host "Отменено" -ForegroundColor Yellow
        exit 0
    }
}

# Сбор информации
Get-NetworkInfo

# Изоляция
if ($Remote -and $TargetComputer) {
    Invoke-RemoteIsolation -Computer $TargetComputer
} else {
    Invoke-Isolation
}

Write-Host ""
Write-Host "Лог сохранён: $LogPath" -ForegroundColor Cyan
Write-Host "Нужна помощь с восстановлением? sos@nullday.ru" -ForegroundColor Cyan
