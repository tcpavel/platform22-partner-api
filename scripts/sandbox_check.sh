#!/usr/bin/env bash
# Проверка интеграции с Platform22 Signals API в песочнице.
#
# Проходит весь жизненный цикл позиции и сверяет каждый ответ с ожидаемым:
# 403 без токена → opened → повтор (duplicate) → долив (averaged) → повтор
# долива (duplicate) → обратное направление (direction_mismatch) → closed →
# повторный close (no_open_position) → невалидное тело (400).
#
# Использование:
#   PF22_TOKEN="тестовый-токен" ./scripts/sandbox_check.sh <strategy_id>
#
# Переменные окружения:
#   PF22_TOKEN     токен (обязательно)
#   PF22_BASE_URL  по умолчанию https://api-dev.pf22.ru (песочница)
#   PF22_TICKER    по умолчанию SANDBOXUSDT — служебный тикер, чтобы не мешать
#                  вашим тестовым позициям
#
# Нужны: bash, curl, python3 (для разбора JSON).
set -euo pipefail

STRATEGY_ID="${1:-}"
BASE_URL="${PF22_BASE_URL:-https://api-dev.pf22.ru}"
TICKER="${PF22_TICKER:-SANDBOXUSDT}"
TOKEN="${PF22_TOKEN:-}"

if [[ -z "$STRATEGY_ID" || -z "$TOKEN" ]]; then
  echo "Использование: PF22_TOKEN=<токен> $0 <strategy_id>" >&2
  exit 2
fi
if [[ "$BASE_URL" == *"api.platform22.pro"* ]]; then
  echo "Это боевой контур. Скрипт рассчитан на песочницу: он открывает и закрывает позиции." >&2
  echo "Если вы точно понимаете, что делаете, задайте PF22_ALLOW_PROD=1." >&2
  [[ "${PF22_ALLOW_PROD:-}" == "1" ]] || exit 2
fi

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; D=; N=; fi
PASS=0; FAIL=0
RUN_ID=$(( $(date +%s) * 1000 ))   # уникальные open_signal_id на каждый прогон

# post <path> <json> [token] → печатает "<http_code> <body>"
post() {
  local path="$1" body="$2" token="${3-$TOKEN}"
  local auth=()
  [[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")
  curl -sS -m 30 -o /tmp/pf22_body.$$ -w '%{http_code}' -X POST "$BASE_URL$path" \
    ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' -d "$body"
  printf ' '; cat /tmp/pf22_body.$$
}

field() {  # field <json> <key>
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]) or "")' "$1" "$2" 2>/dev/null || true
}

check() {  # check <n> <title> <response> <code> [result] [reason]
  local n="$1" title="$2" resp="$3" want_code="$4" want_result="${5:-}" want_reason="${6:-}"
  local code="${resp%% *}" body="${resp#* }"
  local ok=1
  [[ "$code" == "$want_code" ]] || ok=0
  [[ -z "$want_result" || "$(field "$body" result)" == "$want_result" ]] || ok=0
  [[ -z "$want_reason" || "$(field "$body" reason)" == "$want_reason" ]] || ok=0
  if (( ok )); then
    PASS=$((PASS + 1)); printf '%s✔%s %s. %s %s→ %s %s%s\n' "$G" "$N" "$n" "$title" "$D" "$code" "$body" "$N"
  else
    FAIL=$((FAIL + 1)); printf '%s✘ %s. %s%s\n    ожидалось: %s %s %s\n    получено:  %s %s\n' \
      "$R" "$n" "$title" "$N" "$want_code" "$want_result" "$want_reason" "$code" "$body"
  fi
}

open_body() {  # open_body <direction> <price> <signal_id> [averaging]
  local avg=""
  [[ "${4:-}" == "true" ]] && avg=', "averaging": true'
  printf '{"strategy_id": %s, "ticker": "%s", "direction": "%s", "open_price": "%s", "quantity": "1", "open_signal_id": %s%s}' \
    "$STRATEGY_ID" "$TICKER" "$1" "$2" "$3" "$avg"
}
CLOSE_BODY=$(printf '{"strategy_id": %s, "ticker": "%s", "close_price": "110"}' "$STRATEGY_ID" "$TICKER")

echo "Platform22 Signals API — проверка песочницы"
echo "${D}$BASE_URL · strategy_id=$STRATEGY_ID · ticker=$TICKER${N}"
echo

# Если прошлый прогон оборвался, позиция могла остаться открытой — закрываем.
pre=$(post /partner/v1/positions/close "$CLOSE_BODY")
case "${pre%% *}" in
  200) [[ "$(field "${pre#* }" result)" == "closed" ]] && echo "${D}Закрыта позиция, оставшаяся от прошлого прогона.${N}" ;;
  403) echo "${R}403: токен не принят. Проверьте PF22_TOKEN и контур (тестовый токен работает только в песочнице).${N}"; exit 1 ;;
  400) echo "${R}400: ${pre#* }${N}"; echo "Проверьте strategy_id: он должен быть привязан к вашему токену."; exit 1 ;;
esac

check 1 "Запрос без токена" \
  "$(post /partner/v1/positions/open "$(open_body long 100 $((RUN_ID + 1)))" '')" 403
check 2 "Открытие" \
  "$(post /partner/v1/positions/open "$(open_body long 100 $((RUN_ID + 1)))")" 200 opened
check 3 "Повтор открытия" \
  "$(post /partner/v1/positions/open "$(open_body long 100 $((RUN_ID + 1)))")" 200 duplicate_ignored position_already_open
check 4 "Долив (averaging: true)" \
  "$(post /partner/v1/positions/open "$(open_body long 90 $((RUN_ID + 2)) true)")" 200 averaged
check 5 "Повтор долива" \
  "$(post /partner/v1/positions/open "$(open_body long 90 $((RUN_ID + 2)) true)")" 200 duplicate_ignored same_open_signal_id
check 6 "Открытие в обратную сторону" \
  "$(post /partner/v1/positions/open "$(open_body short 95 $((RUN_ID + 3)))")" 200 direction_mismatch
check 7 "Закрытие" \
  "$(post /partner/v1/positions/close "$CLOSE_BODY")" 200 closed
check 8 "Повтор закрытия" \
  "$(post /partner/v1/positions/close "$CLOSE_BODY")" 200 no_open_position
check 9 "Невалидное тело (direction: up)" \
  "$(post /partner/v1/positions/open "$(open_body up 100 $((RUN_ID + 4)))")" 400

rm -f /tmp/pf22_body.$$
echo
if (( FAIL == 0 )); then
  echo "${G}Все проверки пройдены: $PASS из $PASS.${N}"
else
  echo "${R}Не пройдено: $FAIL из $((PASS + FAIL)).${N}"
  exit 1
fi
