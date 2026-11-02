# CMP 90HX: compute, PCIe Gen2 и автоматические idle-частоты

Ветка `experimental/dkms` добавляет тестовую автоматическую пересборку модулей.
Порядок перехода и ограничения: [DKMS-TEST.md](DKMS-TEST.md).

`unlock_cmp90hx.sh` — установщик для одной NVIDIA CMP 90HX (`10de:220d`)
на CachyOS и Debian 13. Он объединяет compute-разблокировку и PCIe Gen2
из репозитория Rhonstin, устанавливает загрузочные службы и собирает
`nvidia-pstated` для переключения частот между простоем и нагрузкой.

Собственный код этого репозитория распространяется по [MIT License](LICENSE).
Внешние проекты, исходники и NVIDIA runfiles сохраняют собственные лицензии
и условия использования.

Это сторонняя модификация драйвера, не официальный инструмент NVIDIA.
Используйте её на тестовой машине с резервной копией и независимым доступом
к консоли. Установка изменяет драйвер, kernel modules и конфигурацию systemd;
ошибки могут привести к зависанию GPU или потере доступа к нему.

## Поддержка и статус проверки

| Хост | Ядро | Статус |
| --- | --- | --- |
| CachyOS, x86_64 | `linux-cachyos-lts` 6.18 | Compute и Gen2 проверены на пользовательском хосте с ядром `6.18.48-1-cachyos-lts` |
| Debian 13, x86_64 | штатная ветка 6.12 | Адаптация предусмотрена в коде; аппаратная проверка не выполнена |

Проверенная конфигурация: Ryzen 5600G, изображение выводится через iGPU,
одна CMP 90HX используется для вычислений. Fast-проход достиг PCIe Gen2 x4
за 52 секунды в одном холодном запуске. Это наблюдение, не гарантия времени
или стабильности на других картах и платформах. Нужны повторные холодные
запуски и проверка реальной вычислительной нагрузки.

Установщик и его встроенные службы покрыты локальными тестами с подменой
системных команд. Эти тесты не заменяют аппаратную проверку полного
установочного процесса, Debian или работы демона.

Другие ОС/ядра можно пробовать с `--allow-unsupported-host`, но этот флаг
только ослабляет проверку платформы, а не обеспечивает совместимость.
Ubuntu отдельным профилем не поддерживается. Автоматизация рассчитана
строго на одну CMP 90HX; несколько таких карт приводят к отказу установки.

## Что устанавливается

- **NVIDIA 610.43.03:** официальный `.run` устанавливает userspace и firmware
  с `--no-kernel-modules`. Если нужная версия уже найдена, шаг пропускается.
- **Объединённые kernel modules:** `driver/build-gen2.sh` из Rhonstin
  скачивает исходники NVIDIA Open, применяет патчи 0014–0017 и устанавливает
  compute + GEN2CHAIN модули для текущего ядра.
- **CUDA Toolkit:** существующая ветка 13.3 проверяется по метаданным и
  наличию `nvcc`, `nvml.h`, `libcudart.so`. Если каталог отсутствует,
  официальный runfile **13.3.0** скачивается с сайта NVIDIA, проверяется
  по опубликованной MD5 и запускается в режиме **toolkit-only**.
- **Gen2 runtime:** устанавливаются полный и сокращённый загрузочные пути;
  по умолчанию включается experimental fast со fallback на полный проход.
- **nvidia-pstated:** демон собирается из закреплённой версии исходников
  и включается для запуска после успешной Gen2-службы.

Отдельно применять WildFlash compute-патчи не требуется: нужные compute-патчи
уже входят в выбранную сборку Rhonstin. Это не установка `cmp90hx_pwner`
и не точное воспроизведение его REJOIN16-алгоритма.

## Подготовка

Требуются root, интернет, systemd, отключённый Secure Boot и заголовки
**именно загруженного ядра**. Для CUDA runfile и распаковки требуется несколько
ГБ свободного места; предусмотрите запас в рабочем каталоге, `/usr/local`
и временном каталоге установщика.

### CachyOS

```bash
sudo pacman -S --needed base-devel git curl patch python pciutils kmod \
  util-linux cmake linux-cachyos-lts-headers mkinitcpio mokutil
```

Загрузитесь в `linux-cachyos-lts` 6.18. Компилятор модуля выбирается по
конфигурации ядра. Если ядро собрано GCC 15, а системный GCC уже другой ветки,
нужен доступный `gcc-15` (в CachyOS — пакет `gcc15`). Для Clang-ядра нужны
`clang` и `ld.lld`.

### Debian 13

```bash
sudo apt update
sudo apt install build-essential git curl patch python3 pciutils kmod \
  util-linux cmake initramfs-tools mokutil "linux-headers-$(uname -r)"
```

