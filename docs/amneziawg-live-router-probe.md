# Проверка AmneziaWG runtime на живом Keenetic

Этот probe предназначен только для измерения совместимости и памяти перед
решением о включении AWG в MINIMAL. Он не импортирует `vpn://`, не подключается
к настоящему серверу и не меняет рабочий VPN.

## Граница безопасности

Режим `preflight` полностью read-only. Режим `run` требует явный `--yes` и:

- создаёт только временный интерфейс `awgprobe0`;
- использует локальный фиктивный endpoint `127.0.0.1:9`;
- не назначает интерфейсу IP-адрес;
- не добавляет и не удаляет route/rule;
- не вызывает `ndmc` и не меняет Keenetic `Proxy0`;
- не перезапускает Xray, agent или watchdog;
- не читает сохранённые VLESS/AWG profiles;
- сравнивает Xray config, active-slot state, routes и rules до/после;
- при штатном завершении, ошибке или сигнале останавливает созданный процесс,
  удаляет `awgprobe0`, UAPI socket и временные файлы.

`run` отказывается стартовать при доступной памяти ниже 24576 КБ. Порог можно
уменьшить только явно, но первый тест на 40-МБ роутере следует начинать строго
с `preflight` и сначала оценить его результат.

## Получение файлов

Откройте последний успешный запуск workflow
[`AWG runtime probe`](https://github.com/Kuzz007/keenetic_xray_installer/actions/workflows/awg-runtime-probe.yml)
на ветке `main` и скачайте artifact для архитектуры роутера.

С GitHub CLI на компьютере:

```sh
gh run list \
  --repo Kuzz007/keenetic_xray_installer \
  --workflow awg-runtime-probe.yml \
  --branch main \
  --status success \
  --limit 1

gh run download RUN_ID \
  --repo Kuzz007/keenetic_xray_installer \
  --name awg-runtime-probe-linux-mipsle \
  --dir awg-runtime-probe-mipsle
```

Для первого MIPSLE-теста на роутер нужны только:

```text
keenetic-awg-live-probe.sh
keenetic-awg-live-probe.sh.sha256
amneziawg-go-linux-mipsle
amneziawg-go-linux-mipsle.sha256
amneziawg-tools-linux-mipsle
amneziawg-tools-linux-mipsle.sha256
```

Runtime probe сам повторно проверит SHA256 обоих бинарников перед запуском.

## Шаг 1. Только preflight

Поместите файлы в отдельный каталог, например `/opt/tmp/awg-live-probe`, затем:

```sh
cd /opt/tmp/awg-live-probe
probe_runner='keenetic-awg-live-probe.sh'
probe_expected="$(tr -d '[:space:]' < "$probe_runner.sha256")"
probe_actual="$(sha256sum "$probe_runner" | awk '{ print $1 }')"
[ "$probe_actual" = "$probe_expected" ] || { echo 'PROBE SHA256 ERROR'; exit 1; }

chmod 700 keenetic-awg-live-probe.sh \
  amneziawg-go-linux-mipsle \
  amneziawg-tools-linux-mipsle

sh ./keenetic-awg-live-probe.sh preflight | tee awg-preflight.txt
```

Для продолжения нужны как минимум:

```text
AWG_PROBE_ARCH=mipsle
AWG_PROBE_ARCH_SUPPORTED=yes
AWG_PROBE_UID=0
AWG_PROBE_TUN=present
AWG_PROBE_INTERFACE_AVAILABLE=yes
AWG_PROBE_SOCKET_AVAILABLE=yes
AWG_PROBE_PREFLIGHT=pass
```

Вывод не содержит VPN URL, токены или ключи, поэтому его можно передать для
анализа целиком. Если preflight не прошёл, `run` выполнять нельзя.

## Шаг 2. Изолированное измерение

Запускать после проверки preflight:

```sh
sh ./keenetic-awg-live-probe.sh run --yes \
  --runtime "$(pwd)/amneziawg-go-linux-mipsle" \
  --tools "$(pwd)/amneziawg-tools-linux-mipsle" \
  --seconds 5 \
  | tee awg-live-result.txt
```

Успешное завершение содержит:

```text
AWG_PROBE_ROUTE_RESTORED=yes
AWG_PROBE_RULES_RESTORED=yes
AWG_PROBE_MANAGED_STATE_RESTORED=yes
AWG_PROBE_PROXY0_TOUCHED=no
AWG_PROBE_ACTIVE_SLOT_TOUCHED=no
AWG_PROBE_HANDSHAKE=not-requested
AWG_PROBE_RESULT=pass
```

Для memory gate важны:

- `AWG_PROBE_MEM_AVAILABLE_BEFORE_KB`;
- `AWG_PROBE_MEM_AVAILABLE_DURING_KB`;
- `AWG_PROBE_MEM_AVAILABLE_AFTER_KB`;
- `AWG_PROBE_MEM_AVAILABLE_DELTA_KB`;
- `AWG_PROBE_RUNTIME_RSS_KB`;
- `AWG_PROBE_RUNTIME_HWM_KB`;
- `AWG_PROBE_RUNTIME_THREADS`.

Этот тест не выполняет handshake и не проверяет реальный трафик. Его успешный
результат разрешает переход к реализации одного AWG-слота, но сам по себе ещё
не разрешает выпуск AWG в MINIMAL или `latest`.
