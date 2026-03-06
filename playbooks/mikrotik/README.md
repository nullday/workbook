# 🌐 Playbook: Восстановление MikroTik после компрометации

**Типовое время:** 2–5 часов  
**Сложность:** ⭐⭐⭐ Высокая  
**Требования:** физический доступ к устройству, бэкап конфигурации или документация по сети

> ⚠️ После атаки шифровальщика MikroTik может быть скомпрометирован. Нельзя доверять существующей конфигурации — только полный сброс и настройка с нуля.

---

## Шаг 1. Полный сброс устройства

```routeros
# Вариант 1: Через консоль (если доступ есть)
/system reset-configuration no-defaults=yes skip-backup=yes

# Вариант 2: Физический сброс
# Зажать кнопку Reset на 5 секунд при включённом питании
# Дождаться мигания всех индикаторов

# Вариант 3: Через Netinstall (если устройство не отвечает)
# Скачать Netinstall с mikrotik.com
# Зажать Reset перед подключением питания → удерживать до начала загрузки
# Устройство появится в Netinstall → выбрать прошивку → Install
```

---

## Шаг 2. Первичная защита после сброса

```routeros
# Подключиться через WinBox по MAC-адресу (IP ещё не назначен)
# Логин: admin, пароль: пустой (или тот что на наклейке)

# ПЕРВОЕ ДЕЙСТВИЕ — сменить пароль
/user set admin password="НовыйСложныйПароль1!"

# Отключить неиспользуемые сервисы
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
set ssh port=2222          # Нестандартный порт
set winbox port=8291       # Можно изменить

# Отключить MAC-сервер после первоначальной настройки
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none

# Отключить обнаружение соседей (Neighbor Discovery) на внешнем интерфейсе
/ip neighbor discovery-settings set discover-interface-list=!ether1
```

---

## Шаг 3. Восстановление из резервной копии

```routeros
# Если есть backup-файл (.backup)
/system backup load name=company-backup.backup password="ПарольБэкапа"

# Если есть экспорт конфигурации (.rsc)
/import file-name=company-config.rsc

# После загрузки — проверить и сменить все пароли
/user print
/ppp secret print
/ip ipsec identity print
```

---

## Шаг 4. Настройка с нуля (если бэкапа нет)

### 4.1 Базовая конфигурация интерфейсов

```routeros
# Переименовать интерфейсы для удобства
/interface set ether1 name=WAN comment="Интернет-провайдер"
/interface set ether2 name=LAN comment="Основная сеть"
/interface set ether3 name=SERVERS comment="Серверный сегмент"
/interface set ether4 name=MANAGEMENT comment="Управление"

# Настроить VLAN (если используются)
/interface vlan
add interface=LAN name=VLAN10-Users vlan-id=10 comment="Пользователи"
add interface=LAN name=VLAN20-Servers vlan-id=20 comment="Серверы"
add interface=LAN name=VLAN30-MGMT vlan-id=30 comment="Управление"
add interface=LAN name=VLAN99-GUEST vlan-id=99 comment="Гости"
```

### 4.2 IP-адресация

```routeros
# WAN — получить от провайдера (или статический)
/ip address add address=x.x.x.x/xx interface=WAN comment="WAN IP"

# LAN сегменты
/ip address add address=192.168.10.1/24 interface=VLAN10-Users
/ip address add address=192.168.20.1/24 interface=VLAN20-Servers
/ip address add address=192.168.30.1/24 interface=VLAN30-MGMT

# DHCP для пользователей
/ip pool add name=pool-users ranges=192.168.10.100-192.168.10.250
/ip dhcp-server add name=dhcp-users interface=VLAN10-Users \
    address-pool=pool-users lease-time=1d disabled=no
/ip dhcp-server network add address=192.168.10.0/24 \
    gateway=192.168.10.1 dns-server=192.168.20.1,192.168.20.2
```

### 4.3 NAT и маршрутизация

```routeros
# Маршрут по умолчанию
/ip route add dst-address=0.0.0.0/0 gateway=x.x.x.x comment="Default GW"

# Masquerade для исходящего трафика
/ip firewall nat add chain=srcnat out-interface=WAN \
    action=masquerade comment="NAT to Internet"
```

### 4.4 Базовые правила файрвола

