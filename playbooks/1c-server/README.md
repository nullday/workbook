# 📊 Playbook: Восстановление сервера 1С:Предприятие

**Типовое время:** 3–6 часов  
**Сложность:** ⭐⭐⭐ Высокая  
**Требования:** дистрибутив 1С, лицензии, бэкап БД (SQL .bak или файлы ИБ)

---

## Необходимые материалы

- [ ] Дистрибутив платформы 1С:Предприятие 8.x (той же версии, что была)
- [ ] Пинкод-лицензии или файлы лицензий 1С (или доступ к серверу лицензирования)
- [ ] Дистрибутив MS SQL Server или PostgreSQL
- [ ] Резервные копии баз данных 1С (`.bak` для SQL или папки с файловыми ИБ)
- [ ] Список информационных баз с параметрами подключения
- [ ] Windows Server с ролью AD (должен быть восстановлен первым)

---

## Архитектура типовой установки

```
[Клиент 1С] ──→ [Сервер 1С (ragent, rmngr, rphost)]
                         │
                         └──→ [MS SQL Server / PostgreSQL]
                                       │
                                       └──→ [Базы данных .mdf/.ldf]
```

---

## Шаг 1. Установка MS SQL Server

```powershell
# Установка SQL Server (пример для SQL Server 2019)
# Запустить setup.exe с параметрами:

# Минимальная конфигурация для 1С
.\setup.exe /Q /ACTION=Install /FEATURES=SQLEngine `
    /INSTANCENAME=MSSQLSERVER `
    /SQLSVCACCOUNT="NT AUTHORITY\SYSTEM" `
    /SQLSYSADMINACCOUNTS="COMPANY\Domain Admins" `
    /TCPENABLED=1 `
    /NPENABLED=0 `
    /IACCEPTSQLSERVERLICENSETERMS

# После установки — включить TCP/IP в SQL Server Configuration Manager
# SQL Server Configuration Manager → SQL Server Network Configuration
# → Protocols for MSSQLSERVER → TCP/IP → Enable
```

```sql
-- Проверка после установки
SELECT @@VERSION
SELECT @@SERVERNAME
SELECT name, state_desc FROM sys.databases
```

---

## Шаг 2. Восстановление баз данных 1С из резервной копии

### Восстановление из SQL-бэкапа (.bak)

```sql
-- Посмотреть содержимое файла бэкапа
RESTORE FILELISTONLY FROM DISK = 'D:\Backups\Accounting.bak'

-- Восстановить базу данных
RESTORE DATABASE [Accounting]
FROM DISK = 'D:\Backups\Accounting.bak'
WITH MOVE 'Accounting' TO 'C:\SQLData\Accounting.mdf',
     MOVE 'Accounting_log' TO 'C:\SQLData\Accounting.ldf',
     RECOVERY, STATS = 10

-- Проверить состояние после восстановления
SELECT name, state_desc, recovery_model_desc
FROM sys.databases
WHERE name = 'Accounting'
```

### Если бэкап SQL повреждён — восстановление из файловой копии ИБ

```sql
-- Создать пустую базу для файловой ИБ
CREATE DATABASE [Accounting]
ON PRIMARY (
    NAME = 'Accounting',
    FILENAME = 'C:\SQLData\Accounting.mdf',
    SIZE = 1GB
)
LOG ON (
    NAME = 'Accounting_log',
    FILENAME = 'C:\SQLData\Accounting.ldf',
    SIZE = 512MB
)
```

```
# Затем загрузить файловую ИБ через конфигуратор 1С:
# → Загрузить информационную базу → указать .dt файл
```

---

## Шаг 3. Настройка прав SQL для сервера 1С

```sql
-- Создать логин для сервиса 1С
CREATE LOGIN [COMPANY\1c_service] FROM WINDOWS

-- Дать права на базы данных 1С
USE [Accounting]
CREATE USER [COMPANY\1c_service] FOR LOGIN [COMPANY\1c_service]
ALTER ROLE db_owner ADD MEMBER [COMPANY\1c_service]

-- Дать права на создание баз (для новых ИБ через консоль 1С)
USE [master]
GRANT CREATE ANY DATABASE TO [COMPANY\1c_service]
```

---

## Шаг 4. Установка сервера 1С:Предприятие

```powershell
# Установка компонентов сервера 1С
# Запустить setup.exe из дистрибутива 1С

# Компоненты для установки:
# ✓ 1С:Предприятие — сервер (обязательно)
# ✓ Модули расширения веб-сервера (если используется веб-клиент)
# ✓ Сервер хранилища конфигурации (если используется хранилище)

# После установки сервер запускается автоматически как служба
# "Агент сервера 1С:Предприятие 8.x"

# Проверить статус службы
Get-Service -Name "*1C*" | Select-Object Name, Status, StartType
```