Используйте штатное ядро 6.12. После установки модулей скрипт обновляет
initramfs текущего ядра через `update-initramfs`.

### Конфликты драйверов

NVIDIA `.run` устанавливает файлы вне пакетного менеджера. Не смешивайте его
с несовместимыми пакетами NVIDIA: обновление `nvidia-utils` или аналогичных
пакетов может заменить библиотеки. Если обнаружен несовместимый/неполный
userspace, принадлежащий пакетам, скрипт откажется накладывать `.run`.
Автоматическое удаление пакетов не выполняется.

При загруженном `nouveau` установщик добавит blacklist, обновит initramfs
и попросит перезагрузиться, затем повторить установку. Не пытайтесь выгружать
драйвер, обслуживающий основной дисплей.

Для headless CMP важно, чтобы display manager и приложения не держали её
открытой. Монитор на iGPU сам по себе этого не гарантирует. Скрипт не выбирает
основной GPU в BIOS, не перенастраивает рабочий стол и не устанавливает
headless-параметры `nvidia-drm` автоматически.

## Установка

Главный скрипт самодостаточен: runtime-скрипты и unit-файлы встроены в него.
Достаточно скопировать `unlock_cmp90hx.sh` в постоянный рабочий каталог:

```bash
chmod +x unlock_cmp90hx.sh
sudo ./unlock_cmp90hx.sh install
sudo systemctl poweroff
```

После полного выключения обеспечьте отсутствие питания карты не менее
60 секунд, затем включите машину. Обычный `reboot` не заменяет холодный тест.
При fallback загрузка может существенно задержаться; установщик предлагает
ожидать до 30 минут. Не запускайте параллельные consume/hammer/reload-проходы.

`install` включает fast и демон на следующую загрузку. Отдельного немедленного
запуска демона в ходе установки нет. Сборщик upstream при этом может попытаться
загрузить модули — установка не является операцией без влияния на текущий GPU.

Загрузки, исходники, сборки и резервные копии находятся в `cmp90hx-work`
**рядом со скриптом**, а не относительно текущего каталога запуска.
Сохраните этот каталог для `repair-runtime` и диагностики.

## Команды и параметры

| Команда | Назначение |
| --- | --- |
| `install` | Полная установка; также действие по умолчанию без аргументов |
| `verify` | Версия драйвера, путь модуля, текущий PCIe link и compute-маркеры журнала |
| `repair-runtime` | Обновление обеих runtime-копий и служб без пересборки модуля; сохраняет выбор режима |
| `install-fast` | Установка/обновление fast-runtime без изменения выбранной boot-службы |
| `enable-fast` | Выбор fast для следующей загрузки, отключение полной службы |
| `enable-full` | Выбор полного прохода для следующей загрузки, отключение fast |
| `install-pstated` | Проверка/установка userspace и CUDA, сборка демона и его службы; требует установленный Gen2 runtime |
| `install-dkms` | Экспериментальная миграция установленного compute + Gen2 на DKMS; без переустановки CUDA/userspace/демона |
| `apply` | Немедленный полный проход; останавливает демон, требует полного режима и отсутствия клиентов GPU |

`apply` не является рекомендуемым первым тестом после установки. Команда
отказывается работать при включённой/активной fast-службе и не запускает
остановленный демон обратно автоматически.

Параметры:

- `--dkms`: экспериментальная полная установка через DKMS. При уже
  зарегистрированном `cmp90hx-nvidia` повторный `install` сохраняет DKMS-режим.
- `--no-install-userspace`: требовать уже установленный NVIDIA 610.43.03;
  это **не** отключает автоматическую установку CUDA.
- `--install-userspace`: флаг совместимости; установка userspace уже включена
  по умолчанию.
- `--no-enable-service`: установить без включения Gen2-служб и демона.
- `--allow-unsupported-host`: экспериментальная установка на другой ОС/ядре.
- `--help`: встроенная справка.

Переменные окружения:

- `CMP90_STATE_DIR`: другой каталог для исходников, загрузок и резервных копий.
- `CMP90_CUDA_ROOT`: абсолютный путь к отдельному каталогу Toolkit;
  по умолчанию `/usr/local/cuda-13.3`.
- `CMP90_GEN2_REF`: другой **полный commit hash** Rhonstin; изменение отменяет
  воспроизводимость проверенной конфигурации.

Пример передачи окружения через `sudo`:

```bash
sudo env CMP90_STATE_DIR=/srv/cmp90hx-work \
  CMP90_CUDA_ROOT=/usr/local/cuda-13.3 ./unlock_cmp90hx.sh install
```

