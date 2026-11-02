#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# CMP 90HX: compute + PCIe Gen2 unlock installer for CachyOS and Debian 13.
# Targets: linux-cachyos-lts 6.18 or Debian 13 kernel 6.12,
# NVIDIA Open 610.43.03, PCI ID 10de:220d.
set -Eeuo pipefail

readonly DRIVER_VERSION="610.43.03"
readonly GEN2_URL="https://github.com/Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock.git"
readonly GEN2_REF="${CMP90_GEN2_REF:-c94505635a2ef6883678b990a7dd9e4efe15ed0d}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="${CMP90_STATE_DIR:-$SCRIPT_DIR/cmp90hx-work}"
readonly RUNTIME_DIR="/usr/local/libexec/cmp90hx-gen2"
readonly SERVICE_FILE="/etc/systemd/system/cmp90hx-gen2.service"
readonly PSTATED_URL="https://github.com/PabloSoage/nvidia-pstated.git"
readonly PSTATED_REF="3a3f86a5c83043e36e78df20c7919c53faa1a2e1"
readonly CUDA_ROOT="${CMP90_CUDA_ROOT:-/usr/local/cuda-13.3}"
readonly CUDA_VERSION="13.3.0"
readonly CUDA_RUNFILE="cuda_13.3.0_610.43.02_linux.run"
readonly CUDA_URL="https://developer.download.nvidia.com/compute/cuda/13.3.0/local_installers/$CUDA_RUNFILE"
# Published by NVIDIA: compute/cuda/13.3.0/docs/sidebar/md5sum.txt
readonly CUDA_MD5="16d68669cf659157777d2e7adaff179d"
readonly DKMS_NAME="cmp90hx-nvidia"
readonly DKMS_VERSION="$DRIVER_VERSION-gen2.1"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi
info() { printf '%b[INFO]%b %s\n' "$CYAN" "$NC" "$*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

ACTION="install"
INSTALL_USERSPACE=1
USE_DKMS=0
ENABLE_SERVICE=1
ALLOW_UNSUPPORTED=0
HOST_PROFILE="unknown"
HOST_PRETTY="unknown"

usage() {
    cat <<'EOF'
Usage:
  sudo ./unlock_cmp90hx.sh [install] [options]
  sudo ./unlock_cmp90hx.sh apply
  sudo ./unlock_cmp90hx.sh repair-runtime
  sudo ./unlock_cmp90hx.sh install-fast
  sudo ./unlock_cmp90hx.sh enable-fast
  sudo ./unlock_cmp90hx.sh enable-full
  sudo ./unlock_cmp90hx.sh install-pstated
  sudo ./unlock_cmp90hx.sh install-dkms
  ./unlock_cmp90hx.sh verify

Actions:
  install                 Install NVIDIA, compute+fast Gen2 and nvidia-pstated
  apply                   Run the installed Gen2 consume+retrain pass now
  repair-runtime          Reinstall boot scripts/service without rebuilding
  install-fast            Install disabled experimental two-mask boot service
  enable-fast             Select fast service for NEXT boot (no immediate apply)
  enable-full             Restore full service for NEXT boot
  install-pstated          Build/install clock daemon and its boot service only
  install-dkms             Migrate installed compute+Gen2 modules to DKMS (experimental)
  verify                  Report driver, compute log markers and PCIe link

Options for install:
  --dkms                  Build/install modules through DKMS (experimental)
  --install-userspace     Compatibility flag; driver installation is now default
  --no-install-userspace  Require existing NVIDIA 610.43.03 userspace/firmware
  --no-enable-service     Install but disable full/fast Gen2 and clock daemon
  --allow-unsupported-host
                          Allow an unsupported OS/kernel pair (experimental)
  -h, --help              Show this help

Environment overrides:
  CMP90_STATE_DIR, CMP90_GEN2_REF, CMP90_CUDA_ROOT

Supported hosts:
  CachyOS/Arch with linux-cachyos-lts 6.18
  Debian 13 with the stock 6.12 kernel

Build sources, downloads and backups are kept in ./cmp90hx-work next to this
script by default. CMP90_STATE_DIR can place that working tree elsewhere.

The PCIe privilege masks re-lock after a real power loss. The installed
fast service re-applies Gen2 at boot, with a full-walk fallback. nvidia-pstated
starts after Gen2, sets idle clocks to 210/405 MHz after about 60 seconds,
and restores default clocks when utilization becomes nonzero.
CUDA Toolkit 13.3.0 is checked and installed automatically if absent
(toolkit-only NVIDIA runfile; default: /usr/local/cuda-13.3).
Automatic boot operation deliberately
supports one CMP 90HX only; multi-GPU fleets need the upstream isolation flow.
EOF
}

for arg in "$@"; do
    case "$arg" in
        install|apply|repair-runtime|verify|install-fast|enable-fast|enable-full|install-pstated|install-dkms) ACTION="$arg" ;;
        --dkms) USE_DKMS=1 ;;
        --install-userspace) INSTALL_USERSPACE=1 ;;
        --no-install-userspace) INSTALL_USERSPACE=0 ;;
        --no-enable-service) ENABLE_SERVICE=0 ;;
        --allow-unsupported-host) ALLOW_UNSUPPORTED=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Неизвестный аргумент: $arg (см. --help)" ;;
    esac
done

require_root() {
    [[ $EUID -eq 0 ]] || die "Запустите от root: sudo $0 $ACTION"
}

ensure_no_unlock_in_progress() {
    local unit state
    for unit in cmp90hx-gen2.service cmp90hx-gen2-fast.service; do
        state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
        [[ "$state" != activating && "$state" != deactivating ]] || die "Сейчас выполняется $unit; дождитесь завершения"
    done
}

detect_host_profile() {
    local os_id="" os_like="" version_id=""
    HOST_PROFILE="unsupported"
    HOST_PRETTY="unknown"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
        version_id="${VERSION_ID:-}"
        HOST_PRETTY="${PRETTY_NAME:-unknown}"
    fi

    if [[ "$os_id" == "cachyos" || " $os_like " == *" arch "* ]]; then
        HOST_PROFILE="cachyos"
    elif [[ "$os_id" == "debian" && "$version_id" =~ ^13([.]|$) ]]; then
        HOST_PROFILE="debian13"
    fi
}

