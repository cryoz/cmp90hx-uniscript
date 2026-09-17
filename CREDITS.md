# Credits

`unlock_cmp90hx.sh` автоматизирует установку и адаптацию существующих решений
для одной CMP 90HX на CachyOS и Debian 13. Он не является авторской реализацией
самих compute/PCIe-разблокировок. Ниже разделены используемые зависимости,
происхождение патчей и источники идей.

## Используемые проекты

- [Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock](https://github.com/Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock)
  — объединённые патчи compute + PCIe Gen2, `driver/build-gen2.sh`, исходные
  consume/hammer-скрипты. Установщик использует commit
  `c94505635a2ef6883678b990a7dd9e4efe15ed0d`.
- [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules/tree/610.43.03)
  — исходники модулей NVIDIA Open версии `610.43.03`, скачиваемые сборщиком
  Rhonstin и используемые для патченной сборки.
- [NVIDIA Linux Driver](https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/)
  — официальный userspace и GSP firmware `610.43.03`. Runfile запускается
  с `--no-kernel-modules`.
- [NVIDIA CUDA Toolkit](https://developer.nvidia.com/cuda-toolkit)
  — инструменты и development-файлы CUDA. Для новой установки используется
  официальный [runfile 13.3.0 для Linux x86_64](https://developer.download.nvidia.com/compute/cuda/13.3.0/local_installers/cuda_13.3.0_610.43.02_linux.run)
  в режиме toolkit-only.
- [PabloSoage/nvidia-pstated](https://github.com/PabloSoage/nvidia-pstated)
  — демон автоматического переключения idle/load частот. Используется commit
  `3a3f86a5c83043e36e78df20c7919c53faa1a2e1`.

## Происхождение разблокировок и идеи fast

- [pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker)
  — compute stockflow/rejoin15: V67 и настройка SS0/SS1, включённые в сборку
  Rhonstin; также источник формы Gen2 retrain для 50HX.
- [NatsumeAi/CMP-90HX-Compute-PCIE2.0-unlock](https://github.com/NatsumeAi/CMP-90HX-Compute-PCIE2.0-unlock)
  — upstream, от которого ответвился используемый репозиторий Rhonstin.
- [WildFlash1st/cmp90hx-unlock](https://github.com/WildFlash1st/cmp90hx-unlock)
  — compute-разблокировка, использовавшаяся при первоначальном исследовании.
  Текущий установщик не клонирует этот проект и не применяет его отдельно.
- [iatethelogs/cmp90hx_pwner](https://github.com/iatethelogs/cmp90hx_pwner)
  — источник идеи сокращённого прохода по двум маскам. Наш fast-путь остаётся
  на GEN2CHAIN из Rhonstin, не устанавливает pwner и не воспроизводит его
  REJOIN16-алгоритм целиком.

В [CREDITS.md закреплённой версии Rhonstin](https://github.com/Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock/blob/c94505635a2ef6883678b990a7dd9e4efe15ed0d/CREDITS.md)
также указаны:

- **jdowning100 / rejoin16** — таблица из 34 PCIe privilege masks,
  in-kernel speed-path writes и проверка на версиях VBIOS `.01` / `.05`.
- **bendy2 / amoghmunikote** — Booter-time speed path для 170HX.
- **studebaker8/cmp170hx-gen2** — retrain-link hammer до подтверждения Gen2
  в LnkSta.

Эти вклады перечислены по upstream credits; отдельные установщики этих
авторов текущий скрипт не запускает.

## Локальная интеграция

Дополнения в этом установщике: проверки ОС и toolchain, установка userspace
и CUDA, runtime-адаптация BAR0/SS, experimental fast-проход с полным fallback,
systemd-службы и настройка `nvidia-pstated` для одной карты.
Авторство underlying патчей и демона остаётся за соответствующими проектами.

## Лицензии

Собственный код этого репозитория распространяется по [MIT License](LICENSE).
Этот файл фиксирует авторство, но не заменяет лицензии и не предоставляет
разрешение на распространение стороннего кода или бинарных файлов. Соблюдайте
лицензии используемых upstream-проектов и NVIDIA EULA.
