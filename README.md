# DelovodAI

Автономный деловой AI-ассистент на базе OpenCLAW и Ollama.

Локальная среда — никаких утечек данных на чужие серверы.

## Возможности

- Telegram-бот и/или веб-интерфейс
- Документооборот, переписка, расписание, задачи
- Полная локальность: вся конфигурация и данные в папке `data/` (в `.gitignore`)
- Расширяется плагинами

## Быстрый старт

```bash
# Запустить (автоматически создаст .env из .env.example при первом запуске)
./run.sh
```

Или вручную:

```bash
cp .env.example .env
# настроить .env при необходимости
docker compose up -d
```

## Переменные окружения (`.env`)

| Переменная | Обязательно | По умолчанию | Описание |
|---|---|---|---|
| `OLLAMA_HOST` | да | `ollama:11434` | Адрес Ollama |
| `TELEGRAM_BOT_TOKEN` | нет | — | Токен Telegram-бота |
| `WEBUI_PASSWORD` | нет | — | Пароль веб-интерфейса |
| `WEBUI_PORT` | нет | `3000` | Порт веб-интерфейса |
| `CALDAV_PORT` | нет | `5232` | Порт CalDAV-сервера (Radicale) |
| `DEFAULT_MODEL` | нет | `gpt-oss:20b` | Модель Ollama по умолчанию |

## Структура томов

Всё изменяемое — внутри `data/` (директория в `.gitignore`):

```
data/
├── config/
│   ├── openclaw.json    ← конфигурация OpenCLAW (генерируется при первом запуске)
│   ├── env              ← сохранённые переменные окружения
│   └── AGENTS.md        ← системный промпт ассистента (можно редактировать)
├── openclaw/            ← данные OpenCLAW (сессии, память)
├── plugins/             ← кастомные плагины (.js)
├── documents/
│   ├── templates/       ← шаблоны документов
│   └── generated/       ← сгенерированные документы
├── calendar/            ← CalDAV (Radicale)
└── tasks/               ← задачи
```

## Зависимости

- **Docker** + **Docker Compose**
- **SelfHostedAI** — Ollama + Open WebUI в соседней директории ([github.com/NikitaShubin/SelfHostedAI](https://github.com/NikitaShubin/SelfHostedAI)).  
  Ollama должен быть запущен и доступен по адресу из `OLLAMA_HOST`.
