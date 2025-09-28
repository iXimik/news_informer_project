#!/usr/bin/env bash
set -euo pipefail

# ── Константы ──────────────────────────────────────────────────────────────────
APP_DIR="$HOME/nix2/news_informer2"
ENV_DIR="$APP_DIR/venv"
PY_SCRIPT="$APP_DIR/news_informer.py"
LOG_FILE="$APP_DIR/news_informer.log"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/news_informer.service"

# IP вашего ESP32 (можно переопределить переменной окружения перед запуском)
: "${ESP32_IP:=192.168.1.235}"

echo "▶️ Создание каталогов…"
mkdir -p "$APP_DIR" "$SERVICE_DIR"

echo "🐍 Создание виртуального окружения…"
python3 -m venv "$ENV_DIR"
# shellcheck source=/dev/null
source "$ENV_DIR/bin/activate"

echo "📦 Установка зависимостей…"
pip install --upgrade pip
pip install "urllib3==2.*" requests feedparser beautifulsoup4 sdnotify

echo "📄 Создание Python-скрипта: $PY_SCRIPT"
cat > "$PY_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import sys, os, time, random, re, gc, logging, threading, signal
from logging.handlers import RotatingFileHandler

import requests, feedparser
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# sdnotify для интеграции с systemd (READY/WATCHDOG)
try:
    from sdnotify import SystemdNotifier
except Exception:
    class _Dummy:
        def notify(self, *_a, **_kw): pass
    SystemdNotifier = _Dummy  # type: ignore

# ── Конфиг ─────────────────────────────────────────────────────────────────────
APP_DIR   = os.path.dirname(os.path.abspath(__file__))
LOG_FILE  = os.environ.get("NI_LOG_FILE", os.path.join(APP_DIR, "news_informer.log"))
ESP32_IP  = os.environ.get("ESP32_IP", "192.168.1.235")

WATCHDOG_PERIOD        = 15           # сек, пинг systemd
SESSION_REFRESH_EVERY  = 3600         # сек, пересоздавать HTTP-сессию
SEND_COOLDOWN_FAILS    = 10           # подряд неудачных отправок -> «передышка»
SEND_COOLDOWN_SECS     = 60           # сек «передышки» после серии неудач
PARSE_PERIOD           = 180          # сек, шаг парсинга источников
SEND_PERIOD            = 20           # сек, шаг отправки

RSS_SOURCES = [
    {"url": "https://tass.ru/rss/v2.xml",                     "name": "ТАСС",        "lang": "ru"},
    {"url": "https://ria.ru/export/rss2/index.xml",           "name": "РИА",         "lang": "ru"},
    {"url": "https://www.vesti.ru/vesti.rss",                 "name": "Вести",       "lang": "ru"},
    {"url": "https://lenta.ru/rss",                           "name": "Лента",       "lang": "ru"},
    {"url": "https://www.interfax.ru/rss.asp",                "name": "Интерфакс",   "lang": "ru"},
    {"url": "https://www.kommersant.ru/RSS/news.xml",         "name": "Коммерсант",  "lang": "ru"},
    {"url": "https://rg.ru/rss/",                             "name": "РГ",          "lang": "ru"},
    {"url": "https://www.gazeta.ru/export/rss/lenta.xml",     "name": "Газета.ru",   "lang": "ru"},
    {"url": "https://rss.cnn.com/rss/edition.rss",            "name": "CNN",         "lang": "en"},
    {"url": "https://feeds.bbci.co.uk/news/rss.xml",          "name": "BBC",         "lang": "en"},
    {"url": "https://www.aljazeera.com/xml/rss/all.xml",      "name": "AlJazeera",   "lang": "en"},
    {"url": "https://www.theguardian.com/world/rss",          "name": "Guardian",    "lang": "en"},
    {"url": "https://www.nytimes.com/services/xml/rss/nyt/World.xml", "name":"NYT", "lang": "en"},
    {"url": "https://www.dw.com/rdf/rss-en-all",              "name": "DW",          "lang": "en"},
    {"url": "https://www.euronews.com/rss",                   "name": "Euronews",    "lang": "en"},
]

