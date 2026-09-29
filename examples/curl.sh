#!/usr/bin/env bash
# Platform22 Signals API: открытие, долив и закрытие позиции на curl.
#
#   PF22_TOKEN="тестовый-токен" STRATEGY_ID=6 ./examples/curl.sh
#
# Для боевого контура: PF22_BASE_URL=https://api.platform22.pro и боевой токен.
set -euo pipefail

BASE_URL="${PF22_BASE_URL:-https://api-dev.pf22.ru}"
: "${PF22_TOKEN:?задайте PF22_TOKEN}"
: "${STRATEGY_ID:?задайте STRATEGY_ID}"

send() {  # send <open|close> <json>
  curl -sS -X POST "$BASE_URL/partner/v1/positions/$1" \
    -H "Authorization: Bearer $PF22_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2"
  echo
}

# 1. Открытие
send open '{
  "strategy_id": '"$STRATEGY_ID"',
  "ticker": "BTCUSDT",
  "direction": "long",
  "open_price": "65000.00",
  "quantity": "1",
  "open_signal_id": 100000001,
  "timeframe": 240
}'

# 2. Долив: тот же тикер, averaging: true и новый open_signal_id
send open '{
  "strategy_id": '"$STRATEGY_ID"',
  "ticker": "BTCUSDT",
  "direction": "long",
  "open_price": "64000.00",
  "quantity": "1",
  "averaging": true,
  "open_signal_id": 100000002
}'

# 3. Закрытие — целиком, по паре strategy_id + ticker
send close '{
  "strategy_id": '"$STRATEGY_ID"',
  "ticker": "BTCUSDT",
  "close_price": "66200.00",
  "close_signal_id": 100000003
}'