Несовместимый или неполный существующий каталог CUDA не перезаписывается.
В `version.json` выпуск 13.3 может иметь SDK-версию `13.3.20260519`, а `nvcc`
— `13.3.33`; эти внутренние номера не обязаны совпадать с `13.3.0`.
Поле CUDA в `nvidia-smi` не подтверждает наличие установленного Toolkit.
Скрипт не настраивает глобальные `PATH`/`LD_LIBRARY_PATH`.

На CachyOS CUDA runfile запускается с `--override` для установочных проверок.
Это не делает GCC 16 совместимым с `nvcc`: для сборки CUDA-кода отдельно
выберите поддерживаемый host compiler, например GCC 15. Компилятор модуля
ядра и host compiler CUDA — разные настройки.

## Загрузка и энергопотребление

Fast выполняет compute prime, GEN2CHAIN-записи индексов **33 (FEAT)** и
**0 (XVE)**, late-config **34**, затем hammer и проверку фактического link.
Если остаётся Gen1, но GPU отвечает, используется полный проход **0–33**.
После ошибок MMIO, consume/unload или неотвечающего GPU fallback не запускается.
PCI reset, FLR/SBR и remove/rescan в fast-wrapper не применяются.

Gen2-службы — `oneshot` с `RemainAfterExit=yes`: успешное состояние
`active (exited)` нормально. Демон запускается только если одна из этих
служб активна. Простого включения unit через `enable` для этого недостаточно.

`nvidia-pstated-cmp90hx.service` работает в clock-mode:

- опрос примерно каждые 100 мс;
- после примерно 60 секунд нулевой GPU utilization — частоты GPU/памяти
  **210/405 МГц**;
- при ненулевой GPU utilization — снятие ограничений частот, а не установка
  фиксированной максимальной частоты;
- перед запуском восстанавливается **default power limit**, считанный с карты,
  чтобы прежнее ограничение 120 Вт от `gpu-idle` не осталось незаметно.

Это реакция на измеренную utilization, не планировщик задач и не интеграция
с очередью inference-сервера. Короткие всплески могут быть пропущены между
опросами. Стандартная служба не устанавливает fan helpers и не заменяет
контроль температуры/охлаждения. Не используйте параллельно другие скрипты,
меняющие те же ограничения частот или power limit.

На тестовой карте ручное ограничение памяти 405 МГц снизило idle с примерно
75 Вт до 12 Вт (P8). Это не гарантия результата демона на другой системе.

## Проверка и диагностика

```bash
sudo ./unlock_cmp90hx.sh verify
systemctl status cmp90hx-gen2-fast.service nvidia-pstated-cmp90hx.service
journalctl -b -u cmp90hx-gen2-fast.service --no-pager
journalctl -b -u nvidia-pstated-cmp90hx.service --no-pager
nvidia-smi --query-gpu=pstate,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu --format=csv
```

Признаки успешного fast: `FAST_SUCCESS`, link **5.0 GT/s** и Gen2 в PCIe
LnkSta. `FULL_FALLBACK` + `FALLBACK_SUCCESS` означает успех полного пути,
а не короткого. Ширина x4 на проверенной карте не означает ошибку: скрипт
разблокирует поколение link, не обещает x16.

Compute-маркер PLM и видимость GPU в `nvidia-smi` не являются измерением
производительности. Проверьте обычную вычислительную задачу и сравните скорость.
`verify` — отчёт, а не исчерпывающий автоматический acceptance test.

Журналы в `/var/log`:

- `cmp90hx-gen2-fast.log`;
- `cmp90hx-gen2-fast-consume.log`, `cmp90hx-gen2-fast-hammer.log`;
- `cmp90hx-gen2-fast-fallback-consume.log`, `cmp90hx-gen2-fast-fallback-hammer.log`;
- `cmp90hx-gen2-consume.log`, `cmp90hx-gen2-hammer.log` для полного режима.

`audit: STILL LOCKED` с пустыми значениями `()` означает, что аудит не получил
читаемых значений; такая строка сама по себе не опровергает Gen2. Сопоставляйте
in-driver readback, late-config, фактический link и вычислительную нагрузку.

Если появляется `cannot unload nvidia stack` или `insmod: File exists`,
не запускайте повторные циклы поверх текущего состояния. Проверьте:

```bash
lsmod | grep nvidia
sudo fuser -v /dev/nvidia* /dev/dri/*
journalctl -b -u cmp90hx-gen2-fast.service -u cmp90hx-gen2.service --no-pager
```

Для `fuser` может потребоваться пакет `psmisc`. Найдите клиентов GPU
(display manager, persistence daemon, compute-процессы), прежде чем решать,
что можно остановить. Сообщение об отсутствующем `nvidia-persistenced.service`
само по себе не является причиной отказа: его остановка допускает отсутствие unit.

