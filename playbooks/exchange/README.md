# 📧 Playbook: Восстановление Exchange / почтового сервера

**Типовое время:** 4–8 часов  
**Сложность:** ⭐⭐⭐ Высокая  
**Требования:** дистрибутив Exchange, бэкап EDB или PST-архивы

---

## Необходимые материалы

- [ ] Дистрибутив Microsoft Exchange Server (той же версии)
- [ ] Бэкап базы почтовых ящиков (`.edb`) или PST-файлы
- [ ] SSL-сертификат для OWA/ActiveSync
- [ ] Доступ к DNS для настройки MX-записи
- [ ] Windows Server с ролью AD (должен быть восстановлен первым)

---

## Шаг 1. Установка Exchange Server

```powershell
# Установить необходимые компоненты
Install-WindowsFeature `
    NET-Framework-45-Features, RPC-over-HTTP-proxy, RSAT-Clustering, `
    RSAT-Clustering-CmdInterface, RSAT-Clustering-Mgmt, RSAT-Clustering-PowerShell, `
    WAS-Process-Model, Web-Asp-Net45, Web-Basic-Auth, Web-Client-Auth, `
    Web-Digest-Auth, Web-Dir-Browsing, Web-Dyn-Compression, Web-Http-Errors, `
    Web-Http-Logging, Web-Http-Redirect, Web-Http-Tracing, Web-ISAPI-Ext, `
    Web-ISAPI-Filter, Web-Lgcy-Mgmt-Console, Web-Metabase, Web-Mgmt-Console, `
    Web-Mgmt-Service, Web-Net-Ext45, Web-Request-Monitor, Web-Server, `
    Web-Stat-Compression, Web-Static-Content, Web-Windows-Auth, `
    Web-WMI, Windows-Identity-Foundation, RSAT-ADDS

# Установить Visual C++ Redistributable и URL Rewrite (скачать с Microsoft)

# Запустить установку Exchange
.\Setup.exe /mode:Install /role:Mailbox /IAcceptExchangeServerLicenseTerms
```

---

## Шаг 2. Восстановление базы почтовых ящиков

```powershell
# Создать Recovery Database из бэкапа
New-MailboxDatabase -Recovery -Name "Recovery DB" `
    -Server MAIL01 `
    -EdbFilePath "D:\ExchangeRestore\Mailbox.edb" `
    -LogFolderPath "D:\ExchangeRestore\Logs"

# Смонтировать
Mount-Database "Recovery DB"

# Восстановить почтовые ящики из Recovery DB
Get-MailboxStatistics -Database "Recovery DB" | ForEach-Object {
    New-MailboxRestoreRequest `
        -SourceDatabase "Recovery DB" `
        -SourceStoreMailbox $_.DisplayName `
        -TargetMailbox $_.DisplayName `
        -AllowLegacyDNSMismatch
}

# Проверить статус восстановления
Get-MailboxRestoreRequest | Get-MailboxRestoreRequestStatistics
```

---

## Шаг 3. Настройка коннекторов и DNS

```powershell
# Настроить Receive Connector
Set-ReceiveConnector "Default MAIL01" -MaxMessageSize 50MB

# Проверить Send Connector
Get-SendConnector | Select-Object Name, AddressSpaces, SmartHosts

# Настроить OWA Virtual Directory
Set-OwaVirtualDirectory -Identity "MAIL01\owa (Default Web Site)" `
    -ExternalUrl "https://mail.company.ru/owa" `
    -InternalUrl "https://mail.company.ru/owa"
```

```
DNS-записи для обновления:
MX  company.ru → mail.company.ru (приоритет 10)
A   mail.company.ru → [внешний IP сервера]
TXT company.ru → "v=spf1 ip4:[внешний IP] -all"
```

---

## Шаг 4. Проверка

```powershell
# Тест отправки
Send-MailMessage -To "test@gmail.com" -From "test@company.ru" `
    -Subject "Тест" -Body "Тестовое письмо" -SmtpServer "localhost"

# Проверить очередь
Get-Queue

# Проверить журналы
Get-MessageTrackingLog -Start (Get-Date).AddHours(-1) | `
    Select-Object Timestamp, Source, EventId, Sender, Recipients
```

---

## Критерии успешного завершения

- [ ] Пользователи могут зайти в OWA
- [ ] Отправка и получение работают для всех ящиков
- [ ] ActiveSync работает для мобильных устройств
- [ ] SPF/DKIM/DMARC настроены

---

**Нужна помощь?** sos@nullday.ru
