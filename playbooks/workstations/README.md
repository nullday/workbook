# 🖥️ Playbook: Массовое восстановление рабочих мест

**Типовое время:** 1–3 часа на одно место (в зависимости от автоматизации)  
**Сложность:** ⭐⭐ Средняя  
**Требования:** Windows ISO, образ системы или MDT/WDS-сервер

---

## Стратегии восстановления (выбрать одну)

| Стратегия | Когда применять | Скорость |
|---|---|---|
| **A. Bare-metal из образа** | Есть Acronis/Veeam образы рабочих мест | ⚡ Быстро |
| **B. MDT/WDS автоматическая установка** | Есть MDT-сервер или можно развернуть | ⚡⚡ Очень быстро для 20+ машин |
| **C. Ручная установка + скрипт** | Нет инфраструктуры, мало машин | 🐢 Медленно, но надёжно |

---

## Стратегия A. Восстановление из Acronis/Veeam образа

```powershell
# Загрузиться с Acronis Bootable Media
# Выбрать: Восстановить → Диск/Раздел
# Указать источник: сетевое хранилище или локальный диск
# Выбрать образ → Восстановить

# После восстановления и загрузки – выполнить скрипт персонализации:
# (запустить от имени администратора)

# Переименовать компьютер
$newName = Read-Host "Введите имя компьютера (например PC-IVANOV)"
Rename-Computer -NewName $newName

# Ввести в домен
Add-Computer -DomainName "company.local" `
    -Credential (Get-Credential -Message "Учётные данные администратора домена") `
    -Restart
```

---

## Стратегия B. Автоматическая установка через WDS + MDT

### Подготовка WDS-сервера (выполняется один раз)

```powershell
# Установить роли WDS и MDT
Install-WindowsFeature -Name WDS -IncludeManagementTools
# MDT скачать с Microsoft и установить отдельно

# Инициализировать WDS
wdsutil /initialize-server /reminst:"D:\RemoteInstall"
wdsutil /set-server /answerclients:all

# Добавить загрузочный образ (WinPE из ADK)
wdsutil /add-image /imagefile:"D:\Sources\boot.wim" /imagetype:boot

# Добавить образ установки Windows
wdsutil /add-image /imagefile:"D:\Sources\install.wim" `
    /imagetype:install /imagegroup:"Windows 10"
```

### MDT Task Sequence для автоматической установки

```xml
<!-- Файл CustomSettings.ini для автоматического ответа -->
[Settings]
Priority=Default

[Default]
OSInstall=Y
SkipCapture=YES
SkipAdminPassword=YES
SkipProductKey=YES
SkipComputerBackup=YES
SkipBitLocker=YES
SkipLocaleSelection=YES
KeyboardLocale=ru-RU
UserLocale=ru-RU
UILanguage=ru-RU
TimeZoneName=Russian Standard Time
JoinDomain=company.local
DomainAdmin=COMPANY\MDTJoinAccount
DomainAdminPassword=СекретныйПароль
MachineObjectOU=OU=Workstations,DC=company,DC=local
SkipDomainMembership=YES
SkipUserData=YES
SkipSummary=YES
SkipFinalSummary=YES
FinishAction=RESTART
```

---

## Стратегия C. Ручная установка со скриптом автонастройки

### C.1 Установка Windows

```
1. Загрузиться с USB-носителя с Windows 10/11
2. Выполнить чистую установку (удалить все разделы)
3. Не вводить ключ продукта при установке (введём через KMS позже)
4. Создать локального администратора: LocalAdmin / временный пароль
```

### C.2 Скрипт первичной настройки (запустить сразу после установки)

```powershell
# setup-workstation.ps1
# Запускать от имени локального администратора

param(
    [Parameter(Mandatory=$true)]
    [string]$ComputerName,    # Например: PC-IVANOV
    
    [Parameter(Mandatory=$true)]
    [string]$UserFullName,    # Например: Иванов Иван
    
    [string]$Department = ""  # Отдел для OU
)

Write-Host "=== Настройка рабочего места ===" -ForegroundColor Cyan
Write-Host "Компьютер: $ComputerName" -ForegroundColor Yellow
Write-Host "Пользователь: $UserFullName" -ForegroundColor Yellow

# 1. Переименовать компьютер
Write-Host "`n[1/8] Переименование компьютера..." -ForegroundColor Green
Rename-Computer -NewName $ComputerName -Force

