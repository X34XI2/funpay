#!/bin/bash
# uninstall-fpc.sh - удаление FPC / Cardinal с сервера (Ubuntu / Debian).
#
# Использование:
#   sudo ./uninstall-fpc.sh <username>              # обычное удаление (спросит подтверждение)
#   sudo ./uninstall-fpc.sh <username> --yes        # без вопросов (для автоматизации)
#   sudo ./uninstall-fpc.sh <username> --purge-user # + удалить самого пользователя (userdel -r)
#   sudo ./uninstall-fpc.sh <username> --keep-configs # не удалять резервную копию конфигов
#
# Что удаляется:
#   - сервис Funpay@<username> (stop, disable, симлинк/файл юнита)
#   - /home/<username>/Funpay      (код, configs/, logs/, plugins/, storage/)
#   - /home/<username>/pyvenv      (виртуальное окружение)
#   - /home/<username>/fpc-install (хвосты установщика)
# Опционально (--purge-user): сам пользователь вместе с /home/<username>.
#
# Что НЕ удаляется намеренно:
#   - apt-пакеты (python3.11/3.12, curl, unzip, locales) - они общесистемные
#   - репозиторий deadsnakes - сообщим, но удалять не будем (вдруг нужен не только FPC)
#   - docker-контейнеры - если ставил через docker-compose, он подскажет команду
#
# ВАЖНО: перед удалением конфиги (/home/<username>/Funpay/configs) копируются в
#        /root/fpc-configs-backup-<username>-<дата>. Без них восстановление = полная
#        перенастройка бота (токен, пароль, golden_key, настройки FunPay).

set -u

RED='\033[1;91m'
CYAN='\033[1;96m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
RESET='\033[0m'

USERNAME=""
ASSUME_YES=0
PURGE_USER=0
KEEP_CONFIGS=0

# ---------- разбор аргументов ----------
for arg in "$@"; do
  case "$arg" in
    --yes|-y)        ASSUME_YES=1 ;;
    --purge-user)    PURGE_USER=1 ;;
    --keep-configs)  KEEP_CONFIGS=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo -e "${RED}Неизвестный параметр: $arg${RESET}"
      exit 2
      ;;
    *)
      if [ -n "$USERNAME" ]; then
        echo -e "${RED}Указано больше одного имени пользователя.${RESET}"
        exit 2
      fi
      USERNAME="$arg"
      ;;
  esac
done

# ---------- проверки ----------
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Запусти скрипт от root (sudo ./uninstall-fpc.sh <username>).${RESET}"
  exit 1
fi

if [ -z "$USERNAME" ]; then
  echo -e "${RED}Не указано имя пользователя.${RESET}"
  echo -e "${CYAN}Пример: sudo ./uninstall-fpc.sh jopa${RESET}"
  echo -e "${CYAN}Посмотреть установленные инстансы: systemctl list-units 'Funpay@*'${RESET}"
  exit 2
fi

# Защита от rm -rf по пустому/подозрительному пути.
if [[ ! "$USERNAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
  echo -e "${RED}Недопустимое имя пользователя: '$USERNAME'.${RESET}"
  exit 2
fi

HOME_DIR="/home/$USERNAME"
BOT_DIR="$HOME_DIR/Funpay"
VENV_DIR="$HOME_DIR/pyvenv"
INSTALL_DIR="$HOME_DIR/fpc-install"
SERVICE="Funpay@$USERNAME.service"

echo -e "${CYAN}################################################################################"
echo -e "Удаление FPC / Cardinal"
echo -e "Пользователь: $USERNAME"
echo -e "Каталог бота: $BOT_DIR"
echo -e "Сервис:       $SERVICE"
if [ "$PURGE_USER" -eq 1 ]; then
  echo -e "${RED}ВНИМАНИЕ: пользователь $USERNAME будет удалён вместе с $HOME_DIR${RESET}"
fi
echo -e "################################################################################${RESET}"

if [ ! -d "$BOT_DIR" ] && [ ! -f "/etc/systemd/system/$SERVICE" ]; then
  echo -e "${YELLOW}Похоже, FPC для пользователя '$USERNAME' не установлен (нет $BOT_DIR и нет юнита).${RESET}"
  echo -e "${CYAN}Проверь имя пользователя. Список каталогов: ls -1 /home/${RESET}"
  exit 3
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  echo -ne "\n${CYAN}Продолжить удаление? [y/n]: ${RESET}"
  read -r confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) echo -e "${CYAN}Отменено, ничего не тронуто.${RESET}"; exit 0 ;;
  esac
fi

# ---------- бэкап конфигов ----------
CONFIG_SRC="$BOT_DIR/configs"
if [ -d "$CONFIG_SRC" ]; then
  BACKUP_DIR="/root/fpc-configs-backup-$USERNAME-$(date +%Y%m%d-%H%M%S)"
  if cp -r "$CONFIG_SRC" "$BACKUP_DIR"; then
    chmod -R go-rwx "$BACKUP_DIR"
    echo -e "${GREEN}Конфиги сохранены: $BACKUP_DIR${RESET}"
    echo -e "${CYAN}Токен бота и ключи FunPay лежат там в открытом виде - убери в надёжное место и удали копию, когда не нужна.${RESET}"
  else
    echo -e "${RED}Не удалось сохранить конфиги.${RESET}"
    if [ "$ASSUME_YES" -ne 1 ]; then
      echo -ne "${CYAN}Продолжить удаление без бэкапа? [y/n]: ${RESET}"
      read -r cont
      case "$cont" in
        [yY]|[yY][eE][sS]) ;;
        *) echo -e "${CYAN}Отменено.${RESET}"; exit 0 ;;
      esac
    fi
  fi