---

## Шаг 5. Настройка кластера серверов через консоль

```
Запустить: Администрирование серверов 1С Предприятия

1. Добавить центральный сервер:
   → Имя: 1C-SERVER (или hostname сервера)
   → Порт: 1541 (стандартный)

2. Создать кластер (если не восстановлен из бэкапа):
   → Правой кнопкой → Создать кластер
   → Имя: Основной кластер
   → Порт: 1540

3. Добавить рабочий сервер:
   → Рабочие серверы → Создать рабочий сервер
   → Имя компьютера: 1C-SERVER
   → Порт агента: 1541

4. Добавить информационные базы:
   → Информационные базы → Создать информационную базу
   → Имя: Бухгалтерия
   → Сервер БД: SQL-SERVER\MSSQLSERVER
   → База данных: Accounting
```

---

## Шаг 6. Настройка регламентного задания резервного копирования

```sql
-- Создание плана обслуживания для автоматического бэкапа

-- Job для ежедневного полного бэкапа в 23:00
USE msdb
EXEC sp_add_job @job_name = N'1C Full Backup Daily'

EXEC sp_add_jobstep @job_name = N'1C Full Backup Daily',
    @step_name = N'Backup All 1C DBs',
    @command = N'
DECLARE @BackupPath NVARCHAR(256)
DECLARE @DBName NVARCHAR(128)
DECLARE @FileName NVARCHAR(512)

DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases
    WHERE name NOT IN (''master'', ''tempdb'', ''model'', ''msdb'')
    AND state_desc = ''ONLINE''

OPEN db_cursor
FETCH NEXT FROM db_cursor INTO @DBName

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @FileName = ''D:\Backups\'' + @DBName + ''_'' +
        CONVERT(VARCHAR, GETDATE(), 112) + ''.bak''
    BACKUP DATABASE @DBName TO DISK = @FileName WITH COMPRESSION, STATS = 10
    FETCH NEXT FROM db_cursor INTO @DBName
END

CLOSE db_cursor
DEALLOCATE db_cursor'

EXEC sp_add_schedule @schedule_name = N'Daily 23:00',
    @freq_type = 4, @freq_interval = 1,
    @active_start_time = 230000

EXEC sp_attach_schedule @job_name = N'1C Full Backup Daily',
    @schedule_name = N'Daily 23:00'

EXEC sp_add_jobserver @job_name = N'1C Full Backup Daily'
```

---

## Шаг 7. Проверка работоспособности

```powershell
# Проверить порты сервера 1С
Test-NetConnection -ComputerName 1C-SERVER -Port 1540
Test-NetConnection -ComputerName 1C-SERVER -Port 1541
Test-NetConnection -ComputerName SQL-SERVER -Port 1433

# Проверить службы
Get-Service -ComputerName 1C-SERVER -Name "*1C*"

# Проверить журналы сервера 1С
Get-Content "C:\Program Files\1cv8\srvinfo\srvrib.lst"
```

**Тест через тонкий клиент:**
1. Открыть 1С:Предприятие
2. Добавить информационную базу → На сервере 1С
3. Кластер: `1C-SERVER`, База: `Accounting`
4. Войти под тестовым пользователем
5. Открыть любой справочник или документ — убедиться в наличии данных

---

## Типичные проблемы

| Проблема | Решение |
|---|---|
| Ошибка соединения с сервером лицензирования | Проверить доступность порта 1543, перезапустить службу менеджера лицензий |
| `Сервер баз данных не обнаружен` | Проверить TCP/IP в SQL Configuration Manager, порт 1433 |
| Ошибка прав при восстановлении БД | Запустить SQL Management Studio от имени администратора |
| Медленная работа после восстановления | Выполнить `UPDATE STATISTICS` и `REBUILD INDEX` для всех таблиц 1С |
| Не запускается служба сервера 1С | Проверить права учётной записи службы на папку srvinfo |

---

## Критерии успешного завершения

- [ ] Все информационные базы 1С видны в консоли администрирования
- [ ] Пользователи могут войти в каждую ИБ
- [ ] Данные в базах актуальны (дата последних документов соответствует ожидаемой)
- [ ] Регламентные задания (закрытие месяца, отчёты) запускаются без ошибок
- [ ] Задание SQL Server Agent на резервное копирование активно

---

**Следующий шаг:** [Playbook: Файловый сервер →](../file-server/README.md)  
**Нужна помощь?** sos@nullday.ru