require_commands() {
    local missing=() cmd hint
    detect_host_profile
    for cmd in bash git curl patch make python3 lspci setpci cc awk grep install lsmod \
        timeout insmod modprobe systemctl journalctl modinfo depmod ldconfig flock md5sum; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ "$HOST_PROFILE" == "debian13" ]]; then
        command -v update-initramfs >/dev/null 2>&1 || missing+=("update-initramfs")
        if [[ -d /sys/firmware/efi/efivars ]]; then
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
        fi
        hint="apt update && apt install build-essential git curl patch python3 pciutils kmod initramfs-tools mokutil linux-headers-$(uname -r)"
    else
        hint="pacman -S --needed base-devel git curl python pciutils linux-cachyos-lts-headers"
    fi
    if ((${#missing[@]})); then
        die "Не найдены команды: ${missing[*]}. Установите от root: $hint"
    fi
}

host_preflight() {
    local kver expected headers_hint
    kver="$(uname -r)"
    detect_host_profile
    info "Хост: $HOST_PRETTY; ядро: $kver"
    [[ "$(uname -m)" == "x86_64" ]] || die "Поддерживается только архитектура x86_64"

    case "$HOST_PROFILE" in
        cachyos)
            expected='6.18 linux-cachyos-lts'
            headers_hint='linux-cachyos-lts-headers'
            [[ "$kver" =~ ^6\.18([.-]|$) ]] || {
                ((ALLOW_UNSUPPORTED)) || die "Для CachyOS ожидалось ядро $expected, найдено $kver"
                warn "Непроверенная версия ядра: $kver"
            }
            ;;
        debian13)
            expected='штатное ядро Debian 13 ветки 6.12'
            headers_hint="linux-headers-$kver"
            [[ "$kver" =~ ^6\.12([.+-]|$) ]] || {
                ((ALLOW_UNSUPPORTED)) || die "Для Debian 13 ожидалось $expected, найдено $kver"
                warn "Непроверенная версия ядра Debian 13: $kver"
            }
            ;;
        *)
            ((ALLOW_UNSUPPORTED)) || die "Поддерживаются CachyOS/Arch с ядром 6.18 и Debian 13 с ядром 6.12. Для эксперимента используйте --allow-unsupported-host"
            headers_hint="заголовки для $kver"
            warn "Непроверенная ОС: $HOST_PRETTY"
            ;;
    esac
    [[ -d "/lib/modules/$kver/build" ]] ||
        die "Нет заголовков для $kver. Установите $headers_hint и загрузитесь в соответствующее ядро"

    if [[ -d /sys/firmware/efi/efivars ]]; then
        if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
            die "Secure Boot включён; неподписанные модифицированные модули не загрузятся"
        fi
    fi
}