# ── Логирование: stdout (journald) + файл с ротацией ──────────────────────────
root = logging.getLogger()
root.setLevel(logging.INFO)
fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

sh = logging.StreamHandler(sys.stdout); sh.setFormatter(fmt); root.addHandler(sh)
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
fh = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=3); fh.setFormatter(fmt); root.addHandler(fh)
log = logging.getLogger("informer")

# ── Вспомогательные ───────────────────────────────────────────────────────────
def _clean(text: str) -> str:
    if not text: return ""
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"[^\w\sа-яА-ЯёЁA-Za-z0-9.,!?\-:;]", "", text)

# ── Класс демона ──────────────────────────────────────────────────────────────
class NewsInformer:
    def __init__(self):
        self.running = True
        self.stop_event = threading.Event()
        self.lock = threading.Lock()

        self.news_list = []
        self.sent_titles = set()
        self.idx = 0
        self.send_fail_streak = 0

        self.notifier = SystemdNotifier()
        self._mk_session()
        self.last_session_reset = time.time()

        # потоки
        threading.Thread(target=self._watchdog_thread, name="watchdog", daemon=True).start()
        threading.Thread(target=self._parse_loop,     name="parser",   daemon=True).start()
        threading.Thread(target=self._send_loop,      name="sender",   daemon=True).start()
        threading.Thread(target=self._heartbeat,      name="heartbeat",daemon=True).start()

        try: self.notifier.notify("READY=1")
        except Exception: pass

        log.info("initialized; sources=%d; ESP32=%s", len(RSS_SOURCES), ESP32_IP)

    # HTTP-сессия с ретраями/пулом
    def _mk_session(self):
        s = requests.Session()
        s.headers.update({"User-Agent":"news-informer/1.0"})
        retry = Retry(total=5, connect=5, read=5, backoff_factor=0.5,
                      status_forcelist=(429,500,502,503,504),
                      allowed_methods=frozenset(["GET","HEAD"]))
        ad = HTTPAdapter(max_retries=retry, pool_maxsize=20)
        s.mount("http://", ad); s.mount("https://", ad)
        self.session = s

    def _refresh_session_if_needed(self):
        if time.time() - self.last_session_reset > SESSION_REFRESH_EVERY:
            log.info("http session refresh")
            try: self.session.close()
            except Exception: pass
            self._mk_session()
            self.last_session_reset = time.time()
            gc.collect()

    # Диагностический «пульс»
    def _heartbeat(self):
        while self.running:
            th = [t.name for t in threading.enumerate()]
            log.info("heartbeat: threads=%s; news=%d; sent=%d",
                     th, len(self.news_list), len(self.sent_titles))
            self.stop_event.wait(30)

    # Watchdog для systemd
    def _watchdog_thread(self):
        while self.running:
            try: self.notifier.notify("WATCHDOG=1")
            except Exception: pass
            time.sleep(WATCHDOG_PERIOD)

    # Парсинг
    def _fetch_feed(self, url: str):
        r = self.session.get(url, timeout=(5,10))
        r.raise_for_status()
        return feedparser.parse(r.content)

    def _parse_once(self):
        src = RSS_SOURCES[self.idx]
        self.idx = (self.idx + 1) % len(RSS_SOURCES)
        self._refresh_session_if_needed()

        log.info("parse: %s %s", src["name"], src["url"])
        try:
            feed = self._fetch_feed(src["url"])
        except requests.Timeout:
            log.warning("timeout on %s", src["name"]); return
        except requests.RequestException as e:
            log.warning("network error on %s: %s", src["name"], e); return

        if getattr(feed, "bozo", False):
            log.warning("bozo on %s: %s", src["name"], getattr(feed, "bozo_exception", None))

        entries = getattr(feed, "entries", [])[:15]
        if not entries:
            log.info("no entries in %s", src["name"]); return

        added = 0
        new_items = []
        for e in entries:
            try:
                title = _clean(e.get("title",""))
                if len(title) < 5:  # мягче фильтр
                    continue
                link = e.get("link") or ""
                if not link and getattr(e, "links", None):
                    for lo in e.links:
                        if getattr(lo, "rel", "") == "alternate":
                            link = getattr(lo, "href", "") or link; break
                desc = ""
                for key in ("summary","description"):
                    if getattr(e, key, None):
                        desc = _clean(getattr(e, key)); break
                if not desc and getattr(e, "content", None):
                    try: desc = _clean(e.content[0].value)
                    except Exception: pass
                new_items.append({"title": title, "link": link, "description": desc,
                                  "source": src["name"], "lang": src["lang"]})
                added += 1
            except Exception as ex:
                log.warning("entry err in %s: %s", src["name"], ex)

        if added:
            with self.lock:
                self.news_list.extend(new_items)
                self.news_list = self.news_list[-150:]
            log.info("added=%d from %s; total=%d", added, src["name"], len(self.news_list))

    def _parse_loop(self):
        while self.running:
            try:
                self._parse_once()
            except Exception as e:
                log.exception("parse loop: %s", e)
            self.stop_event.wait(PARSE_PERIOD)

    # Отправка
    def _send_esp(self, message: str) -> bool:
        clean = re.sub(r"[^\w\sа-яА-ЯёЁA-Za-z0-9.,!?\-:;]", "", message)
        url = f"http://{ESP32_IP}/api?mes={requests.utils.quote(clean)}"
        log.info("send -> %s", clean[:80])
        try:
            self._refresh_session_if_needed()
            r = self.session.get(url, timeout=(3,5))
            log.info("send status=%s", r.status_code)
            return r.status_code == 200
        except requests.Timeout:
            log.warning("send timeout")
        except requests.RequestException as e:
            log.warning("send error: %s", e)
        return False

    def _send_loop(self):
        while self.running:
            try:
                with self.lock:
                    avail = [n for n in self.news_list if n["title"] not in self.sent_titles]
                    if not avail and self.news_list:
                        self.sent_titles.clear()
                        avail = list(self.news_list)
                if avail:
                    n = random.choice(avail)
                    prefix = "[INT] " if n["lang"]=="en" else "[RU] "
                    msg = (prefix + n["title"])[:200]
                    if self._send_esp(msg):
                        self.sent_titles.add(n["title"])
                        self.send_fail_streak = 0
                    else:
                        self.send_fail_streak += 1
                        if self.send_fail_streak >= SEND_COOLDOWN_FAILS:
                            log.warning("too many send fails -> cooldown %ss", SEND_COOLDOWN_SECS)
                            self.stop_event.wait(SEND_COOLDOWN_SECS)
                            self.send_fail_streak = 0
                else:
                    log.info("queue empty: news=%d", len(self.news_list))
            except Exception as e:
                log.exception("send loop: %s", e)
            self.stop_event.wait(SEND_PERIOD)

    def stop(self):
        self.running = False
        self.stop_event.set()

