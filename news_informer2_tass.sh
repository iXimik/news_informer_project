#!/bin/bash

# Константы
APP_DIR="$HOME/nix2/news_informer2"
ENV_DIR="$APP_DIR/venv"
PY_SCRIPT="$APP_DIR/news_informer2.py"
LOG_FILE="$APP_DIR/informer.log"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/news_informer.service"

echo "▶️ Создание каталога $APP_DIR"
mkdir -p "$APP_DIR"
mkdir -p "$SERVICE_DIR"

echo "🐍 Создание виртуального окружения..."
python3 -m venv "$ENV_DIR"
source "$ENV_DIR/bin/activate"

echo "📦 Установка зависимостей..."
pip install --upgrade pip
pip install requests feedparser

echo "📄 Создание Python-скрипта: $PY_SCRIPT"
cat <<'EOF' > "$PY_SCRIPT"
import requests
import feedparser
from datetime import datetime
import time
import threading
import random
from requests.utils import quote
import logging
import re

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('news_informer.log'),
        logging.StreamHandler()
    ]
)

# Разные RSS-ленты TASS
RSS_URLS = [
    "https://tass.ru/rss/v2.xml",           # Основная лента (все новости)
    "https://tass.ru/rss/news.xml",         # Главные новости
    "https://tass.ru/rss/economy.xml",      # Экономика
    "https://tass.ru/rss/politics.xml",     # Политика
    "https://tass.ru/rss/society.xml",      # Общество
    "https://tass.ru/rss/incidents.xml",    # Происшествия
    "https://tass.ru/rss/culture.xml",      # Культура
    "https://tass.ru/rss/defense.xml",      # Оборона
    "https://tass.ru/rss/science.xml",      # Наука
    "https://tass.ru/rss/sport.xml",        # Спорт (если нужно)
]

ESP32_IP = "1.1.1.235"

