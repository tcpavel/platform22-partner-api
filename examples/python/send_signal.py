"""Клиент Platform22 Signals API с повтором при сбоях.

    pip install requests
    PF22_TOKEN=... python send_signal.py

Повтор безопасен: сервер отбрасывает повторный сигнал как `duplicate_ignored`,
поэтому при таймауте, 429 или 5xx тот же сигнал отправляется ещё раз. Ответы
200 (при любом `result`), 400 и 403 не повторяются.
"""
import os
import time

import requests

SANDBOX_URL = "https://api-dev.pf22.ru"
PROD_URL = "https://api.platform22.pro"

RETRY_STATUSES = {429, 500, 502, 503, 504}
DESYNC_RESULTS = {"direction_mismatch", "no_open_position"}


class SignalRejected(Exception):
    """400/403: повтор не поможет — нужно исправить запрос или токен."""


class Platform22Signals:
    def __init__(self, token, base_url=SANDBOX_URL, timeout=15, max_attempts=5):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.max_attempts = max_attempts
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })

    def open(self, strategy_id, ticker, direction, price, quantity="1",
             signal_id=None, averaging=False, **extra):
        body = {
            "strategy_id": strategy_id,
            "ticker": ticker,
            "direction": direction,
            "open_price": str(price),
            "quantity": str(quantity),
            **extra,
        }
        if signal_id is not None:
            body["open_signal_id"] = signal_id
        if averaging:
            body["averaging"] = True
        return self._send("open", body)

    def close(self, strategy_id, ticker, price, signal_id=None, **extra):
        body = {"strategy_id": strategy_id, "ticker": ticker,
                "close_price": str(price), **extra}
        if signal_id is not None:
            body["close_signal_id"] = signal_id
        return self._send("close", body)

    def _send(self, action, body):
        url = f"{self.base_url}/partner/v1/positions/{action}"
        delay = 1
        for attempt in range(1, self.max_attempts + 1):
            try:
                resp = self.session.post(url, json=body, timeout=self.timeout)
            except requests.RequestException:
                resp = None  # таймаут или обрыв: сигнал мог дойти, но повтор безопасен
            if resp is not None and resp.status_code == 200:
                data = resp.json()
                if data.get("result") in DESYNC_RESULTS:
                    # Рассинхрон с платформой — повод для алерта, не для повтора.
                    print(f"ALERT: {action} {body['ticker']}: {data}")
                return data
            if resp is not None and resp.status_code not in RETRY_STATUSES:
                raise SignalRejected(f"{resp.status_code}: {resp.text}")
            if attempt < self.max_attempts:
                retry_after = resp.headers.get("Retry-After") if resp is not None else None
                time.sleep(int(retry_after) if retry_after and retry_after.isdigit() else delay)
                delay = min(delay * 2, 30)
        raise ConnectionError(f"{action}: нет ответа после {self.max_attempts} попыток")


if __name__ == "__main__":
    api = Platform22Signals(os.environ["PF22_TOKEN"],
                            base_url=os.environ.get("PF22_BASE_URL", SANDBOX_URL))
    strategy_id = int(os.environ.get("STRATEGY_ID", "6"))

    print(api.open(strategy_id, "BTCUSDT", "long", "65000.00", signal_id=100000001))
    print(api.open(strategy_id, "BTCUSDT", "long", "64000.00", signal_id=100000002, averaging=True))
    print(api.close(strategy_id, "BTCUSDT", "66200.00", signal_id=100000003))