def main():
    ni = NewsInformer()
    # корректное завершение по сигналам
    def _sigterm(_s, _f):
        ni.stop()
    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT,  _sigterm)

    try:
        while ni.running:
            time.sleep(1)
    finally:
        ni.stop()
        log.info("stopped")

if __name__ == "__main__":
    main()
PYEOF

chmod +x "$PY_SCRIPT"

echo "🧾 Создание systemd user-сервиса: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<SYSEOF
[Unit]
Description=Multi-Source News Informer Service
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
Environment=ESP32_IP=$ESP32_IP
ExecStart=$ENV_DIR/bin/python $PY_SCRIPT
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5s
# страховка от долгоживущих зависаний/утечек — мягкий рестарт раз в час
RuntimeMaxSec=3600
# перезапустить, если пропал WATCHDOG
WatchdogSec=60s

[Install]
WantedBy=default.target
SYSEOF

echo "🔄 Перезагрузка юнитов и запуск…"
systemctl --user daemon-reload
systemctl --user enable --now news_informer.service || true
systemctl --user restart news_informer.service

echo "✅ Готово."
echo "📄 Логи: journalctl --user -u news_informer.service -f"
echo "📝 Файл-лог: tail -f $LOG_FILE"
echo "🌐 ESP32_IP=$ESP32_IP (можно переопределить перед запуском скрипта)"
