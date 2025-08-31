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
pip install requests feedparser beautifulsoup4

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
from bs4 import BeautifulSoup

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('news_informer.log'),
        logging.StreamHandler()
    ]
)

# Множество RSS-лент мировых новостных агентств
RSS_SOURCES = [
    # Русскоязычные источники
    {"url": "https://tass.ru/rss/v2.xml", "name": "ТАСС", "lang": "ru"},
    {"url": "https://ria.ru/export/rss2/index.xml", "name": "РИА Новости", "lang": "ru"},
    {"url": "https://www.vesti.ru/vesti.rss", "name": "Вести", "lang": "ru"},
    {"url": "https://lenta.ru/rss", "name": "Лента.ру", "lang": "ru"},
    {"url": "https://www.interfax.ru/rss.asp", "name": "Интерфакс", "lang": "ru"},
    {"url": "https://www.kommersant.ru/RSS/news.xml", "name": "Коммерсант", "lang": "ru"},
    {"url": "https://rg.ru/rss/", "name": "Российская газета", "lang": "ru"},
    {"url": "https://www.gazeta.ru/export/rss/lenta.xml", "name": "Газета.ru", "lang": "ru"},
    
    # Англоязычные и международные источники
    {"url": "https://rss.cnn.com/rss/edition.rss", "name": "CNN", "lang": "en"},
    {"url": "https://feeds.bbci.co.uk/news/rss.xml", "name": "BBC News", "lang": "en"},
    {"url": "https://www.reutersagency.com/feed/?taxonomy=best-topics&post_type=best", "name": "Reuters", "lang": "en"},
    {"url": "https://www.cgtn.com/rss/news", "name": "CGTN", "lang": "en"},
    {"url": "https://www.aljazeera.com/xml/rss/all.xml", "name": "Al Jazeera", "lang": "en"},
    {"url": "https://www.bloomberg.com/feed/podcast/etf-report.xml", "name": "Bloomberg", "lang": "en"},
    {"url": "https://www.theguardian.com/world/rss", "name": "The Guardian", "lang": "en"},
    {"url": "https://www.nytimes.com/services/xml/rss/nyt/World.xml", "name": "New York Times", "lang": "en"},
    
    # Региональные и тематические
    {"url": "https://www.dw.com/rdf/rss-en-all", "name": "Deutsche Welle", "lang": "en"},
    {"url": "https://www.france24.com/en/rss", "name": "France 24", "lang": "en"},
    {"url": "https://www.euronews.com/rss", "name": "Euronews", "lang": "en"},
]

ESP32_IP = "1.1.1.235"

