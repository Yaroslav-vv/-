#!/bin/bash
# catch_ampere.sh — Стабилизированная версия (уведомления по email)
#
# Коды выхода:
#   0   — нет мест / временная ошибка → продолжаем попытки
#   1   — критическая ошибка (auth, ключи) → воркфлоу останавливается
#   100 — инстанс создан → воркфлоу останавливается

set -o pipefail

# ─── Конфигурация ─────────────────────────────────────────────────────────────
export OCI_CLI_CONFIG_FILE="$HOME/.oci/config"
KEY_PATH="$HOME/.oci/ampere_key"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EMAIL_SCRIPT="$SCRIPT_DIR/send_email.py"
# ──────────────────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Отправка email.
# Аргументы: <subject> <body> [attach_path]
# Тело письма передаётся через stdin в Python-скрипт.
# При полном провале SMTP — ключ выводится в лог GitHub Actions.
email_send() {
    local subject="$1"
    local body="$2"
    local attach="${3:-}"

    # Проверяем наличие Python-скрипта (защита от случайного запуска без checkout)
    if [ ! -f "$EMAIL_SCRIPT" ]; then
        log "❌ Скрипт $EMAIL_SCRIPT не найден! Убедись, что он лежит рядом с catch_ampere.sh."
        return 1
    fi

    local args=("--subject" "$subject")
    [ -n "$attach" ] && args+=("--attach" "$attach")

    echo "$body" | python3 "$EMAIL_SCRIPT" "${args[@]}"
    local rc=$?

    # Если email с ключом не ушёл — выводим ключ в лог как последний резерв
    if [ $rc -ne 0 ] && [ -n "$attach" ] && [ -f "$attach" ]; then
        log "🆘 Email не отправлен. РЕЗЕРВНЫЙ ВЫВОД КЛЮЧА В ЛОГ GitHub Actions:"
        echo "━━━━━━━━━━━━ PRIVATE KEY START ━━━━━━━━━━━━"
        cat "$attach"
        echo "━━━━━━━━━━━━  PRIVATE KEY END  ━━━━━━━━━━━━"
        log "⬆️  Скопируй ключ из логов Actions вручную!"
    fi

    return $rc
}

# ─── Основная логика ───────────────────────────────────────────────────────────

log "══════════════════════════════════════════════════"
log " ПОПЫТКА СОЗДАНИЯ AMPERE A1 [$(date -u '+%Y-%m-%d %H:%M:%S UTC')]"
log "══════════════════════════════════════════════════"

# 1. Генерация свежей пары SSH-ключей (ed25519)
rm -f "$KEY_PATH" "${KEY_PATH}.pub"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q 2>&1

if [[ ! -f "$KEY_PATH" ]] || [[ ! -f "${KEY_PATH}.pub" ]]; then
    log "❌ КРИТИЧНО: SSH-ключи не сгенерированы!"
    exit 1
fi
log "🔑 SSH-ключи (ed25519) сгенерированы"

# 2. Вызов OCI API с жёстким таймаутом 90 сек
DISPLAY_NAME="Ampere-$(date '+%Y%m%d-%H%M%S')"
log "🚀 OCI запрос → создаём '$DISPLAY_NAME' ..."

RESPONSE=$(timeout 20 oci compute instance launch \
    --compartment-id       "$OCI_COMPARTMENT_ID" \
    --availability-domain  "$OCI_AVAILABILITY_DOMAIN" \
    --shape                "VM.Standard.A1.Flex" \
    --shape-config         '{"ocpus":1,"memoryInGBs":6}' \
    --subnet-id            "$OCI_SUBNET_ID" \
    --image-id             "$OCI_IMAGE_ID" \
    --ssh-authorized-keys-file "${KEY_PATH}.pub" \
    --display-name         "$DISPLAY_NAME" \
    --output               json 2>&1)
OCI_RC=$?

# 3. Разбор результата ─────────────────────────────────────────────────────────

if [ $OCI_RC -eq 124 ]; then
    log "⏰ OCI API не ответил за 90 сек (таймаут) — пропускаем итерацию."
    exit 0
fi

