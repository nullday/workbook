# 📁 Playbook: Восстановление файлового сервера

**Типовое время:** 2–4 часа (плюс время копирования данных)  
**Сложность:** ⭐⭐ Средняя  
**Требования:** Windows Server, бэкап данных, матрица прав доступа

---

## Шаг 1. Установка и настройка роли файлового сервера

```powershell
# Установить роль
Install-WindowsFeature -Name FS-FileServer, FS-Resource-Manager `
    -IncludeManagementTools

# Создать корневую папку для общих ресурсов
New-Item -Path "D:\Shares" -ItemType Directory

# Создать структуру папок (пример типовой организации)
$folders = @(
    "D:\Shares\Common",           # Общие файлы для всех
    "D:\Shares\Accounting",       # Бухгалтерия
    "D:\Shares\HR",               # Кадры
    "D:\Shares\Management",       # Руководство
    "D:\Shares\IT",               # IT-отдел
    "D:\Shares\Archive"           # Архив
)
$folders | ForEach-Object { New-Item -Path $_ -ItemType Directory -Force }
```

---

## Шаг 2. Восстановление данных из резервной копии

```powershell
# Вариант 1: Восстановление через Robocopy с сетевого хранилища
robocopy \\BACKUP-NAS\FileServerBackup D:\Shares `
    /E /COPYALL /R:3 /W:5 /LOG:D:\restore_log.txt /TEE

# Вариант 2: Восстановление из Windows Server Backup
wbadmin start recovery `
    -backupTarget:\\BACKUP-NAS\Backups `
    -machine:FILESERVER `
    -recoveryTarget:D:\Shares `
    -itemtype:file `
    -items:\\FILESERVER\D:\Shares `
    -quiet

# Вариант 3: Просто скопировать с чистого носителя
robocopy E:\BackupDrive\Shares D:\Shares /E /COPYALL /LOG:D:\copy_log.txt

# Проверить результат
Get-ChildItem D:\Shares -Recurse | Measure-Object | Select-Object Count
```

---

## Шаг 3. Настройка прав доступа

```powershell
# Отключить наследование прав на корневой папке
$acl = Get-Acl "D:\Shares"
$acl.SetAccessRuleProtection($true, $false)
Set-Acl "D:\Shares" $acl

# Функция для настройки прав папки
function Set-FolderPermissions {
    param(
        [string]$Path,
        [hashtable]$Permissions  # @{"DOMAIN\Group" = "ReadAndExecute"}
    )
    
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    
    # Всегда добавлять SYSTEM и Domain Admins с полными правами
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit",
        "None", "Allow"
    )
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "COMPANY\Domain Admins", "FullControl", "ContainerInherit,ObjectInherit",
        "None", "Allow"
    )
    $acl.AddAccessRule($systemRule)
    $acl.AddAccessRule($adminRule)
    
    foreach ($entry in $Permissions.GetEnumerator()) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $entry.Key, $entry.Value, "ContainerInherit,ObjectInherit",
            "None", "Allow"
        )
        $acl.AddAccessRule($rule)
    }
    
    Set-Acl -Path $Path -AclObject $acl
}

# Настроить права для каждой папки
Set-FolderPermissions -Path "D:\Shares\Common" -Permissions @{
    "COMPANY\Domain Users" = "ReadAndExecute"
    "COMPANY\IT" = "Modify"
}

Set-FolderPermissions -Path "D:\Shares\Accounting" -Permissions @{
    "COMPANY\Accounting" = "Modify"
    "COMPANY\Management" = "ReadAndExecute"
}

Set-FolderPermissions -Path "D:\Shares\HR" -Permissions @{
    "COMPANY\HR" = "Modify"
    "COMPANY\Management" = "ReadAndExecute"
}

Set-FolderPermissions -Path "D:\Shares\Management" -Permissions @{
    "COMPANY\Management" = "Modify"
}

Set-FolderPermissions -Path "D:\Shares\IT" -Permissions @{
    "COMPANY\IT" = "Modify"
}
```