```routeros
/ip firewall filter

# --- INPUT (защита самого роутера) ---
# Разрешить established/related
add chain=input connection-state=established,related action=accept \
    comment="Allow established"
# Отбросить invalid
add chain=input connection-state=invalid action=drop \
    comment="Drop invalid"
# Разрешить ICMP (ping)
add chain=input protocol=icmp action=accept comment="Allow ICMP"
# Разрешить доступ к управлению только из сети MGMT
add chain=input src-address=192.168.30.0/24 action=accept \
    comment="Allow management from MGMT VLAN"
# Запретить доступ к роутеру с WAN
add chain=input in-interface=WAN action=drop \
    comment="Drop all from WAN"
# Запретить доступ к роутеру из пользовательской сети
add chain=input in-interface=VLAN10-Users action=drop \
    comment="Drop management from users"

# --- FORWARD (трафик через роутер) ---
add chain=forward connection-state=established,related action=accept \
    comment="Allow established forward"
add chain=forward connection-state=invalid action=drop \
    comment="Drop invalid forward"
# Пользователи → Интернет: разрешить
add chain=forward in-interface=VLAN10-Users out-interface=WAN \
    action=accept comment="Users to Internet"
# Пользователи → Серверы: разрешить нужные порты
add chain=forward in-interface=VLAN10-Users dst-address=192.168.20.0/24 \
    protocol=tcp dst-port=445,1433,1541,1540,3389 action=accept \
    comment="Users to Servers (SMB, SQL, 1C, RDP)"
# Запретить прямой доступ пользователей к серверам кроме разрешённого
add chain=forward in-interface=VLAN10-Users dst-address=192.168.20.0/24 \
    action=drop comment="Block unauthorized user to server"
# Запретить всё остальное из WAN
add chain=forward in-interface=WAN action=drop \
    comment="Drop all from WAN"
```

### 4.5 Защита от брутфорса RDP/SSH

```routeros
/ip firewall filter

# Блокировать IP после 5 неудачных попыток RDP за 1 минуту
add chain=forward protocol=tcp dst-port=3389 \
    src-address-list=rdp_blacklist action=drop \
    comment="Drop RDP bruteforce"
add chain=forward protocol=tcp dst-port=3389 \
    connection-state=new src-address-list=rdp_stage3 \
    action=add-src-to-address-list address-list=rdp_blacklist \
    address-list-timeout=1d comment="RDP stage3 → blacklist"
add chain=forward protocol=tcp dst-port=3389 \
    connection-state=new src-address-list=rdp_stage2 \
    action=add-src-to-address-list address-list=rdp_stage3 \
    address-list-timeout=1m
add chain=forward protocol=tcp dst-port=3389 \
    connection-state=new src-address-list=rdp_stage1 \
    action=add-src-to-address-list address-list=rdp_stage2 \
    address-list-timeout=1m
add chain=forward protocol=tcp dst-port=3389 connection-state=new \
    action=add-src-to-address-list address-list=rdp_stage1 \
    address-list-timeout=1m comment="RDP stage1"
```

---

## Шаг 5. Настройка VPN (если использовался)

```routeros
# WireGuard VPN (рекомендуется как современная замена PPTP/L2TP)
/interface wireguard add name=wg-vpn listen-port=51820 mtu=1420
# Посмотреть публичный ключ для передачи клиентам
/interface wireguard print

# Добавить пиры (сотрудников)
/interface wireguard peers
add interface=wg-vpn \
    public-key="PublicKeyСотрудника==" \
    allowed-address=10.10.0.2/32 \
    comment="Иванов И.И."

# IP для VPN-интерфейса
/ip address add address=10.10.0.1/24 interface=wg-vpn

# Разрешить VPN-порт в файрволе
/ip firewall filter add chain=input protocol=udp dst-port=51820 \
    action=accept comment="WireGuard VPN" place-before=0
```

---

## Шаг 6. Настройка уведомлений и мониторинга

```routeros
# Email-уведомления
/tool e-mail set server=smtp.yandex.ru port=587 \
    tls=starttls user=alert@company.ru password="Пароль"

# Уведомление при входе администратора
/system script add name=notify-login source={
    :local msg ("Login alert: " . [/system identity get name])
    /tool e-mail send to="admin@company.ru" subject=$msg body=$msg
}
/system scheduler add name=check-login interval=1m \
    on-event=notify-login

# Резервное копирование конфигурации по расписанию
/system script add name=auto-backup source={
    /system backup save name=("auto-" . [/system clock get date])
    /export file=("auto-export-" . [/system clock get date])
}
/system scheduler add name=daily-backup interval=1d \
    start-time=03:00:00 on-event=auto-backup
```

---

## Шаг 7. Финальная проверка безопасности

```routeros
# Посмотреть все активные сессии
/ip firewall connection print

# Проверить текущих подключённых пользователей
/ip hotspot active print
/ppp active print

# Убедиться что нет посторонних правил NAT
/ip firewall nat print

# Убедиться что нет посторонних скриптов/шедулеров
/system scheduler print
/system script print

# Проверить список пользователей роутера
/user print

# Сохранить конфигурацию и экспортировать для хранения
/system backup save name=post-recovery-backup
/export file=post-recovery-config
```

---

## Критерии успешного завершения

- [ ] Устройство сброшено до заводских настроек и перенастроено с нуля
- [ ] Пароль администратора изменён, стандартный логин `admin` переименован
- [ ] Внешний RDP и управление с WAN заблокированы
- [ ] VLAN-сегментация восстановлена
- [ ] Защита от брутфорса активна
- [ ] Автоматическое резервное копирование конфигурации настроено

---

**Следующий шаг:** [Playbook: Рабочие места →](../workstations/README.md)  
**Нужна помощь?** sos@nullday.ru
