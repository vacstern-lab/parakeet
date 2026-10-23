#!/usr/bin/env bash
# ==============================================================================
# Mikan VPN: Ultimate Setup, Low-RAM Tuning & Hardening
# Оптимизировано под: 768MB RAM | 1 vCPU | 5GB SSD (Node) / 20GB SAS (Main)
# ==============================================================================

set -euo pipefail

# Перенаправляем стандартный ввод на терминал для корректной работы через curl | bash
if [[ -t 0 ]] || [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: запустите скрипт от имени root (sudo -i)${NC}"
   exit 1
fi

# 1. Снятие блокировок apt и отключение фоновых автообновлений
unlock_apt() {
    echo -e "${BLUE}=== [1/8] Проверка пакетного менеджера и снятие блокировок ===${NC}"
    systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl mask unattended-upgrades.service 2>/dev/null || true

    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if (( waited >= 15 )); then
            echo -e "${YELLOW}Принудительная остановка зависших процессов apt/unattended-upgr...${NC}"
            killall -q -9 unattended-upgr apt apt-get 2>/dev/null || true
            sleep 2
            break
        fi
        echo -e "${YELLOW}Ожидание освобождения dpkg (${waited} сек)...${NC}"
        sleep 3
        waited=$((waited + 3))
    done

    dpkg --configure -a 2>/dev/null || true
}

# 2. Основная оптимизация и защита
apply_optimizations() {
    unlock_apt

    # Определяем общий размер корневого диска в ГБ
    DISK_TOTAL_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$2); print $2}')
    echo -e "${GREEN}Обнаружен диск: ~${DISK_TOTAL_GB} ГБ${NC}"

    echo -e "${BLUE}=== [2/8] Установка системных утилит и защиты ===${NC}"
    # Если диск маленький (<= 7 ГБ), отключаем кэширование пакетов apt
    if (( DISK_TOTAL_GB <= 7 )); then
        cat <<EOF > /etc/apt/apt.conf.d/99-no-cache
Dir::Cache "";
Dir::Cache::archives "";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
    fi

    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl wget jq ufw zram-tools fail2ban ca-certificates psmisc procps

    echo -e "${BLUE}=== [3/8] Настройка памяти (768MB RAM Tuning: zRAM + Умный Swap) ===${NC}"
    cat <<EOF > /etc/default/zramswap
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF
    systemctl restart zramswap 2>/dev/null || true

    # Если диск больше 10 ГБ (Москва 20GB SAS) — создаем страховочный swapfile на 1 ГБ
    if (( DISK_TOTAL_GB >= 10 )); then
        if [[ ! -f /swapfile ]]; then
            echo -e "${YELLOW}Диск позволяет (>10 ГБ): создаем страховочный /swapfile на 1 ГБ...${NC}"
            fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon -p 10 /swapfile
            grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
        fi
    else
        echo -e "${YELLOW}Малый диск (${DISK_TOTAL_GB} ГБ SSD): файловый swap пропущен для экономии места, работает только zRAM.${NC}"
    fi

    echo -e "${BLUE}=== [4/8] Жесткий лимит логов Journald (до 20 МБ) ===${NC}"
    mkdir -p /etc/systemd/journald.conf.d/
    cat <<EOF > /etc/systemd/journald.conf.d/low-disk.conf
[Journal]
SystemMaxUse=20M
SystemKeepFree=150M
RuntimeMaxUse=10M
MaxRetentionSec=2day
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald
    journalctl --vacuum-size=15M >/dev/null 2>&1 || true

    echo -e "${BLUE}=== [5/8] Лимит логов Docker (макс. 2 файла по 5 МБ) ===${NC}"
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]] && jq empty /etc/docker/daemon.json 2>/dev/null; then
        TMP_JSON=$(mktemp)
        jq '. + {"log-driver": "json-file", "log-opts": {"max-size": "5m", "max-file": "2"}}' /etc/docker/daemon.json > "$TMP_JSON" && mv "$TMP_JSON" /etc/docker/daemon.json
    else
        cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "2"
  }
}
EOF
    fi

    echo -e "${BLUE}=== [6/8] Тюнинг ядра: BBR, сеть под 1 vCPU / 768M и защита от атак ===${NC}"
    cat <<EOF > /etc/sysctl.d/99-vpn-hardening.conf
# Ускорение TCP и BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# Оптимизация очередей и буферов под 768 МБ ОЗУ
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10240 65535

