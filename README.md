# Element — iOS-клиент ElemSocial

<p align="center">
  <img src="ElementSocialClient/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" alt="Element">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2016%2B-blue" alt="iOS 16+">
  <img src="https://img.shields.io/badge/Swift-5.0-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI">
  <img src="https://img.shields.io/badge/build-XcodeGen-green" alt="XcodeGen">
</p>

Нативный iOS-клиент социальной сети [elemsocial.com](https://elemsocial.com), написанный на SwiftUI. Максимальный паритет с веб-версией: лента, мессенджер, музыка, кошелёк eBalls, Gold-подписка и многое другое.

> 🇷🇺 Основной язык интерфейса — русский, плюс ещё 12 локализаций.

## ✨ Возможности

### 📰 Лента
- Посты с фото, видео, музыкой и опросами; реакции, комментарии, репосты-ссылки
- Создание постов (текст + до 10 вложений + треки + опрос), **редактирование с вложениями**
- Архив, корзина, стена профиля, каналы, поиск по постам

### 💬 Мессенджер (1-в-1 с сайтом)
- Сквозное шифрование по ключевой фразе (та же, что на сайте)
- **Голосовые сообщения** с волной, скоростью 1x/1.5x/2x и seek'ом
- **Видеокружки**: съёмка, превью, экспорт в MP4
- Реакции, ответы, редактирование, удаление, поиск по чату с переходом
- Индикаторы «печатает» / «записывает», галочки прочтения, разделители дат
- Группы: создание, участники, ссылки-приглашения, вступление по `elemsocial.com/join/…`

### 🎵 Музыка
- Библиотека, плейлисты, альбомы, исполнители, избранное
- Загрузка треков, редактирование текстов (LRC), обложки
- Синхронизированные тексты песен, очередь, шаффл, офлайн-кэш

### 💰 Кошелёк и Gold
- Баланс eBalls, история, переводы, **реферальная программа**, зал славы
- Gold-подписка: оплата баллами, активация кодом, история

### 👤 Аккаунты и настройки
- **Регистрация** с hCaptcha, подтверждение почты, вход, **мультиаккаунт** с переключением
- Профиль: аватары, обложки, ссылки, подписки, блокировки, подарки
- Сессии, управление хранилищем, темы, языки, экспорт/удаление данных
- Мои жалобы и апелляции, сторонние приложения (Apps/ConnectApp), EPACK-вьюер

## 🛠 Технологии

| Слой | Решение |
|---|---|
| UI | SwiftUI, MVVM |
| Сеть | **Один WebSocket** (`wss://ws.elemsocial.com/user_api`), без REST |
| Сериализация | MessagePack (свой кодек) + `ray_id`-корреляция запросов |
| Крипто | RSA-OAEP-2048 + AES-CBC handshake, сквозное шифрование чатов |
| Кэш медиа | Чанковые загрузки `[file_id+variant+offset]` с проверкой **SHA-256** (аналог Dexie `file_cacheV2`) |
| Проект | XcodeGen (`project.yml` → `.xcodeproj`) |

## 📦 Установка

Готовый **`.ipa`** прикреплён к [релизам](../../releases) — см. последний релиз.

## 🔨 Сборка из исходников

Требования: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/yukihoshiii/elemsocial-ios.git
cd elemsocial-ios
xcodegen generate
open ElementSocialClient.xcodeproj
```

Или из терминала:

```bash
xcodebuild -project ElementSocialClient.xcodeproj \
  -scheme ElementSocialClient \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## 🗂 Структура проекта

```
ElementSocialClient/
├── Views/          # Экраны (PostsView, Messenger*, MusicView, SettingsViews, …)
├── ViewModels/     # MVVM-логика
├── Models/         # Post, User, Messenger, Music, EBall, …
├── Services/       # APIClient, ElementCrypto, MessagePack,
│                   #   MediaCacheService, ChatRecorder, …
├── Resources/      # Локализации (13 языков), эмодзи Apple, звуки
└── Configs/        # Changelog и прочее
```

## 🔐 Приватность

- Сессии (`S_KEY`) хранятся в Keychain через `AuthTokenStore`
- Ключ-фраза мессенджера проверяется сервером, сообщения расшифровываются только на устройстве
- В репозитории нет секретов: ни ключей, ни токенов, ни паролей

## 📄 Лицензия

Исходники открыты для ознакомления. Серверная часть и торговая марка Element принадлежат создателю Хароми.
