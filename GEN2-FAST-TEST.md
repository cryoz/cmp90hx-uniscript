# Холодный тест сокращённого GEN2CHAIN

Эксперимент для одной CMP 90HX на уже установленном NVIDIA Open 610.43.03
с GEN2CHAIN. Драйвер не пересобирается и REJOIN16 не устанавливается.
Это проверка идеи двух масок из pwner, не точная реализация его алгоритма.

Используйте обновлённый `unlock_cmp90hx.sh`.
Fast wrapper и unit теперь встроены в установщик. Полный `install` включает
fast по умолчанию и также устанавливает nvidia-pstated. Команды ниже позволяют
установить/переключить fast отдельно, без пересборки драйвера.

```bash
chmod +x unlock_cmp90hx.sh
sudo ./unlock_cmp90hx.sh install-fast
sudo ./unlock_cmp90hx.sh enable-fast
sudo systemctl poweroff
```

Подождите >=60 секунд и включите систему. Не используйте `systemctl start`
для первого теста: после полного прохода маски уже открыты, и такой тест не
докажет достаточность короткого прохода после потери питания.

`install-fast` не меняет выбранную boot-службу. `enable-fast` отключает
основную службу `cmp90hx-gen2.service` только для следующих загрузок и включает
экспериментальную `cmp90hx-gen2-fast.service`;
текущую работу GPU не останавливает. Основная служба дополнительно защищена
от запуска, пока выбран fast-режим. Перед переключением дождитесь окончания
любого выполняющегося прохода.

## Алгоритм

1. Штатный compute prime.
2. Проверенный consume с прежней проверкой BAR0/SS0/SS1, но только индексы
   **33 (FEAT 0x00823800), 0 (XVE 0x00088fe8)**.
3. Прежний late-config: индекс **34**. Затем hammer.
4. Проверка фактических 5.0 GT/s в sysfs и Gen2 в PCIe LnkSta.
5. Если остаётся Gen1 и GPU отвечает на `nvidia-smi`, полный прежний
   проход 0..33, late-config и hammer.

Нет PCI reset, FLR/SBR и remove/rescan. После abort consume, ошибки MMIO,
выгрузки модуля или неотвечающего GPU fallback не выполняется.
Наличие устройства в `nvidia-smi` не измеряет производительность compute;
после первого успешного теста сравните свой compute/llama-bench benchmark.

## Результат

```bash
systemctl status cmp90hx-gen2-fast.service
journalctl -b -u cmp90hx-gen2-fast.service --no-pager
cat /var/log/cmp90hx-gen2-fast.log
sudo ./unlock_cmp90hx.sh verify
```

- `FAST_SUCCESS` — Gen2 подтверждён после двух записей без полного прохода.
- `FULL_FALLBACK`, затем `FALLBACK_SUCCESS` — две маски оказались недостаточны
  в этом запуске; Gen2 получен полным проходом.
- `ABORT`/`FAIL` — тест неуспешен; не запускайте повторные reset/reload циклы
  при зависании. Верните полный режим и сделайте холодное выключение.

В каждой строке `[fast +Ns]` указано время от начала запуска. Для сравнения
результатов важны несколько холодных включений, а не один warm reboot.

Отдельные журналы: `cmp90hx-gen2-fast-consume.log`,
`cmp90hx-gen2-fast-hammer.log`, а при fallback также
`cmp90hx-gen2-fast-fallback-consume.log` и
`cmp90hx-gen2-fast-fallback-hammer.log` в `/var/log`.

## Возврат к основной службе

```bash
sudo ./unlock_cmp90hx.sh enable-full
sudo systemctl poweroff
```

Подождите >=60 секунд. Экспериментальные файлы останутся на диске, но fast-служба
будет отключена. Текущий `repair-runtime` обновляет и полный runtime, и
отдельную короткую копию consume; повторный `install-fast` после него не нужен.