detect_cards() {
    mapfile -t CMP90_BDFS < <(lspci -Dnn -d 10de:220d 2>/dev/null | awk '{print $1}')
    ((${#CMP90_BDFS[@]} > 0)) || die "CMP 90HX с PCI ID 10de:220d не найдена"
    info "CMP 90HX: ${CMP90_BDFS[*]}"
    if ((${#CMP90_BDFS[@]} > 1)); then
        die "Обнаружено ${#CMP90_BDFS[@]} карт. Безопасная автоматизация этого скрипта рассчитана на одну карту; для нескольких используйте scripts/fleet/chain-blockall.sh из Gen2-репозитория"
    fi
}

prepare_driver_environment() {
    local nouveau_conf="/etc/modprobe.d/cmp90hx-disable-nouveau.conf"
    [[ "$HOST_PROFILE" == "debian13" || "$HOST_PROFILE" == "cachyos" ]] || return 0

    install -d -m 0755 /etc/modprobe.d
    if [[ ! -f "$nouveau_conf" ]] ||
       ! grep -qx 'blacklist nouveau' "$nouveau_conf" ||
       ! grep -qx 'options nouveau modeset=0' "$nouveau_conf"; then
        printf '%s\n' 'blacklist nouveau' 'options nouveau modeset=0' >"$nouveau_conf"
        chmod 0644 "$nouveau_conf"
        info "Установлен запрет nouveau: $nouveau_conf"
    fi

    if lsmod | grep -q '^nouveau '; then
        if [[ "$HOST_PROFILE" == "debian13" ]]; then
            update-initramfs -u -k "$(uname -r)"
        else
            command -v mkinitcpio >/dev/null || die "Нужно обновить initramfs после blacklist nouveau; установите mkinitcpio"
            mkinitcpio -P
        fi
        die "Сейчас загружен nouveau. Его blacklist добавлен в initramfs; перезагрузите систему и повторите install"
    fi
}

driver_version() {
    local v=""
    if [[ -r /proc/driver/nvidia/version ]]; then
        v="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1 || true)"
    fi
    if [[ -z "$v" ]] && command -v nvidia-smi >/dev/null 2>&1; then
        v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    fi
    printf '%s' "$v"
}

install_userspace_if_needed() {
    local detected runfile url file owned=0
    # Query userspace without requiring a loaded GPU module. A fresh install
    # may have correct libraries but no running kernel driver yet.
    # NVML reports only major.minor (e.g. 610.43), not the package patch
    # version. NVIDIA-SMI reports the complete userspace release without
    # needing a loaded kernel module.
    detected="$(nvidia-smi --version 2>/dev/null | awk '/^NVIDIA-SMI version/ {print $NF; exit}' || true)"
    if [[ "$detected" == "$DRIVER_VERSION" && -f "/lib/firmware/nvidia/$DRIVER_VERSION/gsp_ga10x.bin" ]] &&
       ldconfig -p | grep -F 'libnvidia-api.so.1' >/dev/null; then
        ok "NVIDIA userspace и GSP firmware $DRIVER_VERSION найдены"
        return
    fi

    if (( ! INSTALL_USERSPACE )); then
        die "Нужны NVIDIA userspace, NVAPI и GSP firmware $DRIVER_VERSION (найден userspace: ${detected:-нет}). Уберите --no-install-userspace"
    fi

    for file in "$(command -v nvidia-smi || true)" \
        "$(ldconfig -p | awk '/libnvidia-ml.so.1 / && !seen++ {print $NF}')"; do
        [[ -n "$file" ]] || continue
        if command -v pacman >/dev/null && pacman -Qo "$file" >/dev/null 2>&1; then owned=1; fi
        if command -v dpkg-query >/dev/null && dpkg-query -S "$file" >/dev/null 2>&1; then owned=1; fi
    done
    (( ! owned )) || die "Пакетный NVIDIA userspace несовместим или неполон. Нельзя накладывать .run: сначала разберите пакетный NVIDIA-стек; автоматически он не удаляется"

    warn "NVIDIA .run устанавливает userspace вне пакетного менеджера; обновление nvidia-utils/пакетов NVIDIA может его заменить"
    mkdir -p "$STATE_DIR/downloads"
    runfile="$STATE_DIR/downloads/NVIDIA-Linux-x86_64-$DRIVER_VERSION.run"
    url="https://download.nvidia.com/XFree86/Linux-x86_64/$DRIVER_VERSION/NVIDIA-Linux-x86_64-$DRIVER_VERSION.run"
    if [[ ! -s "$runfile" ]]; then
        info "Загрузка NVIDIA userspace $DRIVER_VERSION"
        curl --fail --location --output "$runfile.part" "$url"
        mv "$runfile.part" "$runfile"
    fi
    chmod 0755 "$runfile"
    "$runfile" --silent --no-kernel-modules
    [[ -f "/lib/firmware/nvidia/$DRIVER_VERSION/gsp_ga10x.bin" ]] ||
        die "После установки отсутствует /lib/firmware/nvidia/$DRIVER_VERSION/gsp_ga10x.bin"
    ldconfig
    detected="$(nvidia-smi --version 2>/dev/null | awk '/^NVIDIA-SMI version/ {print $NF; exit}' || true)"
    [[ "$detected" == "$DRIVER_VERSION" ]] || die "После .run обнаружен NVIDIA-SMI $detected, ожидался $DRIVER_VERSION"
    ok "NVIDIA userspace и GSP firmware $DRIVER_VERSION установлены"
}

checkout_repo() {
    local url="$1" ref="$2" dest="$3"
    if [[ ! -d "$dest/.git" ]]; then
        [[ ! -e "$dest" ]] || die "$dest существует, но не является git-репозиторием"
        git clone "$url" "$dest"
    fi
    if ! git -C "$dest" cat-file -e "$ref^{commit}" 2>/dev/null; then
        git -C "$dest" fetch --tags origin
    fi
    git -C "$dest" checkout --detach "$ref"
    [[ "$(git -C "$dest" rev-parse HEAD)" == "$ref" ]] || die "Не удалось зафиксировать $dest на $ref"
}

select_toolchain() {
    local config="/lib/modules/$(uname -r)/build/.config" gcc_version gcc_major
    [[ -r "$config" ]] || config="/boot/config-$(uname -r)"
    if [[ -r "$config" ]] && grep -qx 'CONFIG_CC_IS_CLANG=y' "$config"; then
        command -v clang >/dev/null && command -v ld.lld >/dev/null ||
            die "Ядро собрано Clang, но clang/ld.lld не установлены"
        BUILD_CC="clang"; BUILD_LD="ld.lld"
    else
        command -v gcc >/dev/null || die "Для сборки модуля требуется GCC"
        BUILD_CC="gcc"
        gcc_version="$(sed -n 's/^CONFIG_GCC_VERSION=//p' "$config" 2>/dev/null || true)"
        if [[ "$gcc_version" =~ ^[0-9]+$ ]] && ((gcc_version > 0)); then
            gcc_major=$((gcc_version / 10000))
            if command -v "gcc-$gcc_major" >/dev/null; then
                BUILD_CC="gcc-$gcc_major"
            elif [[ "$(gcc -dumpversion | cut -d. -f1)" != "$gcc_major" ]]; then
                die "Ядро собрано GCC $gcc_major; установите gcc-$gcc_major (в CachyOS пакет gcc$gcc_major)"
            fi
        fi
        if command -v ld.bfd >/dev/null; then BUILD_LD="ld.bfd"; else BUILD_LD="ld"; fi
    fi
    info "Компилятор модулей: $($BUILD_CC --version | head -1); линкер: $BUILD_LD"
}

patched_module_path() {
    local path
    path="$(modinfo -k "$(uname -r)" -n nvidia 2>/dev/null)" || return 1
    [[ -f "$path" ]] || return 1
    modinfo -p "$path" | grep -q '^cmp90_gen2_idx:' || return 1
    printf '%s\n' "$path"
}

refresh_initramfs() {
    local kver="$(uname -r)" resolved
    depmod -a "$kver"
    resolved="$(patched_module_path || true)"
    if [[ -z "$resolved" ]]; then
        die "После depmod выбран неожиданный модуль nvidia: ${resolved:-не найден}"
    fi

    if [[ "$HOST_PROFILE" == "debian13" ]]; then
        info "Обновление initramfs Debian для $kver"
        update-initramfs -u -k "$kver"
    elif ((USE_DKMS)); then
        mkinitcpio -P
    fi
}

backup_compute_only_modules() {
    local old="/lib/modules/$(uname -r)/updates/cmpunlocker" backup
    [[ -d "$old" ]] || return 0
    backup="$STATE_DIR/backups/$(uname -r)-compute-only-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")"
    mv "$old" "$backup"
    MOVED_OLD_MODULES="$backup"
    warn "Compute-only модули перемещены в $backup, чтобы depmod не выбрал их вместо Gen2"
}

install_runtime() {
    local gen2="$1"
    install -d -m 0755 "$RUNTIME_DIR"
    install -m 0755 "$gen2/scripts/cmp90hx-gen2-consume.sh" "$RUNTIME_DIR/"
    install -m 0755 "$gen2/scripts/cmp90hx-gen2-hammer.sh" "$RUNTIME_DIR/"
    cc -O2 -Wall -Wextra -o "$RUNTIME_DIR/bar0rw" "$gen2/scripts/bar0rw.c"

    # The tested AMD host disables PCI Memory Space when the
    # NVIDIA driver unbinds. Raw BAR0 then reads as all-ones and writes vanish.
    # Wake the function and re-enable MMIO before every userspace BAR0 access.
    python3 - "$RUNTIME_DIR/cmp90hx-gen2-consume.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '''ss_zero() {
    "$POKE" "$BDF" wr 0x0082381c 0x0 >/dev/null
    "$POKE" "$BDF" wr 0x00823820 0x0 >/dev/null
}

bar0_rd() { "$POKE" "$BDF" rd "$1" 2>/dev/null || echo "unreadable"; }
'''
new = '''prepare_bar0() {
    local dev="${1:-$BDF}"
    if [[ -w "/sys/bus/pci/devices/$dev/power/control" ]]; then
        echo on >"/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
    fi
    if setpci -s "$dev" CAP_PM+4.w >/dev/null 2>&1; then
        setpci -s "$dev" CAP_PM+4.w=0000:0003 2>/dev/null || true
    fi
    setpci -s "$dev" COMMAND=0002:0002
    sleep 0.1
}

ss_zero() {
    local ss0 ss1
    prepare_bar0 "$BDF"
    "$POKE" "$BDF" wr 0x0082381c 0x0 >/dev/null
    "$POKE" "$BDF" wr 0x00823820 0x0 >/dev/null
    ss0="$("$POKE" "$BDF" rd 0x0082381c 2>/dev/null || true)"
    ss1="$("$POKE" "$BDF" rd 0x00823820 2>/dev/null || true)"
    if [[ "$ss0" != "0x00000000" || "$ss1" != "0x00000000" ]]; then
        die_hang "BAR0 write verification failed: SS0=${ss0:-unreadable} SS1=${ss1:-unreadable}"
    fi
}

bar0_rd() {
    prepare_bar0 "$BDF"
    "$POKE" "$BDF" rd "$1" 2>/dev/null || echo "unreadable"
}
'''
if new in text:
    raise SystemExit(0)
if old not in text:
    raise SystemExit("consume.sh BAR0 patch point not found")
path.write_text(text.replace(old, new, 1))
PY
    # DKMS can select a distro-specific directory and compress modules.
    # Use kmod's resolved path in both full and fast copies, not a fixed .ko.
    python3 - "$RUNTIME_DIR/cmp90hx-gen2-consume.sh" <<'MODULE_PATH'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = 'KO="${CMP90_NVIDIA_KO:-/lib/modules/${KVER}/updates/cmpunlocker-90hx-stockflow/nvidia.ko}"'
new = 'KO="${CMP90_NVIDIA_KO:-$(modinfo -k "$KVER" -n nvidia)}"\nmodinfo -p "$KO" | grep -q "^cmp90_gen2_idx:" || { echo "Wrong NVIDIA module: $KO" >&2; exit 2; }'
if t.count(old) != 1:
    raise SystemExit('consume module-path patch point not found')
p.write_text(t.replace(old, new))
MODULE_PATH
    chmod 0755 "$RUNTIME_DIR/cmp90hx-gen2-consume.sh"

    # On a minimal/headless installation nothing necessarily opens
    # /dev/nvidia before this service. Ensure that the patched module is loaded
    # and open one RM client. consume.sh will quiesce udev and unload it before
    # auditing FEAT; doing that here as well races module auto-loading.
    cat >"$RUNTIME_DIR/cmp90hx-compute-prime.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
KVER="$(uname -r)"
KO="$(modinfo -k "$KVER" -n nvidia)"
modinfo -p "$KO" | grep -q '^cmp90_gen2_idx:' || { echo "CMP90 prime: wrong NVIDIA module" >&2; exit 2; }
BDF="$(lspci -Dnn -d 10de:220d | awk 'NR == 1 {print $1}')"
[[ -n "$BDF" && -f "$KO" ]] || { echo "CMP90 prime: card or module missing" >&2; exit 2; }
if [[ ! -d /sys/module/nvidia ]]; then
    modprobe drm 2>/dev/null || true
    timeout 120s insmod "$KO" cmp90_gen2_idx=34
fi
timeout 90s nvidia-smi -L >/dev/null
echo "CMP90 prime: RM client opened; consume will verify FEAT after unload"
EOF
    chmod 0755 "$RUNTIME_DIR/cmp90hx-compute-prime.sh"

    cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=CMP 90HX compute and PCIe Gen2 unlock
Documentation=https://github.com/Rhonstin/CMP-90HX-Compute-PCIE2.0-unlock
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=nvidia-persistenced.service display-manager.service graphical.target
ConditionPathExists=/usr/local/libexec/cmp90hx-gen2/cmp90hx-gen2-consume.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/systemctl stop nvidia-persistenced.service
ExecStartPre=-/usr/bin/systemctl stop nvidia-powerd.service
# On some AMD platforms BAR0 reads as 0xffffffff while nvidia.ko is unloaded.
# That is an inaccessible MMIO window, not proof that a PLM is open. Always
# execute the complete 34-write walk and trust in-driver GEN2CHAIN readback.
Environment=CMP90_SKIP_OPEN=0
Environment=CMP90_MAX_STALL=40
Environment=CMP90_WAIT_FIRE_S=45
Environment=CMP90_CONSUME_LOG=/var/log/cmp90hx-gen2-consume.log
Environment=CMP90_HAMMER_LOG=/var/log/cmp90hx-gen2-hammer.log
ExecStart=/usr/local/libexec/cmp90hx-gen2/cmp90hx-compute-prime.sh
ExecStart=/usr/local/libexec/cmp90hx-gen2/cmp90hx-gen2-consume.sh
ExecStartPost=/usr/local/libexec/cmp90hx-gen2/cmp90hx-gen2-hammer.sh
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl is-enabled --quiet cmp90hx-gen2-fast.service; then
        systemctl disable cmp90hx-gen2.service >/dev/null 2>&1 || true
        warn "Сохранён fast-режим. После изменения consume повторите install-fast для обновления его отдельной копии"
    elif ((ENABLE_SERVICE)); then
        systemctl enable cmp90hx-gen2.service
        ok "Сервис cmp90hx-gen2.service включён"
    else
        systemctl disable cmp90hx-gen2.service >/dev/null 2>&1 || true
        warn "Сервис установлен, но не включён (--no-enable-service)"
    fi
}

verify_install() {
    local bdf speed width resolved running enabled fast_enabled
    detect_cards
    bdf="${CMP90_BDFS[0]}"
    running="$(driver_version)"
    resolved="$(modinfo -n nvidia 2>/dev/null || true)"
    speed="$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || echo unknown)"
    width="$(cat "/sys/bus/pci/devices/$bdf/current_link_width" 2>/dev/null || echo unknown)"
    enabled="$(systemctl is-enabled cmp90hx-gen2.service 2>/dev/null || true)"
    fast_enabled="$(systemctl is-enabled cmp90hx-gen2-fast.service 2>/dev/null || true)"

    printf 'Driver:       %s\n' "${running:-not loaded}"
    printf 'nvidia.ko:    %s\n' "${resolved:-not resolved}"
    printf 'PCIe link:    %s x%s (%s)\n' "$speed" "$width" "$bdf"
    printf 'Boot service: %s\n' "${enabled:-not-installed}"
    printf 'Fast service: %s (experimental)\n' "${fast_enabled:-not-installed}"

    if patched_module_path >/dev/null; then
        ok "depmod выбирает объединённый compute+Gen2 модуль"
    else
        warn "depmod не выбирает модуль с параметром GEN2CHAIN cmp90_gen2_idx"
    fi
    if command -v dkms >/dev/null; then
        dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" || true
    fi
    if [[ "$speed" == "5.0 GT/s PCIe" || "$speed" == "5.0 GT/s" ]]; then
        ok "PCIe Gen2 активен"
    else
        warn "PCIe Gen2 пока не подтверждён (нужно холодное выключение и успешный сервис)"
    fi

    if journalctl -k -b --no-pager 2>/dev/null | grep -E 'PLM=0xffffffff|FEAT_PLM_after=0xffffffff' >/dev/null; then
        ok "В журнале текущей загрузки найдено открытие compute PLM"
    else
        warn "В журнале текущей загрузки нет подтверждения compute PLM"
    fi
}

dkms_preflight() {
    command -v dkms >/dev/null || die "Установите dkms: pacman -S dkms или apt install dkms"
    if [[ "$HOST_PROFILE" == cachyos ]]; then
        command -v mkinitcpio >/dev/null || die "Для DKMS runtime нужен mkinitcpio"
    fi
    # A second DKMS package owning nvidia.ko would race our package on upgrades.
    local other
    other="$(dkms status | awk -F/ '/^nvidia[^/]*\// {print $1}' | sort -u)"
    [[ -z "$other" ]] || die "Зарегистрирован другой NVIDIA DKMS: $other. Сначала разберите конфликт владельцев модулей"
}

prepare_dkms_scripts() {
    local gen2="$1"
    # Reuse pinned upstream preparation and kernel compatibility code without
    # executing its install/depmod/initramfs/module-unload tail. Fail closed if
    # upstream changes its boundaries. Generated files retain upstream licensing.
    python3 - "$gen2/driver" <<'DKMS_SPLIT'
import pathlib, sys
driver = pathlib.Path(sys.argv[1])
t = (driver / 'build-gen2.sh').read_text()
cut = 'mkdir -p "${INSTALL_MOD_DIR}"\n'
start = 'fix_kernel_compat() {\n'
end = '# Generate conftest first\n'
if t.count(start) != 1 or t.count(end) != 1 or cut not in t:
    raise SystemExit('Unexpected upstream builder layout; refusing DKMS adaptation')
prefix = t[:t.index(cut)]
if not all(s in prefix for s in ('patch -p1', 'PROFILE_PATCH_DIR', 'Memory geometry rewrite skipped')):
    raise SystemExit('Incomplete upstream source preparation')
# Preparing source files neither needs root nor kernel headers. The DKMS
# builder checks target headers when it actually compiles the modules.
prefix = '\n'.join(line for line in prefix.split('\n')
                   if not line.startswith(('[[ "${EUID}" -eq 0 ]]', '[[ -d "${KSRC}" ]]')))
(driver / 'prepare-dkms.sh').write_text(prefix)
(driver / 'compat-dkms.sh').write_text(t[t.index(start):t.index(end)])
DKMS_SPLIT
}

write_dkms_build_script() {
    local dest="$1"
    cat >"$dest/cmp90-build.sh" <<'DKMS_BUILD'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Offline DKMS build only: never download, install, unload or start a service.
set -Eeuo pipefail
KVER="${1:?target kernel required}"
KSRC="${2:?target kernel headers required}"
JOBS="${3:-2}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=2
[[ "$KVER" =~ ^6\.(12|18)([.+-]|$) ]] || {
    echo "Untested kernel $KVER: only 6.12 and 6.18 are allowed in this experimental package" >&2
    exit 1
}
[[ -d "$KSRC" ]] || { echo "Missing headers: $KSRC" >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR"
GSP_C="$SRC_DIR/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
cd "$SRC_DIR"
config="$KSRC/.config"
[[ -r "$config" ]] || config="/boot/config-$KVER"
[[ -r "$config" ]] || { echo "Missing target kernel config" >&2; exit 1; }
if grep -qx 'CONFIG_CC_IS_CLANG=y' "$config"; then
    export CC=clang LD=ld.lld
    command -v "$CC" >/dev/null; command -v "$LD" >/dev/null
else
    version="$(sed -n 's/^CONFIG_GCC_VERSION=//p' "$config")"
    [[ "$version" =~ ^[0-9]+$ && "$version" -gt 0 ]] || { echo "Missing CONFIG_GCC_VERSION" >&2; exit 1; }
    major=$((version / 10000))
    if command -v "gcc-$major" >/dev/null; then
        export CC="gcc-$major"
    else
        [[ "$(gcc -dumpversion | cut -d. -f1)" == "$major" ]] || { echo "Need gcc-$major for $KVER" >&2; exit 1; }
        export CC=gcc
    fi
    if command -v ld.bfd >/dev/null; then export LD=ld.bfd; else export LD=ld; fi
fi
export IGNORE_CC_MISMATCH=1
export NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem"
info() { echo "[DKMS] $*"; }
ok() { info "$@"; }
warn() { info "$@" >&2; }
source "$SCRIPT_DIR/compat-dkms.sh"
find . -name '*.sh' -exec chmod +x {} +
# Same conftest/compatibility passes as the tested Rhonstin build, with
# target headers passed to EVERY make, including the first conftest pass.
make -j1 modules SYSSRC="$KSRC" SYSOUT="$KSRC" \
    KERNEL_UNAME="$KVER" \
    kernel-open/conftest/headers.h kernel-open/conftest/functions.h \
    kernel-open/conftest/types.h kernel-open/conftest/generic.h || true
fix_kernel_compat
make -j"$JOBS" modules SYSSRC="$KSRC" SYSOUT="$KSRC" KERNEL_UNAME="$KVER" || true
fix_kernel_compat
make -j"$JOBS" modules SYSSRC="$KSRC" SYSOUT="$KSRC" KERNEL_UNAME="$KVER"
for module in nvidia nvidia-uvm; do
    [[ -s "kernel-open/$module.ko" ]] || { echo "Missing $module.ko" >&2; exit 1; }
    [[ "$(modinfo -F vermagic "kernel-open/$module.ko")" == "$KVER "* ]] || {
        echo "Wrong vermagic in $module.ko (expected $KVER)" >&2; exit 1;
    }
done
grep -aq GEN2CHAIN kernel-open/nvidia.ko || { echo "GEN2CHAIN missing" >&2; exit 1; }
if grep -aq REJOIN16 kernel-open/nvidia.ko; then
    echo "Incompatible REJOIN16 marker" >&2; exit 1
fi
DKMS_BUILD
    chmod 0755 "$dest/cmp90-build.sh"
    cat >"$dest/dkms.conf" <<'DKMS_CONF'
PACKAGE_NAME="cmp90hx-nvidia"
PACKAGE_VERSION="610.43.03-gen2.1"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_KERNEL="^6\.(12|18)([.+-]|$)"
MAKE[0]="bash ./cmp90-build.sh '${kernelver}' '${kernel_source_dir}' '${parallel_jobs}'"
POST_INSTALL="cmp90-post-install.sh ${kernelver}"
CLEAN="true"
BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_NAME[1]="nvidia-uvm"
BUILT_MODULE_LOCATION[0]="kernel-open"
BUILT_MODULE_LOCATION[1]="kernel-open"
DEST_MODULE_LOCATION[0]="/updates/cmpunlocker-90hx-stockflow"
DEST_MODULE_LOCATION[1]="/updates/cmpunlocker-90hx-stockflow"
DKMS_CONF
    cat >"$dest/cmp90-post-install.sh" <<'DKMS_POST'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
target="${1:?target kernel required}"
depmod -a "$target"
# Kernel package hooks create new images; update an existing Debian image
# as well when DKMS is installed later by the matching headers package.
if command -v update-initramfs >/dev/null && [[ -f "/boot/initrd.img-$target" ]]; then
    update-initramfs -u -k "$target"
fi
# CachyOS/Arch's DKMS ALPM hook precedes its mkinitcpio hook. The initial
# migration explicitly calls refresh_initramfs after installing runtime.
DKMS_POST
    chmod 0755 "$dest/cmp90-post-install.sh"
}

install_dkms_modules() {
    local gen2="$1" src="/usr/src/$DKMS_NAME-$DKMS_VERSION"
    local registered backup="" old="/lib/modules/$(uname -r)/updates/cmpunlocker-90hx-stockflow"
    dkms_preflight
    registered="$(dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION")"
    if [[ -z "$registered" ]]; then
        [[ ! -e "$src" ]] || die "Незарегистрированный $src уже существует; не перезаписываю"
        prepare_dkms_scripts "$gen2"
        env CMPUNLOCKER_CARD_PROFILE=cmp90-rejoin15 \
            CMPUNLOCKER_DRIVER_VERSION="$DRIVER_VERSION" \
            CMPUNLOCKER_BUILD_DIR="$gen2/driver/.build" \
            bash "$gen2/driver/prepare-dkms.sh"
        local prepared="$gen2/driver/.build/open-gpu-kernel-modules-$DRIVER_VERSION"
        [[ -d "$prepared/kernel-open" ]] || die "Нет подготовленных исходников: $prepared"
        cp "$gen2/driver/compat-dkms.sh" "$prepared/"
        cp "$gen2/driver/inject_rpc_tracer.py" "$prepared/"
        if [[ -f "$gen2/LICENSE" ]]; then cp "$gen2/LICENSE" "$prepared/RHONSTIN-LICENSE"; fi
        write_dkms_build_script "$prepared"
        printf '%s\n' "$GEN2_REF" >"$prepared/cmp90-upstream-ref"
        cp -a "$prepared" "$src"
        dkms add -m "$DKMS_NAME" -v "$DKMS_VERSION"
    else
        [[ "$(cat "$src/cmp90-upstream-ref" 2>/dev/null)" == "$GEN2_REF" ]] ||
            die "Зарегистрированный DKMS использует другой upstream; не подменяю исходники существующей версии"
        # Refresh our wrapper when retrying a failed migration. NVIDIA sources
        # and upstream compatibility code stay pinned and are not downloaded.
        write_dkms_build_script "$src"
    fi
    # Reuse successful builds; no --force and no live module reload.
    local status
    status="$(dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$(uname -r)")"
    if [[ "$status" != *': installed'* ]]; then
        if [[ "$status" != *': built'* ]]; then
            dkms build -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$(uname -r)"
        fi
        # Migrate manual copies only after a successful build. They otherwise
        # shadow /updates/dkms on Debian and retain the pre-DKMS binaries.
        if [[ -d "$old" ]]; then
            backup="$STATE_DIR/backups/$(uname -r)-pre-dkms-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$(dirname "$backup")"
            mv "$old" "$backup"
            warn "Прежние ручные модули сохранены: $backup"
        fi
        if ! dkms install -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$(uname -r)"; then
            if [[ -n "$backup" && ! -e "$old" ]]; then mv "$backup" "$old"; fi
            depmod -a "$(uname -r)"
            die "DKMS install не завершён; см. dkms status и make.log. Загруженный модуль не менялся"
        fi
    fi
    backup_compute_only_modules
    depmod -a "$(uname -r)"
    patched_module_path >/dev/null || die "После DKMS выбран другой NVIDIA-модуль; проверьте modinfo -n nvidia"
    ok "DKMS $DKMS_NAME/$DKMS_VERSION установлен для $(uname -r); текущий GPU не перезагружался"
}

do_install_dkms() {
    require_root
    require_commands
    host_preflight
    detect_cards
    ensure_no_unlock_in_progress
    dkms_preflight
    [[ -f "$SERVICE_FILE" ]] || die "Для миграции нужен установленный runtime; для новой установки: install --dkms"
    local gen2="$STATE_DIR/src/gen2-$GEN2_REF"
    [[ -f "$gen2/driver/build-gen2.sh" ]] || die "Нет сохранённых исходников $gen2; нужен прежний CMP90_STATE_DIR"
    USE_DKMS=1
    install_dkms_modules "$gen2"
    install_runtime "$gen2"
    install_fast_runtime
    refresh_initramfs
    ok "Миграция на DKMS завершена. После холодного включения выполните verify"
}

do_install() {
    local gen2="$STATE_DIR/src/gen2-$GEN2_REF"
    local final_ko
    require_root
    require_commands
    host_preflight
    if command -v dkms >/dev/null && [[ -n "$(dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION")" ]]; then
        USE_DKMS=1
        info "Сохранён зарегистрированный DKMS-режим"
    fi
    if ((USE_DKMS)); then dkms_preflight; fi
    detect_cards
    ensure_no_unlock_in_progress
    pstated_preflight
    systemctl stop nvidia-pstated-cmp90hx.service 2>/dev/null || true
    prepare_driver_environment
    install_userspace_if_needed
    select_toolchain

    mkdir -p "$STATE_DIR/src"
    info "Получение зафиксированных исходников"
    checkout_repo "$GEN2_URL" "$GEN2_REF" "$gen2"

    # Rhonstin vendors all four functional patches, but build-gen2.sh expects
    # two untracked helper files. VERSION is deterministic; the RPC tracer is
    # diagnostic only and intentionally disabled to avoid flooding the kernel log.
    printf '%s\n' "$DRIVER_VERSION" >"$gen2/driver/VERSION"
    printf '%s\n' '# RPC tracer intentionally disabled by the CMP 90HX installer.' \
        >"$gen2/driver/inject_rpc_tracer.py"

    # Ensure the directly invoked build entry point is executable, including
    # copies with lost permission bits, before moving working modules.
    chmod +x "$gen2/driver/build-gen2.sh"
    if ((USE_DKMS)); then
        install_dkms_modules "$gen2"
    else
        backup_compute_only_modules
        if ! env CC="$BUILD_CC" LD="$BUILD_LD" IGNORE_CC_MISMATCH=1 \
            CMPUNLOCKER_DRIVER_VERSION="$DRIVER_VERSION" \
            CMPUNLOCKER_CARD_PROFILE=cmp90-rejoin15 \
            "$gen2/driver/build-gen2.sh"; then
            if [[ -n "${MOVED_OLD_MODULES:-}" && ! -e "/lib/modules/$(uname -r)/updates/cmpunlocker" ]]; then
                mv "$MOVED_OLD_MODULES" "/lib/modules/$(uname -r)/updates/cmpunlocker"
                depmod -a "$(uname -r)"
                warn "После ошибки восстановлены прежние compute-only модули"
            fi
            die "Сборка объединённого модуля завершилась ошибкой"
        fi
    fi

    final_ko="$(patched_module_path)" || die "Сборщик не установил/не выбрал GEN2CHAIN-модуль"
    install_runtime "$gen2"
    install_fast_runtime
    refresh_initramfs
    install_pstated
    if ((ENABLE_SERVICE)); then
        select_boot_mode cmp90hx-gen2-fast.service cmp90hx-gen2.service
    else
        systemctl disable cmp90hx-gen2.service cmp90hx-gen2-fast.service
    fi
    ok "Объединённый compute+PCIe Gen2 стек установлен"

    printf '\nДля первого применения выполните полное выключение (не reboot):\n'
    printf '  sudo systemctl poweroff\n'
    printf 'Подождите не менее 60 секунд и включите ПК. Fast Gen2 обычно быстрее полного прохода; при fallback ожидание до 30 минут.\n'
    printf 'Проверка после загрузки:\n'
    printf '  systemctl status cmp90hx-gen2-fast.service nvidia-pstated-cmp90hx.service\n'
    printf '  %q verify\n' "$0"
}

repair_runtime() {
    local gen2="$STATE_DIR/src/gen2-$GEN2_REF"
    require_root
    require_commands
    detect_cards
    ensure_no_unlock_in_progress
    [[ -d "$gen2/.git" ]] ||
        die "Не найдено рабочее дерево $gen2. Выполните полный install"
    patched_module_path >/dev/null ||
        die "Объединённый nvidia.ko не установлен; выполните полный install"
    install_runtime "$gen2"
    install_fast_runtime
    ok "Boot-скрипты и cmp90hx-gen2.service обновлены без пересборки драйвера"
}

install_fast_runtime() {
    require_root
    ensure_no_unlock_in_progress
    detect_cards
    patched_module_path >/dev/null || die "Нужен установленный GEN2CHAIN-модуль"
    command -v flock >/dev/null || die "Нужен flock (пакет util-linux)"
    [[ -x "$RUNTIME_DIR/cmp90hx-gen2-consume.sh" ]] || die "Сначала выполните install или repair-runtime"
    # Change only the loop order in a separate copy. Preserve the proven
    # BAR0 workaround, RM trigger, udev handling and late-config untouched.
    python3 - "$RUNTIME_DIR/cmp90hx-gen2-consume.sh" "$RUNTIME_DIR/cmp90hx-gen2-consume-fast.sh" <<'PY'
import pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:])
text = src.read_text()
old = 'for idx in $(seq 0 $((TABLE_SIZE - 1))); do'
if text.count(old) != 1 or 'BAR0 write verification failed' not in text:
    raise SystemExit('Expected patched consume loop/BAR0 verification not found; run repair-runtime first')
dst.write_text(text.replace(old, 'for idx in 33 0; do', 1))
PY
    chmod 0755 "$RUNTIME_DIR/cmp90hx-gen2-consume-fast.sh"
    cat >"$RUNTIME_DIR/cmp90hx-gen2-fast.sh" <<'FAST_SCRIPT'
#!/usr/bin/env bash
# Experimental minimal GEN2CHAIN walk; no REJOIN16 driver or PCI resets.
set -Eeuo pipefail
RUNTIME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START=$SECONDS
LOG=/var/log/cmp90hx-gen2-fast.log
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 2; }
exec 9>/run/lock/cmp90hx-gen2-fast.lock
flock -n 9 || { echo 'Another fast pass is running' >&2; exit 2; }
exec > >(tee "$LOG") 2>&1
say() { echo "[fast +$((SECONDS - START))s] $*"; }
if systemctl is-enabled --quiet cmp90hx-gen2.service ||
   systemctl is-active --quiet cmp90hx-gen2.service; then
    say 'ABORT: full service is enabled/active; switch to fast mode and cold boot first'
    exit 2
fi
mapfile -t CARDS < <(lspci -Dnn -d 10de:220d | awk '{print $1}')
[[ ${#CARDS[@]} == 1 ]] || { say 'ABORT: exactly one CMP 90HX required'; exit 2; }
BDF=${CARDS[0]}
export CMP90_BDF="$BDF" CMP90_BDFS="$BDF"
export CMP90_SKIP_OPEN=0 CMP90_MAX_STALL=40
export CMP90_CONSUME_LOG=/var/log/cmp90hx-gen2-fast-consume.log
export CMP90_HAMMER_LOG=/var/log/cmp90hx-gen2-fast-hammer.log
gen2() {
    local speed sta
    speed="$(cat "/sys/bus/pci/devices/$BDF/current_link_speed" 2>/dev/null || true)"
    sta="$(setpci -s "$BDF" CAP_EXP+12.w 2>/dev/null || true)"
    [[ "$speed" == '5.0 GT/s PCIe' || "$speed" == '5.0 GT/s' ]] &&
        [[ "$sta" =~ ^[[:xdigit:]]{4}$ ]] && (( (16#$sta & 15) == 2 ))
}
say "START $BDF; experimental indices 33 (FEAT), 0 (XVE), then 34 (late-config)"
"$RUNTIME/cmp90hx-compute-prime.sh"
# A consume abort may mean a stuck GSP, failed MMIO write or unload failure.
# Do not continue reloading after such an error.
if "$RUNTIME/cmp90hx-gen2-consume-fast.sh"; then
    :
else
    rc=$?
    say "ABORT: short consume failed rc=$rc; no fallback after unsafe failure"
    exit "$rc"
fi
if "$RUNTIME/cmp90hx-gen2-hammer.sh" && gen2; then
    say 'FAST_SUCCESS: Gen2 confirmed without full walk'
    exit 0
fi
say 'Short walk did not reach Gen2; checking GPU health before full fallback'
timeout 60s nvidia-smi -L >/dev/null || {
    say 'ABORT: GPU is not responding; cold power-off required, no fallback'
    exit 3
}
[[ -d "/sys/bus/pci/devices/$BDF" ]] || { say 'ABORT: GPU disappeared'; exit 3; }
export CMP90_CONSUME_LOG=/var/log/cmp90hx-gen2-fast-fallback-consume.log
export CMP90_HAMMER_LOG=/var/log/cmp90hx-gen2-fast-fallback-hammer.log
say 'FULL_FALLBACK: starting unchanged 34-index walk'
"$RUNTIME/cmp90hx-gen2-consume.sh"
"$RUNTIME/cmp90hx-gen2-hammer.sh"
gen2 || { say 'FAIL: fallback did not confirm Gen2'; exit 1; }
say 'FALLBACK_SUCCESS: full walk was required'
FAST_SCRIPT
    chmod 0755 "$RUNTIME_DIR/cmp90hx-gen2-fast.sh"
    cat >/etc/systemd/system/cmp90hx-gen2-fast.service <<'FAST_UNIT'
[Unit]
Description=Experimental CMP 90HX two-mask GEN2CHAIN with full fallback
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=nvidia-persistenced.service display-manager.service graphical.target
ConditionPathExists=/usr/local/libexec/cmp90hx-gen2/cmp90hx-gen2-fast.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/systemctl stop nvidia-persistenced.service
ExecStartPre=-/usr/bin/systemctl stop nvidia-powerd.service
ExecStart=/usr/local/libexec/cmp90hx-gen2/cmp90hx-gen2-fast.sh
TimeoutStartSec=2400

[Install]
WantedBy=multi-user.target
FAST_UNIT
    chmod 0644 /etc/systemd/system/cmp90hx-gen2-fast.service
    # The full unit must not run while fast mode is selected, even if another
    # unit explicitly pulls it in. This does not stop a running GPU pass.
    install -d /etc/systemd/system/cmp90hx-gen2.service.d
    printf '%s\n' '[Service]' \
        'ExecCondition=/bin/sh -c "! /usr/bin/systemctl is-enabled --quiet cmp90hx-gen2-fast.service && ! /usr/bin/systemctl is-active --quiet cmp90hx-gen2-fast.service"' \
        >/etc/systemd/system/cmp90hx-gen2.service.d/fast-mode-guard.conf
    systemctl daemon-reload
    ok "Fast-сервис установлен; состояние enable не изменено. Первый запуск: enable-fast и холодное выключение"
}

cuda_toolkit_ready() {
    [[ -x "$CUDA_ROOT/bin/nvcc" && -f "$CUDA_ROOT/include/nvml.h" &&
       -f "$CUDA_ROOT/lib64/libcudart.so" ]] || return 1
    python3 - "$CUDA_ROOT/version.json" "$CUDA_VERSION" <<'CUDA_CHECK'
import json
import sys
try:
    with open(sys.argv[1]) as stream:
        version = json.load(stream)['cuda']['version']
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
# SDK/component build numbers differ from the public release number:
# CUDA 13.3.0 reports cuda.version=13.3.20260519 and nvcc=13.3.33.
# Accept an installed Toolkit in the requested major.minor branch;
# fresh installations still use the pinned official 13.3.0 runfile.
sys.exit(0 if isinstance(version, str) and
         version.split('.')[:2] == sys.argv[2].split('.')[:2] else 1)
CUDA_CHECK
}

install_cuda_if_needed() {
    if cuda_toolkit_ready; then
        ok "CUDA Toolkit ${CUDA_VERSION%.*} найден: $CUDA_ROOT"
        return
    fi
    [[ "$CUDA_ROOT" == /* && "$CUDA_ROOT" != / ]] || die "CMP90_CUDA_ROOT должен быть абсолютным путём к отдельному каталогу Toolkit"
    [[ ! -e "$CUDA_ROOT" && ! -L "$CUDA_ROOT" ]] ||
        die "В $CUDA_ROOT уже есть несовместимый или неполный Toolkit. Не перезаписываю его; проверьте установку или задайте другой CMP90_CUDA_ROOT"
    require_root
    local downloads="$STATE_DIR/downloads" runfile
    mkdir -p "$downloads"
    runfile="$downloads/$CUDA_RUNFILE"
    if [[ ! -f "$runfile" ]]; then
        info "Скачивание CUDA Toolkit $CUDA_VERSION с сайта NVIDIA (несколько ГБ)"
        curl --fail --location --retry 3 --output "$runfile.partial" "$CUDA_URL"
        mv -- "$runfile.partial" "$runfile"
    fi
    printf '%s  %s\n' "$CUDA_MD5" "$runfile" | md5sum --check --status ||
        die "Контрольная сумма CUDA не совпала: $runfile. Уберите повреждённый файл и повторите установку"
    info "Установка CUDA $CUDA_VERSION toolkit-only; драйвер NVIDIA не изменяется"
    # CachyOS can ship GCC newer than CUDA supports. Override installation
    # checks only; this does NOT make that compiler supported by nvcc.
    local options=(--silent --toolkit "--toolkitpath=$CUDA_ROOT")
    if [[ "$HOST_PROFILE" == cachyos ]]; then
        options+=(--override)
        warn "Для сборки CUDA-кода используйте поддерживаемый host compiler (GCC <=15), не GCC 16"
    fi
    sh "$runfile" "${options[@]}" || die "Установка CUDA не завершена; проверьте /var/log/cuda-installer.log"
    cuda_toolkit_ready || die "После установки CUDA $CUDA_VERSION не прошёл проверку: $CUDA_ROOT"
    ok "CUDA Toolkit $CUDA_VERSION установлен: $CUDA_ROOT"
}

pstated_preflight() {
    command -v cmake >/dev/null || die "Установите cmake: pacman -S cmake или apt install cmake"
    install_cuda_if_needed
}

install_pstated() {
    require_root
    ensure_no_unlock_in_progress
    pstated_preflight
    [[ -f "$SERVICE_FILE" || -f /etc/systemd/system/cmp90hx-gen2-fast.service ]] || die "Сначала установите Gen2 runtime"
    # Do not install current nvidia-utils over the pinned .run userspace.
    python3 - <<'NV_LIBS'
import ctypes
for lib in ('libnvidia-ml.so.1', 'libnvidia-api.so.1'):
    try:
        ctypes.CDLL(lib)
    except OSError as e:
        raise SystemExit(f'{lib}: {e}; нужен userspace/NVAPI NVIDIA 610.43.03, не пакет другого драйвера')
NV_LIBS
    local src="$STATE_DIR/src/nvidia-pstated-$PSTATED_REF"
    local build="$STATE_DIR/build/nvidia-pstated-$PSTATED_REF"
    checkout_repo "$PSTATED_URL" "$PSTATED_REF" "$src"
    info "Сборка nvidia-pstated $PSTATED_REF"
    cmake -S "$src" -B "$build" -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$(command -v gcc)" \
        -DCUDAToolkit_ROOT="$CUDA_ROOT"
    cmake --build "$build" --parallel "$(nproc)"
    systemctl stop nvidia-pstated-cmp90hx.service 2>/dev/null || true
    install -m 0755 "$build/nvidia-pstated" /usr/local/bin/nvidia-pstated
    # Lock/unlock only clocks. Restore the driver default PL once, not on
    # every idle/load transition; the 120W setting from gpu-idle must not
    # silently throttle server workloads. Read defaults from the same GPU.
    cat >"$RUNTIME_DIR/cmp90hx-restore-power.sh" <<'POWER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
BDF="${CMP90_BDF:?CMP90_BDF is required}"
limit="$(timeout 15s nvidia-smi -i "$BDF" --query-gpu=power.default_limit --format=csv,noheader,nounits)"
[[ "$limit" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid default power limit: $limit" >&2; exit 1; }
timeout 15s nvidia-smi -i "$BDF" -pl "$limit"
POWER_SCRIPT
    chmod 0755 "$RUNTIME_DIR/cmp90hx-restore-power.sh"
    cat >/etc/systemd/system/nvidia-pstated-cmp90hx.service <<'PSTATED_UNIT'
[Unit]
Description=CMP 90HX automatic idle/load clocks
After=cmp90hx-gen2-fast.service cmp90hx-gen2.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
Environment=CMP90_BDF=0000:01:00.0
# Neither unit is pulled in here. The selected enabled Gen2 unit runs first.
# Refuse to start polling NVIDIA if its unlock pass did not finish successfully.
ExecCondition=/bin/sh -c '/usr/bin/systemctl is-active --quiet cmp90hx-gen2-fast.service || /usr/bin/systemctl is-active --quiet cmp90hx-gen2.service'
ExecStartPre=/usr/local/libexec/cmp90hx-gen2/cmp90hx-restore-power.sh
ExecStart=/usr/local/bin/nvidia-pstated --clock-mode --ids 0 --clock-gpu-low 210 --clock-mem-low 405 --clock-gpu-high 0 --clock-mem-high 0 --sleep-interval 100 --iterations-before-switch 600 --utilization-threshold 0
ExecStopPost=-/bin/sh -c 'if /usr/bin/systemctl is-active --quiet cmp90hx-gen2-fast.service || /usr/bin/systemctl is-active --quiet cmp90hx-gen2.service; then /usr/bin/timeout 15s /usr/bin/nvidia-smi -i 0000:01:00.0 -rmc; /usr/bin/timeout 15s /usr/bin/nvidia-smi -i 0000:01:00.0 -rgc; fi'
Restart=on-failure
RestartSec=10
TimeoutStopSec=40
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
PSTATED_UNIT
    sed -i "s/0000:01:00.0/${CMP90_BDFS[0]}/g" /etc/systemd/system/nvidia-pstated-cmp90hx.service
    chmod 0644 /etc/systemd/system/nvidia-pstated-cmp90hx.service
    systemctl daemon-reload
    if ((ENABLE_SERVICE)); then
        systemctl enable nvidia-pstated-cmp90hx.service
    else
        systemctl disable nvidia-pstated-cmp90hx.service
    fi
    ok "nvidia-pstated установлен; старт только после следующей загрузки и успешного Gen2"
}

select_boot_mode() {
    require_root
    local chosen="$1" other="$2"
    ensure_no_unlock_in_progress
    [[ -f "/etc/systemd/system/$chosen" ]] || die "Сначала установите $chosen"
    systemctl disable "$other"
    systemctl enable "$chosen"
    ok "На следующую загрузку выбран $chosen. Сейчас карта не изменена; выполните холодное выключение >=60 секунд"
}

case "$ACTION" in
    install) do_install ;;
    install-dkms) do_install_dkms ;;
    apply)
        require_root
        ensure_no_unlock_in_progress
        if systemctl is-enabled --quiet cmp90hx-gen2-fast.service ||
           systemctl is-active --quiet cmp90hx-gen2-fast.service; then
            die "Выбран или работает fast-сервис; для полного режима выполните enable-full и холодное выключение"
        fi
        detect_cards
        [[ -x "$RUNTIME_DIR/cmp90hx-gen2-consume.sh" ]] || die "Сначала выполните install"
        systemctl stop nvidia-pstated-cmp90hx.service 2>/dev/null || true
        "$RUNTIME_DIR/cmp90hx-compute-prime.sh"
        CMP90_SKIP_OPEN=0 CMP90_MAX_STALL=40 \
            "$RUNTIME_DIR/cmp90hx-gen2-consume.sh"
        "$RUNTIME_DIR/cmp90hx-gen2-hammer.sh"
        ;;
    repair-runtime) repair_runtime ;;
    install-fast) install_fast_runtime ;;
    install-pstated) require_root; require_commands; detect_cards; ensure_no_unlock_in_progress; install_userspace_if_needed; install_pstated ;;
    enable-fast) select_boot_mode cmp90hx-gen2-fast.service cmp90hx-gen2.service ;;
    enable-full) select_boot_mode cmp90hx-gen2.service cmp90hx-gen2-fast.service ;;
    verify) verify_install ;;
esac