else
  echo -e "${YELLOW}Каталог конфигов не найден ($CONFIG_SRC) - бэкапить нечего.${RESET}"
fi

# ---------- остановка сервиса ----------
if systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE"; then
  echo -e "${CYAN}Останавливаю и отключаю $SERVICE...${RESET}"
  systemctl stop "$SERVICE"    2>/dev/null || echo -e "${YELLOW}  stop вернул ошибку (возможно, уже остановлен).${RESET}"
  systemctl disable "$SERVICE" 2>/dev/null || true
else
  echo -e "${CYAN}Юнит $SERVICE в systemd не зарегистрирован, пропускаю stop/disable.${RESET}"
fi

# Запущенные вручную процессы (на случай, если бот поднят не через сервис).
if pgrep -f "$BOT_DIR/main.py" >/dev/null 2>&1; then
  echo -e "${YELLOW}Нашёл запущенные вручную процессы бота - останавливаю.${RESET}"
  pkill -f "$BOT_DIR/main.py" || true
  sleep 1
  pkill -9 -f "$BOT_DIR/main.py" 2>/dev/null || true
fi

# ---------- удаление файлов юнита ----------
# install-fpc.sh делает симлинк; если юнит копировали руками - тоже уберём.
if [ -L "/etc/systemd/system/$SERVICE" ] || [ -f "/etc/systemd/system/$SERVICE" ]; then
  rm -f "/etc/systemd/system/$SERVICE"
  echo -e "${GREEN}Юнит /etc/systemd/system/$SERVICE удалён.${RESET}"
fi
systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

# ---------- удаление каталогов ----------
for dir in "$BOT_DIR" "$VENV_DIR" "$INSTALL_DIR"; do
  if [ -d "$dir" ] && [ "$dir" != "/home" ] && [ -n "$dir" ]; then
    echo -e "${CYAN}Удаляю $dir...${RESET}"
    rm -rf -- "$dir"
    if [ -d "$dir" ]; then
      echo -e "${RED}Не удалось удалить $dir${RESET}"
    fi
  fi
done

# ---------- удаление пользователя (опционально) ----------
if [ "$PURGE_USER" -eq 1 ]; then
  if id "$USERNAME" >/dev/null 2>&1; then
    if pgrep -u "$USERNAME" >/dev/null 2>&1; then
      echo -e "${YELLOW}У пользователя $USERNAME ещё есть процессы - завершаю их.${RESET}"
      pkill -u "$USERNAME" || true
      sleep 1
      pkill -9 -u "$USERNAME" 2>/dev/null || true
    fi
    echo -e "${RED}Удаляю пользователя $USERNAME вместе с $HOME_DIR...${RESET}"
    userdel -r "$USERNAME" 2>/dev/null || {
      echo -e "${YELLOW}userdel -r не сработал (возможно, каталог уже удалён), пробую без -r.${RESET}"
      userdel "$USERNAME" || echo -e "${RED}Не удалось удалить пользователя - сделай это вручную: userdel -r $USERNAME${RESET}"
    }
  else
    echo -e "${CYAN}Пользователя $USERNAME в системе нет, пропускаю.${RESET}"
  fi
fi

# ---------- что осталось ----------
echo -e "\n${CYAN}################################################################################"
echo -e "${GREEN}FPC для '$USERNAME' удалён.${RESET}"
echo -e "################################################################################${RESET}"

if [ -d /home/$USERNAME/pyvenv ] || [ -d /home/$USERNAME/Funpay ]; then
  echo -e "${YELLOW}Остались каталоги в $HOME_DIR - проверь права (кто владелец) и удали вручную.${RESET}"
fi

echo -e "\n${CYAN}Осталось на машине (намеренно не тронуто):${RESET}"
echo -e "  - apt-пакеты: python3.11/3.12, curl, unzip, locales - общесистемные"
if ls /etc/apt/sources.list.d/*deadsnakes* >/dev/null 2>&1 || [ -f /etc/apt/preferences.d/10deadsnakes-ppa ]; then
  echo -e "  - репозиторий deadsnakes, если он больше не нужен:"
  echo -e "      sudo rm -f /etc/apt/sources.list.d/*deadsnakes* /etc/apt/preferences.d/10deadsnakes-ppa"
  echo -e "      sudo apt update"
fi
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi -E 'fpc|funpay|cardinal'; then
  echo -e "  - найден docker-контейнер с похожим именем. Если ставил через docker-compose:"
  echo -e "      cd <каталог с docker-compose.yml> && sudo docker compose down -v"
fi
if [ "$KEEP_CONFIGS" -eq 0 ]; then
  echo -e "  - бэкап конфигов в /root/fpc-configs-backup-$USERNAME-* (код для удаления когда не нужен):"
  echo -e "      sudo rm -rf /root/fpc-configs-backup-$USERNAME-*"
fi

echo -e "\n${CYAN}Логи, если что-то пошло не так:${RESET}"
echo -e "  sudo journalctl -u $SERVICE -n100 --no-pager"
