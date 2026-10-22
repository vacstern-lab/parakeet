#!/usr/bin/env bash
# ==============================================================================
# Универсальный скрипт оптимизации и развертывания Mikan (Ubuntu 24.04 / Debian 12)
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: запустите скрипт от root (sudo bash $0)${NC}"
   exit 1
fi

apply_optimizations() {
    echo -e "${BLUE}=== 1. Очистка и установка базовых утилит ===${NC}"
    apt-get update -y
    apt-get install -y curl wget jq ufw zram-tools ca-certificates gnupg lsb-release

    echo -e "${BLUE}=== 2. Настройка zRAM (экономим диск, расширяем RAM) ===${NC}"
    # Вместо swapfile на 5GB SSD используем сжатую память в RAM
    cat <<EOF > /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    systemctl restart zramswap 2>/dev/null || true

    echo -e "${BLUE}=== 3. Жесткое урезание логов Journald ===${NC}"
    mkdir -p /etc/systemd/journald.conf.d/
    cat <<EOF > /etc/systemd/journald.conf.d/low-disk.conf
[Journal]
SystemMaxUse=30M
SystemKeepFree=100M
RuntimeMaxUse=15M
MaxRetentionSec=2day
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald
    journalctl --vacuum-size=30M >/dev/null 2>&1 || true

    echo -e "${BLUE}=== 4. Ограничение логов Docker ===${NC}"
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        # Обновляем существующий json
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

    echo -e "${BLUE}=== 5. Настройка BBR и TCP тюнинг ===${NC}"
    cat <<EOF > /etc/sysctl.d/99-vpn-tuning.conf
# Включение BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Защита от SYN флуда и сетевой стек
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Экономия памяти
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl --system >/dev/null 2>&1

    echo -e "${BLUE}=== 6. Создание автоочистки по крону ===${NC}"
    cat <<'EOF' > /etc/cron.daily/disk-cleaner
#!/bin/bash
journalctl --vacuum-size=25M >/dev/null 2>&1
journalctl --vacuum-time=2d >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
rm -rf /var/cache/apt/archives/* >/dev/null 2>&1
if command -v docker &>/dev/null; then
    docker system prune -f --filter "until=72h" >/dev/null 2>&1
fi
EOF
    chmod +x /etc/cron.daily/disk-cleaner

    echo -e "${BLUE}=== 7. Базовая безопасность (UFW) ===${NC}"
    # Открываем SSH, чтобы не потерять доступ
    SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
    SSH_PORT=${SSH_PORT:-22}
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 443/udp comment 'QUIC/Hysteria'
    # Открываем диапазон для возможных протоколов VPN
    ufw allow 10000:65000/tcp comment 'VPN Dynamic Range TCP'
    ufw allow 10000:65000/udp comment 'VPN Dynamic Range UDP'
    echo "y" | ufw enable

    echo -e "${GREEN}✓ Система оптимизирована! Диск защищен от переполнения логами.${NC}"
}

clean_disk_now() {
    echo -e "${YELLOW}Очищаем диск прямо сейчас...${NC}"
    apt-get clean
    apt-get autoremove -y
    journalctl --vacuum-size=10M
    if command -v docker &>/dev/null; then
        docker system prune -af --volumes=false
    fi
    rm -rf /tmp/* /var/tmp/* /var/cache/apt/archives/*
    df -h /
}

# ----------------- Меню -----------------
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}  Mikan VPN: Setup & Hardening Menu  ${NC}"
echo -e "${GREEN}=====================================${NC}"
echo "1) Выполнить оптимизацию диска/памяти/сети (ОБЯЗАТЕЛЬНО для обоих)"
echo "2) [МОСКВА] Установить основную Mikan Panel"
echo "3) [ФИНЛЯНДИЯ] Подключить как Ноду (Join Node)"
echo "4) Экстренно очистить диск прямо сейчас"
echo "5) Выход"
echo -n "Выберите действие [1-5]: "
read -r CHOICE

case $CHOICE in
    1)
        apply_optimizations
        ;;
    2)
        apply_optimizations
        echo -e "${YELLOW}Запуск официального установщика Mikan Panel...${NC}"
        curl -fsSL https://github.com/Miroshka000/mikan/releases/latest/download/install.sh | bash
        ;;
    3)
        apply_optimizations
        echo -n "Вставьте команду/ключ подключения из панели Mikan (или параметр --join KEY): "
        read -r JOIN_KEY
        if [[ -z "$JOIN_KEY" ]]; then
            echo -e "${RED}Ключ не может быть пустым!${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Подключение ноды...${NC}"
        if [[ "$JOIN_KEY" =~ "install.sh" ]]; then
            eval "$JOIN_KEY"
        else
            curl -fsSL https://github.com/Miroshka000/mikan/releases/latest/download/install.sh | bash -s -- --join "$JOIN_KEY"
        fi
        ;;
    4)
        clean_disk_now
        ;;
    5)
        exit 0
        ;;
    *)
        echo -e "${RED}Неверный пункт!${NC}"
        ;;
esac