Возврат к полному режиму:

```bash
sudo ./unlock_cmp90hx.sh enable-full
sudo systemctl poweroff
```

Затем снова холодное включение после >=60 секунд без питания карты.
Подробности эксперимента: [GEN2-FAST-TEST.md](GEN2-FAST-TEST.md).

Отключение управления частотами:

```bash
sudo systemctl disable --now nvidia-pstated-cmp90hx.service
```

При активной успешной Gen2-службе `ExecStopPost` пытается снять ограничения
памяти и GPU. Если они остались и карта исправно отвечает, снимите вручную,
подставив её фактический BDF:

```bash
sudo nvidia-smi -i 0000:01:00.0 -rmc
sudo nvidia-smi -i 0000:01:00.0 -rgc
```

## Обновления и расположение файлов

Модули устанавливаются для **текущего** ядра в
`/lib/modules/<kernel>/updates/cmpunlocker-90hx-stockflow/`.
В обычном режиме для нового ядра нужны соответствующие headers и повторный
`install`. В экспериментальном DKMS-режиме пересборка выполняется пакетными
хуками при установке ядра/headers; перед перезагрузкой проверьте `dkms status`.
Разрешены только ветки 6.12 и 6.18. Сохраните рабочее старое ядро как вариант
загрузки; DKMS не исправляет несовместимость исходников с новым API ядра.

Runtime располагается в `/usr/local/libexec/cmp90hx-gen2/`, демон —
`/usr/local/bin/nvidia-pstated`, units — в `/etc/systemd/system/`.
Blacklist nouveau: `/etc/modprobe.d/cmp90hx-disable-nouveau.conf`.
Прежние compute-only модули из `updates/cmpunlocker/`, если найдены,
перемещаются в рабочий каталог резервных копий. Это не полный backup драйвера
или системы. Универсальной команды uninstall/rollback нет.

## Исходники и воспроизводимость

Проекты и дистрибутивы, непосредственно используемые установщиком:

- [Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock](https://github.com/Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock):
  объединённые патчи, сборщик и исходный consume/hammer runtime;
  commit `c94505635a2ef6883678b990a7dd9e4efe15ed0d`.
- [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules/tree/610.43.03):
  исходники модулей версии `610.43.03`, скачиваемые сборщиком Rhonstin.
- [NVIDIA Linux Driver 610.43.03](https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/):
  официальный runfile для userspace и GSP firmware; kernel modules из него
  не устанавливаются.
- [NVIDIA CUDA Toolkit](https://developer.nvidia.com/cuda-toolkit):
  при отсутствии Toolkit скачивается
  [runfile 13.3.0 для Linux x86_64](https://developer.download.nvidia.com/compute/cuda/13.3.0/local_installers/cuda_13.3.0_610.43.02_linux.run)
  и устанавливается только Toolkit.
- [PabloSoage/nvidia-pstated](https://github.com/PabloSoage/nvidia-pstated):
  демон переключения idle/load частот;
  commit `3a3f86a5c83043e36e78df20c7919c53faa1a2e1`.

Авторство, происхождение compute/PCIe-патчей и идеи сокращённого прохода
описаны в [CREDITS.md](CREDITS.md).

Документация NVIDIA:

- [NVIDIA CUDA 13.3.0: контрольные суммы](https://developer.download.nvidia.com/compute/cuda/13.3.0/docs/sidebar/md5sum.txt).
- [NVIDIA CUDA 13.3: инструкция Linux](https://docs.nvidia.com/cuda/archive/13.3.0/cuda-installation-guide-linux/index.html).

Исходники клонируются на закреплённые commits (`detached HEAD`), чтобы
изменения upstream не меняли сборку незаметно. Установщик добавляет ожидаемый
Rhonstin файл `driver/VERSION` и отключает необязательный RPC tracer;
перед вызовом `build-gen2.sh` восстанавливает его executable bit.

## Проверка перед коммитом

```bash
bash -n unlock_cmp90hx.sh
```

Статус аппаратной проверки DKMS и порядок миграции описаны в
[DKMS-TEST.md](DKMS-TEST.md).

Минимальный набор для публикации этой ветки: `unlock_cmp90hx.sh`, `README.md`,
`GEN2-FAST-TEST.md`, `DKMS-TEST.md`, `CREDITS.md` и `LICENSE`.
Не включайте `cmp90hx-work`, скачанные установщики, бинарные сборки,
резервные копии модулей, локальные тесты, reference-assets и журналы.
Конечному пользователю достаточно главного скрипта. Публикуйте [MIT License](LICENSE)
вместе с кодом и соблюдайте лицензии upstream и NVIDIA EULA.