class NewsInformer:
    def __init__(self):
        self.running = True
        self.news_list = []
        self.sent_news = set()
        self.current_source_index = 0
        self.start_auto_parse()
        self.start_auto_send()
        logging.info("NewsInformer инициализирован с множеством источников")

    def clean_text(self, text):
        """Очистка текста от HTML тегов и лишних пробелов"""
        if not text:
            return ""
        text = re.sub('<[^<]+?>', '', text)
        text = re.sub('\s+', ' ', text)
        text = re.sub(r'[^\w\sа-яА-ЯёЁa-zA-Z.,!?\-:;]', '', text)
        return text.strip()

    def translate_simple(self, text, source_lang):
        """Простой перевод ключевых слов для английских новостей"""
        if source_lang != 'en':
            return text
            
        # Простая замена ключевых слов для лучшего понимания
        translations = {
            'war': 'война', 'crisis': 'кризис', 'economy': 'экономика',
            'president': 'президент', 'government': 'правительство',
            'attack': 'атака', 'meeting': 'встреча', 'agreement': 'соглашение',
            'sanctions': 'санкции', 'election': 'выборы', 'protest': 'протест',
            'climate': 'климат', 'technology': 'технологии', 'health': 'здоровье',
            'energy': 'энергия', 'security': 'безопасность', 'development': 'развитие'
        }
        
        for eng, rus in translations.items():
            text = re.sub(rf'\b{eng}\b', rus, text, flags=re.IGNORECASE)
        
        return text

    def parse_news(self):
        """Парсинг новостей из различных источников"""
        try:
            source = RSS_SOURCES[self.current_source_index]
            logging.info(f"Парсинг: {source['name']} - {source['url']}")
            
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Accept': 'application/rss+xml, text/xml, application/xml, */*'
            }
            
            try:
                response = requests.get(source['url'], headers=headers, timeout=10)
                response.encoding = 'utf-8'
                feed = feedparser.parse(response.content)
            except:
                feed = feedparser.parse(source['url'])
            
            if feed.bozo and feed.bozo_exception:
                logging.warning(f"Ошибка парсинга {source['name']}: {feed.bozo_exception}")

            if not feed.entries:
                logging.warning(f"Новостей не найдено в {source['name']}")
                self.current_source_index = (self.current_source_index + 1) % len(RSS_SOURCES)
                return

            new_news = []
            for entry in feed.entries[:15]:
                try:
                    title = self.clean_text(entry.get('title', ''))
                    if not title or len(title) < 10:
                        continue
                    
                    # Для английских источников добавляем простой перевод
                    if source['lang'] == 'en':
                        title = self.translate_simple(title, 'en')
                    
                    link = entry.get('link', '')
                    if not link and hasattr(entry, 'links'):
                        for link_obj in entry.links:
                            if link_obj.rel == 'alternate':
                                link = link_obj.href
                                break
                    
                    description = ""
                    if hasattr(entry, 'summary'):
                        description = self.clean_text(entry.summary)
                    elif hasattr(entry, 'description'):
                        description = self.clean_text(entry.description)
                    elif hasattr(entry, 'content'):
                        if entry.content:
                            description = self.clean_text(entry.content[0].value)
                    
                    # Добавляем источник и язык
                    news_item = {
                        'title': title,
                        'link': link,
                        'description': description,
                        'source': source['name'],
                        'lang': source['lang']
                    }
                    
                    new_news.append(news_item)
                    
                except Exception as e:
                    logging.error(f"Ошибка обработки новости из {source['name']}: {e}")
                    continue

            if new_news:
                self.news_list.extend(new_news)
                # Ограничиваем общий список чтобы не занимать много памяти
                self.news_list = self.news_list[-100:]
                logging.info(f"Добавлено {len(new_news)} новостей от {source['name']}. Всего: {len(self.news_list)}")
                
            # Переключаемся на следующий источник
            self.current_source_index = (self.current_source_index + 1) % len(RSS_SOURCES)
                
        except Exception as e:
            logging.error(f"Критическая ошибка при парсинге: {e}")
            self.current_source_index = (self.current_source_index + 1) % len(RSS_SOURCES)

    def send_to_esp32(self, message):
        """Отправка строки на ESP32"""
        try:
            # Очищаем сообщение от проблемных символов
            clean_message = re.sub(r'[^\w\sа-яА-ЯёЁa-zA-Z.,!?\-:;]', '', message)
            encoded_message = quote(clean_message)
            
            url = f"http://{ESP32_IP}/api?mes={encoded_message}"
            
            response = requests.get(url, timeout=5)
            
            if response.status_code == 200:
                logging.info(f"Отправлено: {clean_message[:60]}...")
                return True
            else:
                logging.warning(f"Ошибка HTTP {response.status_code}")
                return False
                
        except requests.exceptions.Timeout:
            logging.warning("Таймаут при отправке на ESP32")
            return False
        except requests.exceptions.ConnectionError:
            logging.error("Ошибка соединения с ESP32")
            return False
        except Exception as e:
            logging.error(f"Ошибка при отправке: {e}")
            return False

    def auto_parse(self):
        """Автоматический парсинг каждые 10 минут"""
        while self.running:
            self.parse_news()
            for _ in range(600):  # 10 минут
                if not self.running:
                    break
                time.sleep(1)

    def auto_send(self):
        """Автоматическая отправка новостей каждые 45 секунд"""
        while self.running:
            if self.news_list:
                available_news = [news for news in self.news_list if news['title'] not in self.sent_news]
                
                if not available_news:
                    # Очищаем историю если все новости отправлены
                    self.sent_news.clear()
                    available_news = self.news_list
                
                if available_news:
                    news_item = random.choice(available_news)
                    
                    # Формируем сообщение с указанием источника
                    if news_item['lang'] == 'en':
                        source_prefix = "[INT] "
                    else:
                        source_prefix = "[RU] "
                    
                    message = f"{source_prefix}{news_item['title']}"
                    
                    # Обрезаем если слишком длинное
                    if len(message) > 200:
                        message = message[:197] + "..."
                    
                    if self.send_to_esp32(message):
                        self.sent_news.add(news_item['title'])
            
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
        logging.info("Мульти-источниковый новостной информер запущен!")
        logging.info(f"Всего источников: {len(RSS_SOURCES)}")
        
        while informer.running:
            time.sleep(0.1)
            
    except KeyboardInterrupt:
        logging.info("Получен сигнал прерывания")
    except Exception as e:
        logging.error(f"Неожиданная ошибка: {e}")
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
Description=Multi-Source News Informer Service
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$ENV_DIR/bin/python $PY_SCRIPT
Environment=PYTHONUNBUFFERED=1
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF

echo "🔄 Перезапуск и включение systemd user-сервиса..."
systemctl --user daemon-reload
systemctl --user enable news_informer.service
systemctl --user restart news_informer.service

echo "✅ Установка завершена! Мульти-источниковый новостной информер активен."
echo "📊 Источников настроено: 20+ (русские и международные)"
echo "📄 Просмотр лога: journalctl --user -u news_informer.service -f"
echo "📁 Логи приложения: tail -f $APP_DIR/news_informer.log"
echo "🌍 Новости из: ТАСС, РИА, Вести, CNN, BBC, Reuters, CGTN и многих других!"
