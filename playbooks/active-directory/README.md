# 🏛️ Playbook: Восстановление Active Directory с нуля

**Типовое время:** 4–8 часов  
**Сложность:** ⭐⭐⭐ Высокая  
**Требования:** Windows Server ISO, бэкап System State или снапшот VM с DC

---

## Когда использовать этот playbook

- Контроллер домена зашифрован или недоступен
- Требуется развернуть новый DC и восстановить базу AD из резервной копии
- Необходимо создать AD заново и перенастроить инфраструктуру

---

## Необходимые материалы

- [ ] Дистрибутив Windows Server (той же или новой версии)
- [ ] Лицензионный ключ Windows Server
- [ ] Резервная копия System State **или** снапшот VM с DC
- [ ] IP-план сети (адреса, маски, шлюзы)
- [ ] Список OU-структуры и групповых политик (если есть документация)
- [ ] Чистый сервер или VM для разворачивания

---

## Шаг 1. Установка Windows Server

```powershell
# После установки – задать имя компьютера (то же, что было у DC)
Rename-Computer -NewName "DC01" -Restart

# Задать статический IP
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.1 `
    -PrefixLength 24 -DefaultGateway 192.168.1.254

Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses 127.0.0.1, 192.168.1.1
```

---

## Шаг 2. Установка роли AD DS

```powershell
# Установить роли
Install-WindowsFeature -Name AD-Domain-Services, DNS `
    -IncludeManagementTools -IncludeAllSubFeature

# Импортировать модуль
Import-Module ADDSDeployment
```

---

## Шаг 3а. Восстановление из резервной копии System State

> Используйте этот путь если есть бэкап System State от Windows Server Backup

```powershell
# Загрузиться в режиме восстановления служб каталогов (DSRM)
# При загрузке нажать F8 → "Directory Services Restore Mode"

# В DSRM выполнить восстановление
wbadmin start systemstaterecovery `
    -backupTarget:\\BACKUP-SERVER\Backups `
    -machine:DC01 `
    -quiet

# После восстановления – выполнить авторитетное восстановление (если нужно)
ntdsutil
# В ntdsutil:
# activate instance ntds
# authoritative restore
# restore database
# quit
# quit
```

---

## Шаг 3б. Создание нового домена (если бэкапа AD нет)

```powershell
# Создание нового леса и домена
Install-ADDSForest `
    -DomainName "company.local" `
    -DomainNetbiosName "COMPANY" `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$false `
    -Force:$true
```

---

## Шаг 4. Проверка состояния после восстановления

```powershell
# Проверить репликацию
repadmin /showrepl
repadmin /replsummary

# Проверить состояние сервисов AD
dcdiag /test:replications /v
dcdiag /test:services
dcdiag /test:dns

# Проверить FSMO-роли
netdom query fsmo

# Проверить количество объектов в AD
Get-ADUser -Filter * | Measure-Object
Get-ADComputer -Filter * | Measure-Object
Get-ADGroup -Filter * | Measure-Object
```

---

## Шаг 5. Сброс паролей после восстановления

```powershell
# ОБЯЗАТЕЛЬНО: Сбросить пароль krbtgt (двукратно с интервалом)
Set-ADAccountPassword -Identity krbtgt -Reset `
    -NewPassword (ConvertTo-SecureString "НовыйСложныйПароль1!" -AsPlainText -Force)

# Подождать время репликации (минимум 10 минут) и повторить
Set-ADAccountPassword -Identity krbtgt -Reset `
    -NewPassword (ConvertTo-SecureString "НовыйСложныйПароль2!" -AsPlainText -Force)

# Сбросить пароли всех пользователей домена
Get-ADUser -Filter {Enabled -eq $true} | ForEach-Object {
    Set-ADAccountPassword -Identity $_ -Reset `
        -NewPassword (ConvertTo-SecureString "TempPass123!" -AsPlainText -Force)
    Set-ADUser -Identity $_ -ChangePasswordAtLogon $true
}

# Проверить и удалить посторонние учётные записи в группах администраторов
Get-ADGroupMember -Identity "Domain Admins" | Select-Object Name, SamAccountName
```

---

## Шаг 6. Настройка групповых политик безопасности

```powershell
# Создать GPO с базовыми политиками безопасности
New-GPO -Name "Security Baseline" | New-GPLink -Target "DC=company,DC=local"

# Политика паролей через Fine-Grained Password Policy
New-ADFineGrainedPasswordPolicy `
    -Name "StrongPasswordPolicy" `
    -Precedence 1 `
    -MinPasswordLength 12 `
    -PasswordHistoryCount 10 `
    -ComplexityEnabled $true `
    -LockoutDuration "00:30:00" `
    -LockoutObservationWindow "00:30:00" `
    -LockoutThreshold 5 `
    -MaxPasswordAge "90.00:00:00"
```

---

## Шаг 7. Настройка аудита событий безопасности

Через Group Policy Management:

```
Computer Configuration → Windows Settings → Security Settings → Advanced Audit Policy

Включить:
✓ Account Logon → Audit Credential Validation (Success, Failure)
✓ Account Management → Audit User Account Management (Success, Failure)
✓ Logon/Logoff → Audit Logon (Success, Failure)
✓ Logon/Logoff → Audit Special Logon (Success)
✓ Object Access → Audit File Share (Failure)
✓ Policy Change → Audit Audit Policy Change (Success)
✓ Privilege Use → Audit Sensitive Privilege Use (Failure)
```

---

## Шаг 8. Подключение рабочих мест к домену

```powershell
# На рабочей станции:
Add-Computer -DomainName "company.local" `
    -Credential (Get-Credential) `
    -Restart

# Массовое подключение через скрипт (запускать на каждой машине):
$domain = "company.local"
$user = "company\administrator"
$password = ConvertTo-SecureString "Пароль" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($user, $password)
Add-Computer -DomainName $domain -Credential $cred -Restart -Force
```

---

## Типичные проблемы и решения

| Проблема | Причина | Решение |
|---|---|---|
| Ошибка репликации после восстановления | USN rollback | `repadmin /options DC01 +DISABLE_OUTBOUND_REPL`, затем очистить метаданные |
| Не работает аутентификация Kerberos | Старые билеты после восстановления | Дождаться истечения TTL (10 часов) или перезагрузить все машины |
| DNS не разрешает имена | DNS не указывает на DC | Убедиться, что DC01 в DNS-клиентах всех машин |
| Компьютеры не видят домен | Учётные записи компьютеров устарели | `Test-ComputerSecureChannel -Repair` или повторное ввведение в домен |

---

## Критерии успешного завершения

- [ ] `dcdiag /v` завершается без ошибок
- [ ] Все пользователи могут аутентифицироваться в домене
- [ ] GPO применяются корректно (`gpresult /r`)
- [ ] DNS разрешает как внутренние, так и внешние имена
- [ ] Аудит событий безопасности включён и пишет в Event Log

---

**Следующий шаг:** [Playbook: Сервер 1С →](../1c-server/README.md)  
**Нужна помощь?** sos@nullday.ru