# Маршрутизация VPN
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Сетевая безопасность (Hardening)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# Память и кеширование дисков (снижение износа SSD и задержек SAS)
vm.swappiness = 80
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
EOF
    sysctl --system >/dev/null 2>&1 || true

    echo -e "${BLUE}=== [7/8] Настройка защиты SSH (Fail2Ban) и файрвола (UFW) ===${NC}"
    SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | head -n1)
    SSH_PORT=${SSH_PORT:-22}

    # Конфигурация Fail2ban
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    # Настройка UFW
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw limit "$SSH_PORT"/tcp comment 'SSH Rate Limit' >/dev/null 2>&1 || true
    ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1 || true
    ufw allow 443/udp comment 'QUIC' >/dev/null 2>&1 || true
    ufw allow 10000:65000/tcp comment 'VPN TCP' >/dev/null 2>&1 || true
    ufw allow 10000:65000/udp comment 'VPN UDP' >/dev/null 2>&1 || true
    echo "y" | ufw enable >/dev/null 2>&1 || true

    echo -e "${BLUE}=== [8/8] Установка ежедневной автоочистки диска ===${NC}"
    cat <<'EOF' > /etc/cron.daily/disk-cleaner
#!/bin/bash
journalctl --vacuum-size=15M >/dev/null 2>&1
journalctl --vacuum-time=2d >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/* /tmp/* /var/tmp/* >/dev/null 2>&1
if command -v docker &>/dev/null; then
    docker system prune -af --filter "until=48h" >/dev/null 2>&1
fi
EOF
    chmod +x /etc/cron.daily/disk-cleaner

    # Очищаем списки пакетов сразу, если мы на 5 ГБ SSD
    if (( DISK_TOTAL_GB <= 7 )); then
        apt-get clean >/dev/null 2>&1
        rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Оптимизация и защита успешно применены!${NC}"
    free -h
    df -h /
}

clean_disk_now() {
    echo -e "${YELLOW}Экстренная очистка диска...${NC}"
    unlock_apt
    apt-get autoremove --purge -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
    journalctl --vacuum-size=5M >/dev/null 2>&1 || true
    if command -v docker &>/dev/null; then
        docker system prune -af --volumes=false || true
    fi
    rm -rf /tmp/* /var/tmp/* /var/cache/apt/archives/* /var/lib/apt/lists/* /var/log/*.gz /var/log/*.[0-9] 2>/dev/null || true
    echo -e "${GREEN}✓ Диск очищен:${NC}"
    df -h /
}

install_mikan_panel() {
    echo -e "${YELLOW}Скачивание и запуск официального инсталлятора Mikan Panel...${NC}"
    local tmp_installer
    tmp_installer=$(mktemp /tmp/mikan_install.XXXXXX.sh)
    curl -fsSL https://github.com/Miroshka000/mikan/releases/latest/download/install.sh -o "$tmp_installer"
    chmod +x "$tmp_installer"
    bash "$tmp_installer" "$@"
    rm -f "$tmp_installer"
}

# Чтение аргумента командной строки (если передан)
CHOICE="${1:-}"

if [[ -z "$CHOICE" ]]; then
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}  Mikan VPN: Setup, Low-RAM & Hardening Menu     ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo "1) Выполнить только оптимизацию (диск/zRAM/BBR/Fail2Ban)"
    echo "2) [МОСКВА - 20GB SAS] Установить основную Mikan Panel"
    echo "3) [ФИНЛЯНДИЯ - 5GB SSD] Подключить как Ноду (Join Node)"
    echo "4) Экстренно очистить диск прямо сейчас"
    echo "5) Выход"
    echo -ne "${YELLOW}Выберите действие [1-5]: ${NC}"
    read -r CHOICE
fi

CHOICE=$(echo "$CHOICE" | tr -d '\r' | xargs)

case "$CHOICE" in
    1)
        apply_optimizations
        ;;
    2)
        apply_optimizations
        install_mikan_panel
        ;;
    3)
        apply_optimizations
        JOIN_KEY="${2:-}"
        if [[ -z "$JOIN_KEY" ]]; then
            echo -ne "${YELLOW}Вставьте ключ или команду подключения из панели: ${NC}"
            read -r JOIN_KEY
        fi

        if [[ -z "$JOIN_KEY" ]]; then
            echo -e "${RED}Ошибка: ключ не может быть пустым!${NC}"
            exit 1
        fi

        echo -e "${YELLOW}Подключение ноды...${NC}"
        if [[ "$JOIN_KEY" =~ "install.sh" ]]; then
            eval "$JOIN_KEY"
        else
            install_mikan_panel --join "$JOIN_KEY"
        fi
        ;;
    4)
        clean_disk_now
        ;;
    5)
        exit 0
        ;;
    *)
        echo -e "${RED}Неверный пункт: '$CHOICE'${NC}"
        exit 1
        ;;
esac
