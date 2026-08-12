# Router bundles: FULL и MINIMAL

Проект собирает два логических установочных пакета для роутера:

```text
keenetic-vpn-full-linux-<arch>.run
keenetic-vpn-minimal-linux-<arch>.run
```

Для каждой поддерживаемой архитектуры выпускается своя пара файлов. Сейчас
полный router stack поддерживает `arm64` и `mipsle`. Обычный `mips` остаётся
поддержан для отдельного `xray-go-agent`, но не для router bundle, потому что
`xray-failover-go` для него не выпускается.

## Что представляет собой `.run`

Это настоящий Linux ELF нужной архитектуры, к которому добавлен gzip/tar
payload. В конце файла находится footer `KVPNBUNDLEv1` с точным размером и
SHA-256 всего payload. Внутри payload лежит строгий JSON manifest с SHA-256,
размером, mode, ролью и целевым путём каждого файла.

Перед чтением или установкой проверяются:

- footer, границы payload и общий SHA-256;
- schema, edition, OS и архитектура manifest;
- допустимость всех путей (только `/opt/...`, без `..`);
- отсутствие symlink, device и других специальных tar entries;
- размер, mode и SHA-256 каждого файла;
- отсутствие дубликатов, лишних и пропущенных файлов.

Распаковка потоковая: весь payload не загружается в RAM. Для роутера с 40 МБ
это важнее небольшой разницы в размере shell-скриптов.

## FULL и MINIMAL

Оба пакета содержат:

- `xray-failover-go`;
- `xray-go-agent` и локальный `xray-go-agent-setup`;
- `xray-go`, doctor, doctor-summary, history, cleanup и recovery;
- управление primary/backup;
- manifest/space/size helpers;
- каталог маршрутов для управления из Telegram-бота;
- небольшие общие shell-библиотеки.

Поэтому `MINIMAL` управляется агентом и ботом так же, как `FULL`. Его отличие
не в вырезанных кнопках или диагностике, а в эксплуатационном профиле: без
автоматически включённых тяжёлых зависимостей и дополнительных фоновых
full-служб.

`FULL` дополнительно содержит watchdog, cron auto-update, privacy/safety
проверки, SOCKS-auth helper, Xray-core updater и full maintenance helpers.
Наличие helper в bundle само по себе не запускает новый daemon и не создаёт
cron-задание.

Amnezia Premium и Premium `vpn://` не входят ни в один пакет. Планируемая AWG
поддержка рассчитана только на self-hosted AmneziaWG.

## Команды файла

```sh
chmod +x keenetic-vpn-minimal-linux-mipsle.run
./keenetic-vpn-minimal-linux-mipsle.run info
./keenetic-vpn-minimal-linux-mipsle.run verify
./keenetic-vpn-minimal-linux-mipsle.run plan
./keenetic-vpn-minimal-linux-mipsle.run install --yes
```

`info`, `verify` и `plan` ничего не меняют. `install` требует явный `--yes`.
Установщик сначала полностью проверяет bundle без изменений системы, затем
повторно проверяет и устанавливает payload потоково, по одному файлу. Файлы с
уже совпадающими mode, размером и SHA-256 пропускаются, поэтому весь payload не
дублируется во временной директории на `/opt`. Замены выполняются через atomic
rename, а старые версии хранятся до конца общей транзакции. При ошибке уже
выполненные замены откатываются в обратном порядке.
Перед первой заменой установщик также рассчитывает объём только реально новых
или изменившихся файлов и требует дополнительно 1 МиБ свободного резерва.

Установщик не меняет:

- `/opt/etc/xray/config.json`;
- сохранённые VLESS/AWG sources;
- active primary/backup slot;
- agent token, router ID и TLS fingerprint;
- Keenetic policy и Proxy0;
- init/cron без отдельной команды настройки.

Если `/opt/bin/xray-go-agent` уже существует, bundle сохраняет его. Обновление
работающего агента выполняется через `Агент -> latest/dev`, где используются
A/B-слоты, health confirmation и автоматический rollback.

На новой установке агент можно связать с уже созданной в боте записью роутера:

```sh
xray-go-agent-setup \
  --server-url 'https://VPS:18090' \
  --server-fingerprint 'SHA256' \
  --router-id 'home' \
  --router-name 'Дом' \
  --agent-token 'TOKEN'
```

Команда не обращается к GitHub: она использует агент из bundle, безопасно
создаёт конфигурацию и Entware init service.

## Каналы

После включения workflow артефакты будут доступны в двух GitHub Releases:

```text
dev:
  releases/download/dev/keenetic-vpn-{full|minimal}-linux-{arm64|mipsle}.run

latest:
  releases/download/latest/keenetic-vpn-{full|minimal}-linux-{arm64|mipsle}.run
```

`dev` — prerelease с текущего проверенного commit `main`. `latest` обновляется
только вместе со стабильным релизом. Для каждого `.run` публикуется sidecar
`.sha256`.

Важно: наличие кода в ветке разработки ещё не делает кнопку `dev` доступной
на живом боте. Для этого изменения должны попасть в `main`, workflow должен
создать dev release, а обновлённый control-server должен быть установлен на
VPS. Эти действия не выполняются автоматически из локальной сборки.

## Текущая граница этапа

Первый этап объединяет и безопасно устанавливает проектный router layer. Он
пока не встраивает сторонний Xray-core и не создаёт первый VLESS/AWG профиль
из пустого роутера. До добавления единого post-install orchestrator начальная
настройка Xray остаётся за существующим setup flow. Это позволяет тестировать
новый формат на живом роутере без переключения текущих рабочих install URL.