---

## Шаг 4. Создание сетевых папок (SMB Shares)

```powershell
# Создать SMB-шары с правильными настройками
$shares = @(
    @{ Name = "Common";     Path = "D:\Shares\Common";     Description = "Общие документы" },
    @{ Name = "Accounting"; Path = "D:\Shares\Accounting"; Description = "Бухгалтерия" },
    @{ Name = "HR";         Path = "D:\Shares\HR";         Description = "Кадры" },
    @{ Name = "Management"; Path = "D:\Shares\Management"; Description = "Руководство" },
    @{ Name = "IT";         Path = "D:\Shares\IT";         Description = "IT-отдел" }
)

foreach ($share in $shares) {
    # Удалить шару если уже существует
    if (Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $share.Name -Force
    }
    
    New-SmbShare `
        -Name $share.Name `
        -Path $share.Path `
        -Description $share.Description `
        -EncryptData $true `
        -FolderEnumerationMode AccessBased  # Пользователи видят только доступные им папки
    
    # Права на уровне SMB — только Full Access для всех (права регулируются через NTFS)
    Grant-SmbShareAccess -Name $share.Name -AccountName "Everyone" `
        -AccessRight Full -Force
}

# Проверить созданные шары
Get-SmbShare | Select-Object Name, Path, Description
```

---

## Шаг 5. Настройка теневых копий (Shadow Copies)

```powershell
# Включить теневые копии на томе D:
$volume = Get-WmiObject Win32_Volume -Filter "DriveLetter='D:'"

# Создать задание через vssadmin
vssadmin add shadowstorage /for=D: /on=D: /maxsize=15%

# Создать расписание через Task Scheduler (7:00 и 12:00 каждый рабочий день)
$trigger1 = New-ScheduledTaskTrigger -Daily -At 07:00
$trigger2 = New-ScheduledTaskTrigger -Daily -At 12:00
$action = New-ScheduledTaskAction -Execute "vssadmin" `
    -Argument "create shadow /for=D:"
Register-ScheduledTask `
    -TaskName "Shadow Copy D 07:00" `
    -Trigger $trigger1 `
    -Action $action `
    -RunLevel Highest `
    -Force
Register-ScheduledTask `
    -TaskName "Shadow Copy D 12:00" `
    -Trigger $trigger2 `
    -Action $action `
    -RunLevel Highest `
    -Force

# Создать первую теневую копию вручную
vssadmin create shadow /for=D:
```

---

## Шаг 6. Настройка DFS (если использовалась)

```powershell
# Установить роль DFS
Install-WindowsFeature -Name FS-DFS-Namespace, FS-DFS-Replication `
    -IncludeManagementTools

# Создать пространство имён DFS
New-DfsnRoot -Path "\\company.local\Files" `
    -Type DomainV2 `
    -TargetPath "\\FILESERVER\Common"

# Добавить папки DFS
New-DfsnFolder -Path "\\company.local\Files\Accounting" `
    -TargetPath "\\FILESERVER\Accounting"
New-DfsnFolder -Path "\\company.local\Files\HR" `
    -TargetPath "\\FILESERVER\HR"
```

---

## Шаг 7. Проверка

```powershell
# Проверить доступность шар
Get-SmbShare | Get-SmbShareAccess

# Проверить права NTFS
Get-Acl "D:\Shares\Accounting" | Format-List

# Проверить теневые копии
vssadmin list shadowstorage
vssadmin list shadows

# Тест доступа от имени пользователя (запустить на клиентской машине)
# net use Z: \\FILESERVER\Common /user:company\testuser
```

---

## Критерии успешного завершения

- [ ] Все сетевые папки доступны с рабочих мест
- [ ] Пользователи видят только те папки, к которым имеют доступ
- [ ] Теневые копии создаются по расписанию
- [ ] Объём данных соответствует исходному (сравнить с бэкапом)

---

**Следующий шаг:** [Playbook: MikroTik →](../mikrotik/README.md)  
**Нужна помощь?** sos@nullday.ru