if [ $OCI_RC -eq 0 ]; then
    # ✅ УСПЕХ — инстанс создан
    INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.data.id // "N/A"' 2>/dev/null || echo "N/A")
    CREATED_AT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    PUB_KEY=$(cat "${KEY_PATH}.pub")
    log "✅ ИНСТАНС СОЗДАН! OCID: $INSTANCE_ID"

    # Формируем тело письма (plain text — надёжнее HTML для важных писем)
    EMAIL_BODY="$(cat << EOF
AMPERE A1 УСПЕШНО СОЗДАН!
══════════════════════════════════════════════

  Инстанс : $DISPLAY_NAME
  OCID    : $INSTANCE_ID
  Создан  : $CREATED_AT

══════════════════════════════════════════════
КАК ПОДКЛЮЧИТЬСЯ
══════════════════════════════════════════════

  ssh -i ampere_key ubuntu@<IP-адрес>

  Приватный SSH-ключ прикреплён к этому письму.
  Сохрани его в безопасное место!

  IP-адрес смотри в панели Oracle Cloud:
  https://cloud.oracle.com/compute/instances

══════════════════════════════════════════════
ПУБЛИЧНЫЙ КЛЮЧ (для справки)
══════════════════════════════════════════════

$PUB_KEY

══════════════════════════════════════════════
Oracle Ampere Catcher | GitHub Actions
EOF
)"

    email_send \
        "✅ Ampere A1 пойман! | $DISPLAY_NAME" \
        "$EMAIL_BODY" \
        "$KEY_PATH"

    exit 100   # ← сигнал для YAML: стоп, инстанс пойман

fi

# ─── Обработка ошибок OCI ────────────────────────────────────────────────────

if echo "$RESPONSE" | grep -qi "Out of host capacity"; then
    # Ожидаемо — мест нет, продолжаем
    log "⏳ Нет мест (Out of host capacity) — ждём следующей итерации."
    exit 0

elif echo "$RESPONSE" | grep -qi "LimitExceeded\|maximum.*instance\|already.*exist"; then
    log "🛑 Достигнут лимит инстансов или дубликат!"
    email_send \
        "🛑 Oracle: лимит инстансов или дубликат" \
        "$(cat << EOF
Воркфлоу остановлен автоматически.

Причина: инстанс с таким именем уже существует,
         или достигнут лимит Free Tier.

Действие: зайди в панель Oracle Cloud и проверь список инстансов.
Если инстанс есть — всё хорошо, можно отключить Actions.
Если нет — удали старый и перезапусти вручную.

  https://cloud.oracle.com/compute/instances

──────────────────────────────────────
Инстанс : $DISPLAY_NAME
Время   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
)"
    exit 100   # нет смысла повторять

elif echo "$RESPONSE" | grep -qi "NotAuthenticated\|InvalidCredentials\|NotAuthorized\|Unauthorized\|Forbidden\|401\|403"; then
    log "🚨 Ошибка авторизации OCI! Проверь секреты GitHub."
    SNIPPET="${RESPONSE:0:600}"
    email_send \
        "🚨 Ошибка авторизации OCI — требуется действие" \
        "$(cat << EOF
Воркфлоу остановлен из-за ошибки авторизации.

Что делать:
  1. Проверь секреты GitHub Actions (Settings → Secrets):
       OCI_USER_ID, OCI_FINGERPRINT, OCI_TENANCY_ID,
       OCI_REGION, OCI_API_KEY_PRIVATE
  2. Убедись, что API-ключ не истёк и не отозван в Oracle.
  3. После исправления перезапусти воркфлоу вручную.

──────────────────────────────────────
Ответ OCI API:
$SNIPPET
──────────────────────────────────────
Время: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
)"
    exit 1     # критично → воркфлоу останавливается с ошибкой

else
    # Неизвестная ошибка — логируем и продолжаем попытки
    SNIPPET="${RESPONSE:0:600}"
    log "❓ Неизвестная ошибка OCI (код $OCI_RC):"
    log "$RESPONSE"
    email_send \
        "⚠️ Неизвестная ошибка OCI (код $OCI_RC)" \
        "$(cat << EOF
Попытка создания инстанса завершилась неизвестной ошибкой.
Скрипт продолжит попытки в следующем цикле.

──────────────────────────────────────
Инстанс : $DISPLAY_NAME
Код     : $OCI_RC
Время   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Ответ OCI API:
$SNIPPET
EOF
)"
    exit 0
fi