# 2. Настройка сети – получение IP от DHCP (обычно уже настроено)
Write-Host "[2/8] Проверка сети..." -ForegroundColor Green
$adapter = Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceAlias $adapter.Name `
    -ServerAddresses "192.168.20.1","192.168.20.2"

# 3. Синхронизация времени с DC
Write-Host "[3/8] Синхронизация времени..." -ForegroundColor Green
w32tm /config /manualpeerlist:"DC01.company.local" /syncfromflags:manual /update
w32tm /resync

# 4. Установка обновлений Windows (фоново)
Write-Host "[4/8] Запуск обновлений Windows..." -ForegroundColor Green
Start-Process -FilePath "wuauclt.exe" -ArgumentList "/detectnow"

# 5. Отключить ненужные службы
Write-Host "[5/8] Оптимизация служб..." -ForegroundColor Green
$servicesToDisable = @("XblAuthManager","XblGameSave","XboxNetApiSvc",
                       "WMPNetworkSvc","Fax","RemoteRegistry")
foreach ($svc in $servicesToDisable) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Set-Service -Name $svc -StartupType Disabled
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
}

# 6. Базовые настройки безопасности
Write-Host "[6/8] Настройки безопасности..." -ForegroundColor Green

# Включить брандмауэр
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True

# Отключить автозапуск с USB
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord

# Включить UAC
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "EnableLUA" -Value 1 -Type DWord

# Отключить SMBv1
Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart

# 7. Установка базового ПО (через winget или ручные пакеты)
Write-Host "[7/8] Установка базового ПО..." -ForegroundColor Green

# Антивирус – пример для Kaspersky Endpoint Security
if (Test-Path "\\FS01\IT\Software\KES\setup_kes.exe") {
    Start-Process "\\FS01\IT\Software\KES\setup_kes.exe" `
        -ArgumentList "/s /pEULA=1 /pKSN=0 /pALLOWREBOOT=0" -Wait
}

# Office (если лицензия корпоративная)
if (Test-Path "\\FS01\IT\Software\Office\setup.exe") {
    Start-Process "\\FS01\IT\Software\Office\setup.exe" `
        -ArgumentList "/configure \\FS01\IT\Software\Office\config.xml" -Wait
}

# 1С тонкий клиент
if (Test-Path "\\FS01\IT\Software\1C\setup.exe") {
    Start-Process "\\FS01\IT\Software\1C\setup.exe" -ArgumentList "/S" -Wait
}

# 8. Ввод в домен
Write-Host "[8/8] Ввод в домен..." -ForegroundColor Green
$domainCred = Get-Credential -Message "Введите учётные данные администратора домена"

$ouPath = "OU=Workstations,DC=company,DC=local"
if ($Department -ne "") {
    $ouPath = "OU=$Department,OU=Workstations,DC=company,DC=local"
}

Add-Computer -DomainName "company.local" `
    -Credential $domainCred `
    -OUPath $ouPath `
    -Restart

Write-Host "`n✅ Настройка завершена. Компьютер будет перезагружен." -ForegroundColor Green
```

---

## C.3 Использование скрипта

```powershell
# Запустить на каждой машине после установки Windows:
.\setup-workstation.ps1 -ComputerName "PC-IVANOV" `
    -UserFullName "Иванов Иван" -Department "Accounting"
```

---

## Массовое развёртывание через PSRemoting (для уже настроенных машин в домене)

```powershell
# Получить список всех машин из AD
$computers = Get-ADComputer -Filter * -SearchBase "OU=Workstations,DC=company,DC=local" |
    Select-Object -ExpandProperty Name

# Проверить доступность
$computers | ForEach-Object {
    $online = Test-Connection -ComputerName $_ -Count 1 -Quiet
    [PSCustomObject]@{ Computer = $_; Online = $online }
} | Format-Table

# Выполнить команду на всех доступных машинах параллельно
Invoke-Command -ComputerName $computers -ThrottleLimit 20 -ScriptBlock {
    # Установить антивирус
    Start-Process "\\FS01\IT\Software\KES\setup_kes.exe" `
        -ArgumentList "/s /pEULA=1 /pKSN=0" -Wait
    
    # Обновить Windows
    Start-Process "wuauclt.exe" -ArgumentList "/detectnow"
    
    # Вернуть статус
    [PSCustomObject]@{
        Computer = $env:COMPUTERNAME
        AV = (Get-Service -Name "AVP" -ErrorAction SilentlyContinue)?.Status
        Status = "Configured"
    }
}
```

---

## Трекер прогресса восстановления рабочих мест

Ведите в таблице для контроля:

| № | Имя ПК | Пользователь | Отдел | Установка | Домен | АВ | ПО | Статус |
|---|---|---|---|---|---|---|---|---|
| 1 | PC-IVANOV | Иванов И.И. | Бухгалтерия | ✅ | ✅ | ✅ | ✅ | Готов |
| 2 | PC-PETROV | Петров П.П. | Продажи | ✅ | ✅ | ⏳ | ⏳ | В работе |
| 3 | PC-SIDOROV | Сидоров С.С. | HR | ⏳ | | | | Ожидает |

---

## Критерии успешного завершения

- [ ] Все рабочие места введены в домен
- [ ] Пользователи могут войти под доменными учётными записями
- [ ] Антивирус установлен и видит актуальные базы
- [ ] Корпоративное ПО (1С, Office) установлено и лицензировано
- [ ] Сетевые папки монтируются через GPO
- [ ] Принтеры установлены и работают

---

**Нужна помощь?** sos@nullday.ru