class NewsInformer:
    def __init__(self):
        self.running = True
        self.news_list = []
        self.sent_news = set()
        self.current_rss_index = 0
        self.start_auto_parse()
        self.start_auto_send()
        logging.info("NewsInformer инициализирован")

    def clean_text(self, text):
        """Очистка текста от HTML тегов и лишних пробелов"""
        if not text:
            return ""
        text = re.sub('<[^<]+?>', '', text)
        text = re.sub('\s+', ' ', text)
        return text.strip()

    def get_current_rss_url(self):
        """Получение текущей RSS-ссылки с ротацией"""
        return RSS_URLS[self.current_rss_index]

    def parse_news(self):
        """Парсинг RSS-ленты TASS с ротацией источников"""
        try:
            current_url = self.get_current_rss_url()
            logging.info(f"Парсинг RSS: {current_url}")
            
            # Добавляем заголовки для имитации браузера
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Accept': 'application/rss+xml, text/xml, application/xml'
            }
            
            feed = feedparser.parse(current_url)
            
            if feed.bozo:
                logging.warning(f"Предупреждения при парсинге: {feed.bozo_exception}")

            if not feed.entries:
                logging.warning("Новостей не найдено в RSS-ленте")
                # Переключаемся на следующую RSS-ленту
                self.current_rss_index = (self.current_rss_index + 1) % len(RSS_URLS)
                return

            new_news = []
            for entry in feed.entries[:20]:  # Берем больше новостей
                try:
                    title = self.clean_text(entry.get('title', ''))
                    if not title:
                        continue
                    
                    # Пропускаем чисто спортивные новости если не хотим только спорт
                    if any(word in title.lower() for word in ['футбол', 'хоккей', 'спорт', 'матч', 'чемпионат']):
                        continue
                    
                    link = entry.get('link', '')
                    
                    description = ""
                    if hasattr(entry, 'summary'):
                        description = self.clean_text(entry.summary)
                    elif hasattr(entry, 'description'):
                        description = self.clean_text(entry.description)
                    
                    # Добавляем источник в сообщение для разнообразия
                    source = "TASS"
                    if "economy" in current_url:
                        source = "ТАСС-Экономика"
                    elif "politics" in current_url:
                        source = "ТАСС-Политика"
                    elif "society" in current_url:
                        source = "ТАСС-Общество"
                    
                    new_news.append((title, link, description, source))
                    
                except Exception as e:
                    logging.error(f"Ошибка обработки новости: {e}")
                    continue

            if new_news:
                self.news_list = new_news
                logging.info(f"Получено {len(self.news_list)} новостей из {current_url}")
                
                # Переключаемся на следующую RSS-ленту для разнообразия
                self.current_rss_index = (self.current_rss_index + 1) % len(RSS_URLS)
                
        except Exception as e:
            logging.error(f"Критическая ошибка при парсинге: {e}")
            # При ошибке тоже переключаем RSS
            self.current_rss_index = (self.current_rss_index + 1) % len(RSS_URLS)

    def send_to_esp32(self, message):
        """Отправка строки на ESP32 с улучшенной обработкой ошибок"""
        try:
            clean_message = re.sub(r'[^\w\sа-яА-ЯёЁ.,!?-]', '', message)
            encoded_message = quote(clean_message)
            
            url = f"http://{ESP32_IP}/api?mes={encoded_message}"
            
            response = requests.get(url, timeout=3)
            
            if response.status_code == 200:
                logging.info(f"Успешно отправлено: {clean_message[:50]}...")
                return True
            else:
                logging.warning(f"Ошибка HTTP {response.status_code}")
                return False
                
        except requests.exceptions.Timeout:
            logging.warning("Таймаут при отправке на ESP32")
            return False
        except requests.exceptions.ConnectionError:
            logging.error("Ошибка соединения с ESP32. Проверьте IP и подключение")
            return False
        except Exception as e:
            logging.error(f"Неожиданная ошибка при отправке: {e}")
            return False

    def auto_parse(self):
        """Автоматический парсинг каждые 15 минут"""
        while self.running:
            self.parse_news()
            for _ in range(900):  # 15 минут
                if not self.running:
                    break
                time.sleep(1)

    def auto_send(self):
        """Автоматическая отправка новостей каждые 45 секунд"""
        while self.running:
            if self.news_list:
                available_news = [news for news in self.news_list if news[0] not in self.sent_news]
                
                if not available_news:
                    self.sent_news.clear()
                    available_news = self.news_list
                
                if available_news:
                    title, link, description, source = random.choice(available_news)
                    
                    # Формируем сообщение с источником
                    if len(title) <= 90:
                        message = f"{source}: {title}"
                    else:
                        message = title[:100] + "..."
                    
                    if self.send_to_esp32(message):
                        self.sent_news.add(title)
            
            for _ in range(45):  # 45 секунд
                if not self.running:
                    break
                time.sleep(1)

    def start_auto_parse(self):
        thread = threading.Thread(target=self.auto_parse, daemon=True)
        thread.start()
        logging.info("Запущен автоматический парсинг")

    def start_auto_send(self):
        thread = threading.Thread(target=self.auto_send, daemon=True)
        thread.start()
        logging.info("Запущена автоматическая отправка")

    def stop(self):
        self.running = False
        logging.info("NewsInformer остановлен")

def main():
    try:
        informer = NewsInformer()
        logging.info("Сервис запущен. Для остановки нажмите Ctrl+C")
        
        while informer.running:
            time.sleep(0.1)
            
    except KeyboardInterrupt:
        logging.info("Получен сигнал прерывания")
    except Exception as e:
        logging.error(f"Неожиданная ошибка в main: {e}")
    finally:
        if 'informer' in locals():
            informer.stop()
        logging.info("Приложение завершено")

if __name__ == "__main__":
    main()
EOF

echo "🧾 Создание systemd user-сервиса: $SERVICE_FILE"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=User News Informer Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$ENV_DIR/bin/python $PY_SCRIPT
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

echo "🔄 Перезапуск и включение systemd user-сервиса..."
systemctl --user daemon-reload
systemctl --user enable news_informer.service
systemctl --user restart news_informer.service

echo "✅ Установка завершена. Сервис активен."
echo "📄 Просмотр лога: journalctl --user -u news_informer.service -f"
echo "📁 Логи приложения: tail -f $APP_DIR/news_informer.log"
