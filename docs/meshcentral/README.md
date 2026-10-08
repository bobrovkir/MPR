# MeshCentral на Linux: установка с защищённой панелью

Схема:

```
[ПК магазинов за NAT] --TCP 4433 (агенты)-------------------> [Linux-сервер MeshCentral]
[Администраторы] --WireGuard (UDP 51820)--> 10.99.0.1:443 (веб-панель) --^
```

- Агенты подключаются к серверу сами, исходящим соединением на порт **4433**. Белые IP у ПК не нужны.
- Веб-панель (порт **443**) доступна **только через VPN**: и файрволом, и настройкой `userAllowedIP` в MeshCentral.
- Для всех администраторов обязательна двухфакторная аутентификация, а сервер делает ежедневные зашифрованные бэкапы.

Файлы в этой папке:

| Файл | Назначение |
|---|---|
| `config.json` | Конфигурация MeshCentral (кладётся в `/opt/meshcentral/meshcentral-data/`) |
| `meshcentral.service` | Unit для systemd |

Примеры ниже рассчитаны на Ubuntu 22.04/24.04 или Debian 12. Замените везде:
- `mesh.example.com` — на домен сервера;
- `admin@example.com` — на вашу почту (для Let's Encrypt);
- `203.0.113.10` — на белый IP сервера.

---

## 0. Что нужно заранее

- Linux-сервер (VPS или машина в офисе) с белым IP. Для нескольких сотен агентов хватит 2 vCPU, 2–4 ГБ RAM, 20+ ГБ диска.
- DNS-запись `A mesh.example.com → 203.0.113.10`.
- Если сервер в офисе за роутером, пробросьте на него порты **80/tcp, 4433/tcp, 51820/udp**. Порт 443 пробрасывать **не нужно**.

## 1. Система и Node.js

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y nodejs npm wireguard ufw unattended-upgrades
node --version   # нужен Node.js 18 или новее
```

Включите автоматические обновления безопасности ОС:

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
```

## 2. WireGuard для администраторов

Ключи сервера:

```bash
sudo -i
cd /etc/wireguard
umask 077
wg genkey | tee server.key | wg pubkey > server.pub
```

`/etc/wireguard/wg0.conf` на сервере:

```ini
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <содержимое server.key>

# Один блок [Peer] на каждого администратора
[Peer]
# admin1
PublicKey = <публичный ключ администратора>
AllowedIPs = 10.99.0.2/32
```

```bash
sudo systemctl enable --now wg-quick@wg0
```

На компьютере администратора установите клиент WireGuard (wireguard.com/install) и создайте туннель:

```ini
[Interface]
PrivateKey = <приватный ключ администратора, генерируется клиентом>
Address = 10.99.0.2/32

[Peer]
PublicKey = <содержимое server.pub>
Endpoint = 203.0.113.10:51820
AllowedIPs = 10.99.0.0/24
PersistentKeepalive = 25
```

Чтобы браузер открывал панель по имени (и сертификат Let's Encrypt был валиден), на компьютере администратора добавьте строку в файл hosts
(`C:\Windows\System32\drivers\etc\hosts`):

```
10.99.0.1  mesh.example.com
```

## 3. Файрвол

> Сначала проверьте, что SSH работает через VPN (`ssh user@10.99.0.1`), и только потом закрывайте SSH снаружи. Иначе можно потерять доступ к серверу.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow 51820/udp                       # WireGuard
sudo ufw allow 4433/tcp                        # агенты MeshCentral
sudo ufw allow 80/tcp                          # Let's Encrypt (проверка домена) и редирект
sudo ufw allow in on wg0 to any port 443 proto tcp   # веб-панель только из VPN
sudo ufw allow in on wg0 to any port 22 proto tcp    # SSH из VPN

# Временно, пока настраиваете VPN; потом удалите: sudo ufw delete allow 22/tcp
sudo ufw allow 22/tcp

sudo ufw enable
sudo ufw status verbose
```

## 4. Установка MeshCentral

Отдельный системный пользователь без входа в систему:

```bash
sudo useradd -r -m -d /opt/meshcentral -s /usr/sbin/nologin meshcentral
sudo -u meshcentral bash -c 'cd /opt/meshcentral && npm install meshcentral'
```

Конфигурация:

```bash
sudo -u meshcentral mkdir -p /opt/meshcentral/meshcentral-data /opt/meshcentral/backups
sudo cp config.json /opt/meshcentral/meshcentral-data/config.json
sudo chown meshcentral:meshcentral /opt/meshcentral/meshcentral-data/config.json
sudo chmod 600 /opt/meshcentral/meshcentral-data/config.json
sudo nano /opt/meshcentral/meshcentral-data/config.json
```

В `config.json` замените домен, почту и **`zipPassword`** (длинный случайный пароль, например из `openssl rand -base64 32`; сохраните его в менеджере паролей, без него бэкап не расшифровать).

Что делают ключевые настройки:

| Настройка | Зачем |
|---|---|
| `agentPort: 4433` | Агенты подключаются на отдельный порт, его можно открыть в интернет отдельно от панели |
| `userAllowedIP: 10.99.0.0/24` | Вход в панель разрешён только с адресов VPN (вторая линия защиты после файрвола) |
| `WANonly: true` | Отключает поиск агентов в локальной сети, сервер работает только через интернет |
| `maxInvalidLogin` | Блокировка на 30 минут после 5 неверных паролей за 10 минут |
| `sessionTime: 30` | Сессия в панели истекает через 30 минут бездействия |
| `allowLoginToken: false` | Запрещает токены входа, которые обходят пароль и 2FA |
| `selfUpdate: false` | Сервер не обновляет себя сам; обновления ставятся вручную (раздел 8) |
| `newAccounts: false` | Регистрация новых пользователей со страницы входа запрещена |
| `force2factor: true` | Каждый пользователь обязан настроить 2FA (приложение-аутентификатор) |
| `autoBackup` | Ежедневный зашифрованный бэкап, хранятся последние 14 дней |
| `letsencrypt.production: false` | Сначала тестовый сертификат; после проверки поменять на `true` |

## 5. Запуск через systemd

```bash
sudo cp meshcentral.service /etc/systemd/system/meshcentral.service
sudo systemctl daemon-reload
sudo systemctl enable --now meshcentral
sudo journalctl -u meshcentral -f
```

При первом запуске MeshCentral сам доустановит нужные npm-модули (Let's Encrypt, 2FA и т.д.) и сгенерирует ключи сервера. Это занимает 1–2 минуты.

Когда в журнале нет ошибок Let's Encrypt, переключите сертификат на боевой:

```bash
sudo sed -i 's/"production": false/"production": true/' /opt/meshcentral/meshcentral-data/config.json
sudo systemctl restart meshcentral
```

## 6. Первый администратор

1. Подключитесь к VPN и откройте `https://mesh.example.com`.
2. Создайте учётную запись: **первая созданная учётная запись автоматически становится администратором сервера**. Сделайте это сразу после запуска, пока никто другой не мог зайти на страницу.
   Если кнопки создания учётной записи нет, создайте администратора из консоли:
   ```bash
   sudo systemctl stop meshcentral
   cd /opt/meshcentral
   sudo -u meshcentral node node_modules/meshcentral --createaccount admin --email admin@example.com
   sudo -u meshcentral node node_modules/meshcentral --adminaccount admin
   sudo systemctl start meshcentral
   ```
   (пароль будет запрошен или задан параметром `--pass`; в последнем случае удалите команду из истории: `history -c`).
3. Сразу настройте 2FA (приложение-аутентификатор: Google Authenticator, Aegis, 2FAS и т.п.) и сохраните резервные коды.
4. Проверьте, что с адреса не из VPN панель не открывается (например, с телефона через мобильный интернет).

Другим администраторам создавайте учётные записи вручную (*Мои пользователи → Добавить*) и давайте права только на нужные группы устройств, а не права администратора сервера.

## 7. Установка агента на ПК

1. В панели создайте **группу устройств** (например, по магазину или региону).
2. В настройках группы задайте **согласие пользователя**: например, уведомлять пользователя при подключении к рабочему столу или запрашивать разрешение. Это и честнее по отношению к сотрудникам, и сразу видно, если подключился кто-то посторонний.
3. *Добавить агент → Windows* → скачайте установщик. Адрес сервера (`mesh.example.com:4433`) и группа уже встроены в файл.
4. Тихая установка на ПК (от администратора):

   ```powershell
   .\meshagent64-<имя_группы>.exe -fullinstall
   ```

   Раскатать можно через GPO (для ПК в домене), через существующий скрипт или вручную. Удаление: `-fulluninstall`.

5. Через минуту ПК появится в группе.

Антивирус может среагировать на агент, потому что такими инструментами пользуются и злоумышленники. Если так, добавьте исключение для `C:\Program Files\Mesh Agent\` и **сверьте, что файл скачан именно с вашего сервера**.

## 8. Обновления

Обновлять сервер MeshCentral нужно регулярно: большинство взломов систем удалённого управления идёт через уже известные и исправленные уязвимости.

Посмотреть, что вышло: https://github.com/Ylianst/MeshCentral/releases

```bash
# Перед обновлением сделайте свежий бэкап (раздел 9)
sudo systemctl stop meshcentral
sudo -u meshcentral bash -c 'cd /opt/meshcentral && npm install meshcentral@latest'
sudo systemctl start meshcentral
sudo journalctl -u meshcentral -n 50
```

Агенты на ПК обновляются автоматически после обновления сервера.

## 9. Бэкапы

Сервер сам кладёт зашифрованные архивы в `/opt/meshcentral/backups` раз в сутки. Этого мало: если сервер умрёт вместе с диском, пропадут и бэкапы. Копируйте их на другую машину или в облако (rsync, rclone, `scp` по cron).

Самое ценное — папка `/opt/meshcentral/meshcentral-data`:
- **Если её потерять**, агенты не смогут подключиться к новому серверу, их придётся переустанавливать на всех ПК.
- **Если она утечёт**, в ней ключи сервера: злоумышленник сможет выдать себя за ваш сервер. Храните бэкапы только в зашифрованном виде и с ограниченным доступом.

Ручной бэкап:

```bash
sudo systemctl stop meshcentral
sudo tar czf /root/meshcentral-data-$(date +%F).tar.gz -C /opt/meshcentral meshcentral-data
sudo systemctl start meshcentral
```

## 10. Проверка безопасности после настройки

- [ ] Снаружи (без VPN) `https://mesh.example.com` не открывается.
- [ ] `nmap -p 22,80,443,4433 203.0.113.10` снаружи: открыты только 80 и 4433 (и 22, если не убрали временное правило).
- [ ] У всех учётных записей включена 2FA.
- [ ] Временное правило SSH (`allow 22/tcp`) удалено.
- [ ] `letsencrypt.production` переключено на `true`, сертификат валидный.
- [ ] `zipPassword` заменён и сохранён в менеджере паролей.
- [ ] Бэкапы копируются на другую машину; восстановление проверено хотя бы раз.
- [ ] Включены автоматические обновления безопасности ОС.
- [ ] Записан день в календаре для проверки обновлений MeshCentral (например, раз в 2 недели).
