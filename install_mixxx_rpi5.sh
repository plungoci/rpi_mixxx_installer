#!/usr/bin/env bash
# =============================================================================
#  install_mixxx_rpi5.sh
#
#  Instalează automat ultima versiune stabilă Mixxx 2.5.x, compilată din
#  sursele oficiale (https://github.com/mixxxdj/mixxx), pe Raspberry Pi 5 cu
#  Raspberry Pi OS 64-bit (ARM64 / aarch64).
#
#  Compatibilitate analizată:
#    * Raspberry Pi OS Bookworm (Debian 12): Qt 6.4.2, CMake 3.25 -> OK
#      (qt6-svg-plugins nu există; se folosesc numele de pachete Debian 12)
#    * Raspberry Pi OS Trixie   (Debian 13): Qt 6.8, CMake 3.31, TagLib 2 -> OK
#      (libtag-dev în loc de libtag1-dev, qt6-svg-plugins disponibil)
#    * Bullseye (Debian 11) NU are Qt >= 6.2 utilizabil -> refuzat.
#  Mixxx 2.5 cere: CMake >= 3.21, Qt >= 6.2 (QML activ implicit).
#
#  Rezumat etape:
#    1  Hardware           6  Configurare CMake     11 Controllere DJ
#    2  Sistem             7  Compilare             12 Test final
#    3  Actualizare        8  Instalare             13 Pornire Mixxx
#    4  Dependențe         9  Desktop entry         14 Raport final
#    5  Surse Mixxx        10 Audio
# =============================================================================

set -Eeuo pipefail
shopt -s extglob

# -----------------------------------------------------------------------------
# Constante și valori implicite
# -----------------------------------------------------------------------------
readonly SCRIPT_NAME="install_mixxx_rpi5.sh"
readonly SCRIPT_VERSION="1.0.0"
readonly MIXXX_REPO_URL="https://github.com/mixxxdj/mixxx.git"
readonly MIXXX_SERIES="2.5"
readonly INSTALL_PREFIX="/usr/local"
readonly STATE_DIR="/var/lib/mixxx-installer"
readonly STATE_FILE="${STATE_DIR}/state"
readonly TEMP_SWAPFILE="/var/tmp/mixxx-build.swap"
readonly MIN_FREE_DISK_GB=6          # minim absolut pentru surse + build
readonly RECOMMENDED_FREE_DISK_GB=10
readonly RAM_PER_JOB_MB=1500         # estimare RAM per job de compilare C++/Qt

# Opțiuni din linia de comandă
OPT_NO_UPGRADE=0
OPT_SKIP_DEPS=0
OPT_SKIP_BUILD=0
OPT_FORCE=0
OPT_DRY_RUN=0
OPT_VERBOSE=0
OPT_YES=0

# Stare globală (folosită în raportul final)
LOG_FILE="/var/log/mixxx-install.log"
CURRENT_STAGE="Inițializare"
FAILED_COMMAND=""
FAILED_EXIT_CODE=0
INSTALL_STATUS="IN PROGRESS"
declare -a SUMMARY_ACTIONS=()
declare -a WARNINGS=()
declare -a MISSING_OPTIONAL_PKGS=()
declare -a SUDO=()

# Informații detectate
ARCH=""; PI_MODEL="necunoscut"; IS_PI5=0; CPU_CORES=0; CPU_MODEL=""
RAM_MB=0; SWAP_MB=0; KERNEL=""; OS_PRETTY=""; OS_CODENAME=""; DEBIAN_VERSION=""
USERLAND_BITS=""; FREE_DISK_GB=0
TARGET_USER=""; TARGET_HOME=""
SRC_DIR=""; BUILD_DIR=""; STAGE_DIR=""
LATEST_TAG=""; INSTALLED_VERSION=""; INSTALLED_BIN=""
BUILD_JOBS=1; CMAKE_GENERATOR="Unix Makefiles"
AUDIO_BACKEND=""; USB_AUDIO_DEVICES=""; USB_MIDI_DEVICES=""
TEMP_SWAP_ACTIVE=0
NEED_BUILD=1
MIXXX_STARTED=0

# -----------------------------------------------------------------------------
# Afișare și logging
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'
    C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_BOLD=$'\e[1m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

# Scrie un mesaj (fără coduri de culoare) în log
log_raw() {
    [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]] || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

info()    { printf '%s[INFO]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*"; log_raw "[INFO] $*"; }
ok()      { printf '%s[OK]%s %s\n'      "${C_GREEN}"  "${C_RESET}" "$*"; log_raw "[OK] $*"; }
warn()    { printf '%s[WARNING]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; log_raw "[WARNING] $*"; WARNINGS+=("$*"); }
error()   { printf '%s[ERROR]%s %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; log_raw "[ERROR] $*"; }
debug()   { (( OPT_VERBOSE )) && printf '[DEBUG] %s\n' "$*"; log_raw "[DEBUG] $*"; return 0; }
hint()    { printf '        %s➜ Sugestie:%s %s\n' "${C_BOLD}" "${C_RESET}" "$*" >&2; log_raw "[HINT] $*"; }

stage() {
    CURRENT_STAGE="$*"
    printf '\n%s========== %s ==========%s\n' "${C_BOLD}" "$*" "${C_RESET}"
    log_raw "========== $* =========="
}

record() {
    local msg="$*"
    (( OPT_DRY_RUN )) && msg="[simulat] ${msg}"
    SUMMARY_ACTIONS+=("${msg}"); log_raw "[ACTION] ${msg}"
}

# Oprire controlată cu mesaj + sugestie
die() {
    local msg="$1" suggestion="${2:-}"
    error "${msg}"
    [[ -n "${suggestion}" ]] && hint "${suggestion}"
    FAILED_COMMAND="${FAILED_COMMAND:-${msg}}"
    FAILED_EXIT_CODE=1
    INSTALL_STATUS="FAILED"
    exit 1
}

# -----------------------------------------------------------------------------
# Execuție comenzi (respectă --dry-run și --verbose)
# -----------------------------------------------------------------------------
# Execută o comandă care MODIFICĂ sistemul. În dry-run doar o afișează.
run() {
    if (( OPT_DRY_RUN )); then
        printf '%s[DRY-RUN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(printf '%q ' "$@")"
        log_raw "[DRY-RUN] $*"
        return 0
    fi
    log_raw "[RUN] $*"
    if (( OPT_VERBOSE )); then
        "$@" 2>&1 | tee -a "${LOG_FILE}"
    else
        "$@" >>"${LOG_FILE}" 2>&1
    fi
}

# Ca run(), dar cu privilegii root (sudo doar dacă nu suntem deja root)
run_root() { run "${SUDO[@]}" "$@"; }

# Întrebare da/nu. $2 = răspunsul implicit (y/n).
# În --dry-run și cu --yes se presupune "y" (continuare), fără interacțiune.
ask_yes_no() {
    local question="$1" default="${2:-n}" reply prompt
    if (( OPT_DRY_RUN )); then
        info "${question} -> (dry-run: se presupune 'y')"; return 0
    fi
    if (( OPT_YES )); then
        info "${question} -> (--yes: 'y')"; return 0
    fi
    if [[ ! -r /dev/tty ]] || ! { : </dev/tty; } 2>/dev/null; then
        info "${question} -> (fără terminal interactiv: implicit '${default}')"
        [[ "${default}" == "y" ]]; return
    fi
    [[ "${default}" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    read -r -p "${C_BOLD}[?]${C_RESET} ${question} ${prompt} " reply </dev/tty || reply=""
    log_raw "[QUESTION] ${question} -> '${reply}'"
    reply="${reply:-${default}}"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" || "${reply,,}" == "d" || "${reply,,}" == "da" ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Ștergere sigură a unui director: doar sub o rădăcină permisă și cu un nume așteptat
safe_rm_dir() {
    local target="$1" allowed_parent="$2" real_target real_parent
    [[ -n "${target}" && -n "${allowed_parent}" ]] || die "safe_rm_dir: argumente goale"
    [[ -e "${target}" ]] || return 0
    real_target="$(readlink -f -- "${target}")"
    real_parent="$(readlink -f -- "${allowed_parent}")"
    case "${real_target}" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/opt|/proc|/root|/sbin|/sys|/usr|/var|"${HOME}"|"${TARGET_HOME}")
            die "Refuz să șterg calea protejată: ${real_target}" ;;
    esac
    [[ "${real_target}" == "${real_parent}/"* ]] \
        || die "Refuz să șterg ${real_target}: nu se află în ${real_parent}"
    run rm -rf -- "${real_target}"
}

# -----------------------------------------------------------------------------
# Tratare erori, curățenie, raport
# -----------------------------------------------------------------------------
on_error() {
    local exit_code=$? line="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND}"
    # Evităm dublarea mesajului când eroarea vine din die()
    [[ "${INSTALL_STATUS}" == "FAILED" ]] && return
    FAILED_COMMAND="${cmd}"
    FAILED_EXIT_CODE="${exit_code}"
    INSTALL_STATUS="FAILED"
    error "Eroare în etapa '${CURRENT_STAGE}' (linia ${line}, cod ${exit_code})"
    error "Comanda care a eșuat: ${cmd}"
    if [[ -r "${LOG_FILE}" ]]; then
        printf '%s--- Ultimele 60 de linii din log (%s) ---%s\n' "${C_BOLD}" "${LOG_FILE}" "${C_RESET}" >&2
        tail -n 60 "${LOG_FILE}" >&2 || true
        printf '%s-----------------------------------------------%s\n' "${C_BOLD}" "${C_RESET}" >&2
    fi
    hint "Verifică logul complet: ${LOG_FILE}"
}

cleanup() {
    local rc=$?
    set +e
    # Dezactivăm swap-ul temporar creat de script (dacă există)
    if (( TEMP_SWAP_ACTIVE )); then
        info "Dezactivez swap-ul temporar ${TEMP_SWAPFILE}"
        "${SUDO[@]}" swapoff "${TEMP_SWAPFILE}" >>"${LOG_FILE}" 2>&1
        "${SUDO[@]}" rm -f -- "${TEMP_SWAPFILE}" >>"${LOG_FILE}" 2>&1
        TEMP_SWAP_ACTIVE=0
    fi
    if (( rc != 0 )) && [[ "${INSTALL_STATUS}" != "FAILED" ]]; then
        INSTALL_STATUS="FAILED"
        FAILED_EXIT_CODE="${rc}"
    fi
    # Raportul final se generează o singură dată, la ieșire (și la eșec)
    if [[ "${REPORT_DONE:-0}" != 1 && "${EARLY_EXIT:-0}" != 1 ]]; then
        final_report
    fi
    exit "${rc}"
}

on_interrupt() {
    FAILED_COMMAND="Întrerupt de utilizator (Ctrl+C)"
    INSTALL_STATUS="FAILED"
    error "Instalare întreruptă de utilizator."
    exit 130
}

trap on_error ERR
trap cleanup EXIT
trap on_interrupt INT TERM

# -----------------------------------------------------------------------------
# Argumente
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Instalează ultima versiune stabilă Mixxx ${MIXXX_SERIES}.x din surse oficiale pe
Raspberry Pi 5 cu Raspberry Pi OS 64-bit (ARM64).

Utilizare:
  ./${SCRIPT_NAME} [opțiuni]
  sudo ./${SCRIPT_NAME} [opțiuni]

Opțiuni:
  --help               Afișează acest ajutor și iese.
  --version            Afișează versiunea scriptului și iese.
  --no-upgrade         Nu rulează 'apt full-upgrade' (rulează doar 'apt update').
  --skip-dependencies  Nu instalează dependențele de compilare.
  --skip-build         Nu configurează și nu compilează. Dacă există deja un build
                       complet, îl instalează; altfel păstrează instalarea curentă.
  --force              Recompilează și reinstalează chiar dacă ultima versiune
                       ${MIXXX_SERIES}.x este deja instalată (reconfigurează CMake).
  --dry-run            Arată ce ar face scriptul, fără a modifica sistemul.
  --verbose            Afișează în terminal ieșirea completă a comenzilor.
  -y, --yes            Răspunde automat 'da' la întrebări (mod neinteractiv).

Locații:
  Surse:  /opt/mixxx-source (rulat ca root/sudo) sau \$HOME/src/mixxx
  Build:  <surse>/build
  Instalare: ${INSTALL_PREFIX} (executabil: ${INSTALL_PREFIX}/bin/mixxx)
  Log:    /var/log/mixxx-install.log

Scriptul NU modifică: configurația audio, ~/.mixxx, biblioteca muzicală,
/boot, firmware-ul sau configurația GPU.
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --help|-h)            usage; EARLY_EXIT=1; exit 0 ;;
            --version|-V)         echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; EARLY_EXIT=1; exit 0 ;;
            --no-upgrade)         OPT_NO_UPGRADE=1 ;;
            --skip-dependencies)  OPT_SKIP_DEPS=1 ;;
            --skip-build)         OPT_SKIP_BUILD=1 ;;
            --force)              OPT_FORCE=1 ;;
            --dry-run)            OPT_DRY_RUN=1 ;;
            --verbose|-v)         OPT_VERBOSE=1 ;;
            --yes|-y)             OPT_YES=1 ;;
            *)
                echo "Opțiune necunoscută: $1" >&2
                echo "Rulează '${SCRIPT_NAME} --help' pentru lista de opțiuni." >&2
                EARLY_EXIT=1; exit 2 ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# Privilegii, utilizator țintă și fișierul de log
# -----------------------------------------------------------------------------
setup_privileges() {
    if (( EUID == 0 )); then
        SUDO=()
        # Utilizatorul real (dacă scriptul a fost pornit cu sudo)
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            TARGET_USER="${SUDO_USER}"
        else
            TARGET_USER="root"
        fi
    else
        need_cmd sudo || {
            echo "[ERROR] Scriptul nu rulează ca root și 'sudo' nu este instalat." >&2
            echo "        ➜ Sugestie: rulează ca root sau instalează sudo: su -c 'apt install sudo'" >&2
            EARLY_EXIT=1; exit 1; }
        SUDO=(sudo)
        TARGET_USER="$(id -un)"
        if (( ! OPT_DRY_RUN )); then
            echo "[INFO] Sunt necesare privilegii sudo pentru unele etape (apt, instalare)."
            sudo -v || { echo "[ERROR] Autentificarea sudo a eșuat." >&2; EARLY_EXIT=1; exit 1; }
        fi
    fi
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
    TARGET_HOME="${TARGET_HOME:-${HOME}}"

    # Directorul surselor: /opt/mixxx-source ca root, altfel ~/src/mixxx
    if (( EUID == 0 )); then
        SRC_DIR="/opt/mixxx-source"
    else
        SRC_DIR="${HOME}/src/mixxx"
    fi
    BUILD_DIR="${SRC_DIR}/build"
    STAGE_DIR="${BUILD_DIR}/stage"
}

setup_logging() {
    if (( OPT_DRY_RUN )); then
        # În dry-run nu scriem în /var/log
        LOG_FILE="${TMPDIR:-/tmp}/mixxx-install-dryrun.log"
        : >"${LOG_FILE}"
    else
        if ! { "${SUDO[@]}" touch "${LOG_FILE}" && "${SUDO[@]}" chown "$(id -u):$(id -g)" "${LOG_FILE}"; } 2>/dev/null; then
            LOG_FILE="${HOME}/mixxx-install.log"
            : >>"${LOG_FILE}"
            echo "[WARNING] Nu pot scrie în /var/log; folosesc ${LOG_FILE}" >&2
        fi
    fi
    {
        echo
        echo "#####################################################################"
        echo "# ${SCRIPT_NAME} v${SCRIPT_VERSION} - $(date '+%F %T')"
        echo "# Argumente: dry-run=${OPT_DRY_RUN} no-upgrade=${OPT_NO_UPGRADE} skip-deps=${OPT_SKIP_DEPS} skip-build=${OPT_SKIP_BUILD} force=${OPT_FORCE}"
        echo "#####################################################################"
    } >>"${LOG_FILE}"
    info "Log: ${LOG_FILE}"
    (( OPT_DRY_RUN )) && warn "Mod DRY-RUN: nicio modificare nu va fi făcută în sistem."
    return 0
}

# =============================================================================
# ETAPA 1 — Verificarea hardware-ului
# =============================================================================
check_hardware() {
    stage "ETAPA 1/14 — Verificarea hardware-ului"
    local c
    for c in uname nproc awk grep df free; do
        need_cmd "${c}" || die "Comanda necesară '${c}' lipsește." "sudo apt install coreutils procps gawk grep"
    done

    # Arhitectura: trebuie aarch64
    ARCH="$(uname -m)"
    if [[ "${ARCH}" != "aarch64" ]]; then
        die "Arhitectură nesuportată: ${ARCH}. Acest script necesită Raspberry Pi OS 64-bit / ARM64." \
            "Instalează Raspberry Pi OS (64-bit) cu Raspberry Pi Imager și rulează din nou scriptul."
    fi
    ok "Architecture: ARM64 (${ARCH})"

    # Modelul Raspberry Pi (device-tree)
    if [[ -r /proc/device-tree/model ]]; then
        PI_MODEL="$(tr -d '\0' </proc/device-tree/model)"
    elif [[ -r /sys/firmware/devicetree/base/model ]]; then
        PI_MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
    fi
    if [[ "${PI_MODEL}" == *"Raspberry Pi 5"* ]]; then
        IS_PI5=1  # folosit pentru decizii specifice Pi 5
        ok "Raspberry Pi 5 detectat (${PI_MODEL})"
    else
        warn "Sistemul nu pare a fi un Raspberry Pi 5 (model detectat: ${PI_MODEL})."
        ask_yes_no "Vrei să continui oricum?" "n" \
            || die "Instalare anulată de utilizator (hardware diferit de Raspberry Pi 5)."
    fi

    # CPU, RAM, swap
    CPU_CORES="$(nproc)"
    CPU_MODEL="$(awk -F': ' '/^model name|^Model|^Hardware/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    if need_cmd lscpu; then
        CPU_MODEL="$(lscpu | awk -F': +' '/^Model name/ {print $2; exit}' || true)"
    fi
    RAM_MB="$(awk '/^MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    SWAP_MB="$(awk '/^SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    KERNEL="$(uname -r)"
    FREE_DISK_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"

    ok "CPU cores: ${CPU_CORES}${CPU_MODEL:+ (${CPU_MODEL})}"
    ok "RAM: aproximativ $(( (RAM_MB + 512) / 1024 )) GB (${RAM_MB} MB), swap: ${SWAP_MB} MB"
    ok "Kernel: ${KERNEL}"
    ok "Spațiu liber pe /: ${FREE_DISK_GB} GB"

    # Versiunea sistemului de operare (Raspberry Pi OS / Debian)
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        OS_PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-necunoscut}")"
        OS_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    fi
    DEBIAN_VERSION="$(cat /etc/debian_version 2>/dev/null || echo necunoscut)"
    ok "OS: ${OS_PRETTY} (codename: ${OS_CODENAME:-?})"
    ok "Debian: ${DEBIAN_VERSION}"
    if [[ -r /etc/rpi-issue ]]; then
        ok "Raspberry Pi OS image: $(head -n1 /etc/rpi-issue)"
    elif ! dpkg -s raspberrypi-sys-mods >/dev/null 2>&1; then
        warn "Nu am găsit semne de Raspberry Pi OS (/etc/rpi-issue, raspberrypi-sys-mods). Continui ca Debian generic."
    fi
}

# =============================================================================
# ETAPA 2 — Verificarea sistemului
# =============================================================================
check_system() {
    stage "ETAPA 2/14 — Verificarea sistemului"

    { need_cmd apt-get && need_cmd apt-cache && need_cmd dpkg; } \
        || die "apt/dpkg nu sunt disponibile. Scriptul funcționează doar pe Raspberry Pi OS/Debian."
    ok "apt: $(apt-get --version | head -n1)"

    # Userland 64-bit (un kernel arm64 poate rula și cu userland armhf!)
    USERLAND_BITS="$(getconf LONG_BIT 2>/dev/null || echo '?')"
    local dpkg_arch
    dpkg_arch="$(dpkg --print-architecture)"
    if [[ "${dpkg_arch}" != "arm64" || "${USERLAND_BITS}" != "64" ]]; then
        die "Acest script necesită Raspberry Pi OS 64-bit / ARM64. (dpkg: ${dpkg_arch}, userland: ${USERLAND_BITS}-bit)" \
            "Kernelul poate fi 64-bit, dar sistemul este 32-bit. Reinstalează Raspberry Pi OS (64-bit)."
    fi
    ok "Raspberry Pi OS 64-bit (dpkg arch: ${dpkg_arch}, userland: ${USERLAND_BITS}-bit)"

    # Compatibilitate distribuție <-> Mixxx 2.5 (Qt >= 6.2, CMake >= 3.21)
    local deb_major="${DEBIAN_VERSION%%.*}"
    case "${OS_CODENAME}" in
        bookworm) ok "Debian 12 (Bookworm): compatibil cu Mixxx ${MIXXX_SERIES} (Qt 6.4)" ;;
        trixie)   ok "Debian 13 (Trixie): compatibil cu Mixxx ${MIXXX_SERIES} (Qt 6.8)" ;;
        buster|bullseye)
            die "${OS_CODENAME} este prea vechi: nu oferă Qt >= 6.2 necesar pentru Mixxx ${MIXXX_SERIES}." \
                "Instalează Raspberry Pi OS Bookworm sau Trixie (64-bit)." ;;
        *)
            if [[ "${deb_major}" =~ ^[0-9]+$ ]] && (( deb_major >= 12 )); then
                warn "Distribuție netestată (${OS_CODENAME:-?}, Debian ${DEBIAN_VERSION}); continui cu detecție automată a pachetelor."
            else
                warn "Nu pot determina sigur versiunea Debian (${DEBIAN_VERSION}). Verificarea pachetelor va decide."
            fi ;;
    esac

    # Unelte de build (lipsa lor NU e fatală aici: se instalează în etapa 4)
    local tool missing=()
    for tool in git cmake gcc g++ make pkg-config; do
        if need_cmd "${tool}"; then
            ok "${tool}: $("${tool}" --version 2>/dev/null | head -n1)"
        else
            missing+=("${tool}")
        fi
    done
    if (( ${#missing[@]} )); then
        if (( OPT_SKIP_DEPS )); then
            die "Lipsesc unelte de build: ${missing[*]} (iar --skip-dependencies este activ)." \
                "Rulează fără --skip-dependencies sau: sudo apt install build-essential git cmake pkg-config"
        fi
        warn "Lipsesc unelte de build: ${missing[*]} — vor fi instalate în etapa 4."
    fi

    # Mixxx deja instalat?
    detect_installed_mixxx
    if [[ -n "${INSTALLED_VERSION}" ]]; then
        ok "Mixxx deja instalat: ${INSTALLED_VERSION} (${INSTALLED_BIN})"
    else
        info "Mixxx nu este instalat în prezent."
    fi
    if dpkg -s mixxx >/dev/null 2>&1; then
        warn "Există și pachetul apt 'mixxx' ($(dpkg-query -W -f='${Version}' mixxx)). NU îl șterg; versiunea din ${INSTALL_PREFIX}/bin are prioritate în PATH."
    fi

    # Configurația personală (doar informativ — nu o atingem)
    if [[ -d "${TARGET_HOME}/.mixxx" ]]; then
        ok "Configurație personală existentă păstrată neatinsă: ${TARGET_HOME}/.mixxx"
    fi
}

# Detectează versiunea Mixxx instalată (prioritar ${INSTALL_PREFIX}/bin/mixxx)
detect_installed_mixxx() {
    INSTALLED_BIN=""; INSTALLED_VERSION=""
    if [[ -x "${INSTALL_PREFIX}/bin/mixxx" ]]; then
        INSTALLED_BIN="${INSTALL_PREFIX}/bin/mixxx"
    elif need_cmd mixxx; then
        INSTALLED_BIN="$(command -v mixxx)"
    fi
    [[ -n "${INSTALLED_BIN}" ]] || return 0
    INSTALLED_VERSION="$(mixxx_version_of "${INSTALLED_BIN}")"
    if [[ -z "${INSTALLED_VERSION}" && -r "${STATE_FILE}" ]]; then
        INSTALLED_VERSION="$(awk -F= '/^installed_tag=/ {print $2}' "${STATE_FILE}")"
    fi
    INSTALLED_VERSION="${INSTALLED_VERSION:-necunoscută}"
}

# Rulează "mixxx --version" fără interfață grafică și extrage numărul versiunii
mixxx_version_of() {
    local bin="$1" out
    out="$(QT_QPA_PLATFORM=offscreen timeout 30 "${bin}" --version 2>/dev/null || true)"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.+-]+)?' <<<"${out}" | head -n1 || true
}

# =============================================================================
# ETAPA 3 — Actualizarea sistemului
# =============================================================================
update_system() {
    stage "ETAPA 3/14 — Actualizarea sistemului"
    export DEBIAN_FRONTEND=noninteractive

    info "Rulez apt update..."
    if ! run_root apt-get update; then
        die "'apt update' a eșuat." \
            "Verifică conexiunea la internet și /etc/apt/sources.list*, apoi: sudo apt update"
    fi
    ok "Lista de pachete actualizată."
    record "apt update"

    local upgradable
    upgradable="$(apt list --upgradable 2>/dev/null | grep -c -- '/' || true)"
    if (( upgradable == 0 )); then
        ok "Sistemul este actualizat (0 pachete de actualizat)."
    elif (( OPT_NO_UPGRADE )); then
        warn "${upgradable} pachete pot fi actualizate, dar --no-upgrade este activ."
    else
        info "${upgradable} pachete de actualizat. Rulez apt full-upgrade (poate dura)..."
        if ! run_root apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade; then
            die "'apt full-upgrade' a eșuat." \
                "Rulează manual 'sudo apt full-upgrade' și 'sudo dpkg --configure -a', apoi repornește scriptul."
        fi
        ok "Sistem actualizat (${upgradable} pachete)."
        record "apt full-upgrade (${upgradable} pachete)"
    fi

    check_reboot_required
}

# Detectează necesitatea unui reboot (nu repornește niciodată automat)
check_reboot_required() {
    local reason=""
    if [[ -f /var/run/reboot-required ]]; then
        reason="/var/run/reboot-required este prezent"
    elif [[ ! -d "/lib/modules/$(uname -r)" ]]; then
        reason="kernelul rulat ($(uname -r)) nu mai are module instalate (kernel nou instalat)"
    fi
    [[ -n "${reason}" ]] || { ok "Nu este necesar reboot."; return 0; }

    warn "Este recomandat un reboot: ${reason}."
    info "Compilarea poate continua, dar pornirea Mixxx e mai sigură după reboot."
    if ask_yes_no "Continui instalarea fără reboot acum? (N = opresc scriptul ca să repornești)" "y"; then
        record "Reboot necesar, amânat de utilizator"
    else
        info "Repornește cu: sudo reboot   apoi rulează din nou scriptul (va continua de unde a rămas)."
        INSTALL_STATUS="STOPPED (reboot necesar)"
        exit 0
    fi
}

# =============================================================================
# ETAPA 4 — Instalarea dependențelor
# =============================================================================
# Fiecare intrare: "nivel|alternativa1 alternativa2 ...|descriere"
#   nivel = critical -> fără el build-ul NU e posibil (oprire)
#           optional -> funcționalitate redusă dacă lipsește (warning)
# Pentru fiecare intrare se alege PRIMA alternativă disponibilă în apt,
# astfel se acoperă diferențele de nume între Debian 12 și 13.
dependency_table() {
    cat <<'EOF'
critical|build-essential|Compilator C/C++ și make
critical|git|Git
critical|cmake|CMake (>= 3.21)
critical|pkg-config pkgconf|pkg-config
critical|file|Verificare arhitectură executabil
optional|ninja-build|Ninja (build mai rapid)
optional|ccache|Cache de compilare (recompilări rapide)
optional|mold lld|Linker rapid / consum redus de RAM
critical|qt6-base-dev|Qt6 Base (Core, Gui, Widgets, SQL, DBus, OpenGL)
critical|qt6-base-private-dev|Qt6 Base private headers
critical|libqt6opengl6-dev qt6-base-dev|Qt6 OpenGL
critical|libqt6svg6-dev qt6-svg-dev|Qt6 SVG / SvgWidgets
critical|qt6-declarative-dev|Qt6 QML/Quick
critical|qt6-declarative-private-dev|Qt6 QML/Quick private
critical|qt6-shadertools-dev libqt6shadertools6-dev|Qt6 ShaderTools
critical|qt6-5compat-dev libqt6core5compat6-dev|Qt6 Core5Compat
critical|libqt6sql6-sqlite|Driver Qt6 SQLite (biblioteca Mixxx)
critical|qt6-qpa-plugins|Plugin-uri platformă Qt6
optional|qt6-multimedia-dev|Qt6 Multimedia
optional|qt6-svg-plugins|Plugin imagini SVG Qt6
optional|qt6-wayland|Suport Wayland pentru Qt6 (desktop implicit RPi OS)
optional|qt6-tools-dev qt6-tools-dev-tools|Unelte Qt6
optional|qt6-translations-l10n|Traduceri Qt6
optional|qml6-module-qt5compat-graphicaleffects|QML GraphicalEffects
optional|qml6-module-qtqml-workerscript|QML WorkerScript
optional|qml6-module-qtquick-controls|QML Controls
optional|qml6-module-qtquick-layouts|QML Layouts
optional|qml6-module-qtquick-shapes|QML Shapes
optional|qml6-module-qtquick-templates|QML Templates
optional|qml6-module-qtquick-window|QML Window
optional|qml6-module-qt-labs-qmlmodels|QML Labs QmlModels
critical|qtkeychain-qt6-dev|QtKeychain (credențiale Live Broadcasting)
critical|libgl-dev libgl1-mesa-dev|OpenGL
critical|libx11-dev|X11
critical|libasound2-dev|ALSA development
critical|libjack-jackd2-dev libjack-dev|JACK development
critical|portaudio19-dev|PortAudio development
critical|libportmidi-dev|PortMidi (controllere MIDI)
critical|libsndfile1-dev libsndfile-dev|libsndfile
critical|libogg-dev|Ogg
critical|libvorbis-dev|Vorbis
critical|libflac-dev|FLAC
critical|libmp3lame-dev|MP3 encoder (LAME)
critical|libopus-dev|Opus
optional|libopusfile-dev|Opusfile (decodare Opus)
optional|libmad0-dev|MP3 decoder (MAD)
optional|libid3tag0-dev|ID3 tags
optional|libfaad-dev|AAC (FAAD)
optional|libmodplug-dev|Module tracker (MOD/XM/IT)
optional|libwavpack-dev|WavPack
critical|libchromaprint-dev|Chromaprint (AcoustID)
critical|libfftw3-dev|FFTW3
critical|libebur128-dev|libebur128 (ReplayGain)
critical|libhidapi-dev|HIDAPI (controllere HID)
critical|libusb-1.0-0-dev|libusb (controllere USB Bulk)
optional|libudev-dev|udev
critical|libprotobuf-dev|Protocol Buffers
critical|protobuf-compiler|Protocol Buffers compiler
critical|libavcodec-dev|FFmpeg libavcodec
critical|libavformat-dev|FFmpeg libavformat
critical|libavutil-dev|FFmpeg libavutil
critical|libswresample-dev|FFmpeg libswresample
critical|libtag-dev libtag1-dev|TagLib (TagLib 2 pe Trixie, 1.x pe Bookworm)
critical|librubberband-dev|Rubber Band
critical|libsoundtouch-dev|SoundTouch (>= 2.1.2)
critical|libupower-glib-dev|UPower
critical|libsqlite3-dev|SQLite3
critical|zlib1g-dev|zlib (Engine Prime export)
optional|libssl-dev|OpenSSL
optional|libkeyfinder-dev|KeyFinder (altfel descărcat la build)
optional|liblilv-dev|LV2 host (lilv)
optional|lv2-dev|LV2 headers
optional|libshout-idjc-dev|Live Broadcasting (libshout-idjc)
optional|libmsgsl-dev|Microsoft GSL
optional|fonts-open-sans|Font Open Sans (skin-uri)
optional|upower|Serviciul UPower (stare baterie)
optional|usbutils|lsusb (detecție USB)
optional|alsa-utils|aplay/arecord (detecție audio)
EOF
}

# Cache cu versiunile candidat din apt (un singur apel apt-cache pentru toate pachetele)
declare -A APT_CANDIDATE=()
load_apt_candidates() {
    local pkg="" line
    while IFS= read -r line; do
        if [[ "${line}" =~ ^([A-Za-z0-9.+-]+)(:[a-z0-9]+)?:$ ]]; then
            pkg="${BASH_REMATCH[1]}"
        elif [[ -n "${pkg}" && "${line}" =~ ^[[:space:]]+Candidate:[[:space:]]+(.+)$ ]]; then
            APT_CANDIDATE["${pkg}"]="${BASH_REMATCH[1]}"
            pkg=""
        fi
    done < <(LC_ALL=C apt-cache policy -- "$@" 2>/dev/null || true)
}

# Pachetul are o versiune candidat instalabilă în apt?
pkg_available() {
    local cand="${APT_CANDIDATE[$1]:-}"
    [[ -n "${cand}" && "${cand}" != "(none)" ]]
}

pkg_installed() {
    [[ "$(dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null)" == "install ok installed" ]]
}

install_dependencies() {
    stage "ETAPA 4/14 — Instalarea dependențelor"
    if (( OPT_SKIP_DEPS )); then
        warn "Etapa sărită (--skip-dependencies)."
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive

    local level alts desc alt chosen
    local -a to_install=() already=() critical_missing=()

    info "Rezolv numele pachetelor pentru ${OS_CODENAME:-sistemul curent} (Debian ${DEBIAN_VERSION})..."
    # shellcheck disable=SC2046
    load_apt_candidates $(dependency_table | cut -d'|' -f2 | tr ' ' '\n' | sort -u)
    while IFS='|' read -r level alts desc; do
        [[ -z "${level}" || "${level}" == \#* ]] && continue
        chosen=""
        for alt in ${alts}; do
            if pkg_available "${alt}"; then chosen="${alt}"; break; fi
        done
        if [[ -z "${chosen}" ]]; then
            if [[ "${level}" == "critical" ]]; then
                critical_missing+=("${desc} [${alts// / | }]")
                error "Dependență CRITICĂ indisponibilă: ${desc} (${alts})"
            else
                MISSING_OPTIONAL_PKGS+=("${alts%% *}")
                warn "Dependență opțională indisponibilă: ${desc} (${alts}) — funcționalitate redusă."
            fi
            continue
        fi
        [[ "${chosen}" != "${alts%% *}" ]] && info "  ${desc}: folosesc numele '${chosen}' (în loc de '${alts%% *}')"
        if [[ " ${to_install[*]} ${already[*]} " == *" ${chosen} "* ]]; then
            continue    # același pachet ales pentru mai multe intrări
        elif pkg_installed "${chosen}"; then
            already+=("${chosen}")
        else
            to_install+=("${chosen}")
        fi
        debug "  ${level}: ${desc} -> ${chosen}"
    done < <(dependency_table)

    if (( ${#critical_missing[@]} )); then
        local m
        for m in "${critical_missing[@]}"; do error "  lipsă: ${m}"; done
        die "${#critical_missing[@]} dependențe critice nu pot fi satisfăcute din depozitele oficiale." \
            "Rulează 'sudo apt update', verifică sursele apt (main/contrib/non-free) și versiunea OS (Bookworm/Trixie 64-bit). Nu am adăugat surse neoficiale."
    fi

    ok "${#already[@]} pachete deja instalate."
    if (( ${#to_install[@]} == 0 )); then
        ok "Toate dependențele disponibile sunt deja instalate."
        return 0
    fi

    info "Instalez ${#to_install[@]} pachete: ${to_install[*]}"
    # --no-install-recommends păstrează sistemul curat; apt eșuat => oprire
    if ! run_root apt-get install -y --no-install-recommends -- "${to_install[@]}"; then
        die "'apt-get install' a eșuat pentru dependențele Mixxx." \
            "Verifică logul (${LOG_FILE}); încearcă 'sudo apt --fix-broken install' și 'sudo dpkg --configure -a'."
    fi
    ok "Dependențe instalate."
    record "Instalate ${#to_install[@]} pachete de dependențe"
}

# =============================================================================
# ETAPA 5 — Descărcarea Mixxx (clone/update + ultimul tag stabil 2.5.x)
# =============================================================================
# Returnează cel mai nou tag stabil 2.5.N (ignoră alpha/beta/rc/dev)
filter_latest_stable_tag() {
    grep -E "^${MIXXX_SERIES//./\\.}\.[0-9]+$" | sort -V | tail -n1
}

fetch_sources() {
    stage "ETAPA 5/14 — Descărcarea surselor Mixxx"
    need_cmd git || { (( OPT_DRY_RUN )) && { warn "git lipsește (dry-run) — nu pot interoga tag-urile."; LATEST_TAG="${MIXXX_SERIES}.x"; return 0; }
                      die "git nu este instalat." "sudo apt install git"; }

    # 1) Interogăm tag-urile oficiale direct de pe server (read-only)
    info "Interoghez tag-urile din ${MIXXX_REPO_URL} ..."
    local remote_tags
    if ! remote_tags="$(git ls-remote --tags --refs "${MIXXX_REPO_URL}" "refs/tags/${MIXXX_SERIES}.*" 2>>"${LOG_FILE}")"; then
        die "Nu pot contacta repository-ul Mixxx." "Verifică conexiunea la internet / DNS / proxy (git ls-remote ${MIXXX_REPO_URL})."
    fi
    LATEST_TAG="$(awk -F'refs/tags/' '{print $2}' <<<"${remote_tags}" | filter_latest_stable_tag || true)"
    [[ -n "${LATEST_TAG}" ]] || die "Nu am găsit niciun tag stabil ${MIXXX_SERIES}.x." "Verifică manual: git ls-remote --tags ${MIXXX_REPO_URL}"
    ok "Ultima versiune stabilă ${MIXXX_SERIES}.x: ${LATEST_TAG}"
    debug "Tag-uri ${MIXXX_SERIES}.*: $(awk -F'refs/tags/' '{print $2}' <<<"${remote_tags}" | tr '\n' ' ')"

    # 2) Decidem dacă e nevoie de compilare (idempotență)
    if [[ "${INSTALLED_VERSION}" == "${LATEST_TAG}" ]] && (( ! OPT_FORCE )); then
        ok "Mixxx ${LATEST_TAG} este deja instalat."
        if (( ! OPT_DRY_RUN )) && ask_yes_no "Versiunea instalată este deja cea mai nouă. Vrei totuși să recompilezi?" "n"; then
            NEED_BUILD=1
        else
            NEED_BUILD=0
            info "Nu recompilez (folosește --force pentru a forța)."
            record "Mixxx ${LATEST_TAG} deja instalat — compilare sărită"
        fi
    fi
    if (( OPT_SKIP_BUILD )) && [[ ! -x "${BUILD_DIR}/mixxx" ]]; then
        NEED_BUILD=0
    fi
    # Fără compilare și fără surse locale: nu descărcăm inutil ~1 GB
    if (( ! NEED_BUILD )) && [[ ! -d "${SRC_DIR}/.git" ]]; then
        info "Sursele nu sunt necesare (nu se compilează); descărcarea este sărită."
        return 0
    fi

    # 3) Clonare sau actualizare
    if [[ -d "${SRC_DIR}/.git" ]]; then
        local origin
        origin="$(git -C "${SRC_DIR}" remote get-url origin 2>/dev/null || true)"
        if [[ "${origin}" != *"mixxxdj/mixxx"* ]]; then
            die "${SRC_DIR} este un repository git, dar nu al Mixxx (origin: ${origin:-niciunul})." \
                "Mută/redenumește directorul sau schimbă origin la ${MIXXX_REPO_URL}."
        fi
        if [[ -n "$(git -C "${SRC_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            die "Sursele din ${SRC_DIR} au modificări locale; nu le suprascriu." \
                "Salvează-le (git -C ${SRC_DIR} stash) sau anulează-le (git -C ${SRC_DIR} checkout -- .), apoi repornește."
        fi
        info "Repository existent în ${SRC_DIR}; actualizez (fără reclonare)..."
        run git -C "${SRC_DIR}" fetch --tags --force --prune origin \
            || die "git fetch a eșuat." "Verifică rețeaua și rulează: git -C ${SRC_DIR} fetch --tags"
        record "Repository actualizat (git fetch)"
    else
        if [[ -e "${SRC_DIR}" ]] && [[ -n "$(ls -A "${SRC_DIR}" 2>/dev/null)" ]]; then
            die "${SRC_DIR} există și nu este gol, dar nu e un repository git." "Mută directorul sau golește-l, apoi repornește."
        fi
        info "Clonez ${MIXXX_REPO_URL} în ${SRC_DIR} (clone parțial, fără blob-uri istorice)..."
        run mkdir -p "$(dirname "${SRC_DIR}")"
        run git clone --filter=blob:none --no-checkout "${MIXXX_REPO_URL}" "${SRC_DIR}" \
            || die "git clone a eșuat." "Verifică rețeaua și spațiul pe disc, apoi repornește scriptul."
        record "Repository clonat în ${SRC_DIR}"
    fi

    # 4) Verificăm tag-ul și în repository-ul local și facem checkout exact pe el
    if (( ! OPT_DRY_RUN )); then
        local local_latest
        local_latest="$(git -C "${SRC_DIR}" tag -l "${MIXXX_SERIES}.*" | filter_latest_stable_tag || true)"
        [[ "${local_latest}" == "${LATEST_TAG}" ]] \
            || warn "Tag local (${local_latest:-niciunul}) diferă de cel de pe server (${LATEST_TAG}); folosesc ${LATEST_TAG}."
        git -C "${SRC_DIR}" rev-parse -q --verify "refs/tags/${LATEST_TAG}" >/dev/null \
            || die "Tag-ul ${LATEST_TAG} nu există local după fetch." "Rulează: git -C ${SRC_DIR} fetch --tags"
    fi
    local current_tag=""
    [[ -d "${SRC_DIR}/.git" ]] && current_tag="$(git -C "${SRC_DIR}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "${current_tag}" == "${LATEST_TAG}" ]]; then
        ok "Sursele sunt deja pe tag-ul ${LATEST_TAG}."
    else
        info "Checkout tag ${LATEST_TAG}..."
        run git -C "${SRC_DIR}" -c advice.detachedHead=false checkout --detach "refs/tags/${LATEST_TAG}" \
            || die "Checkout pe ${LATEST_TAG} a eșuat." "Verifică: git -C ${SRC_DIR} status"
        ok "Checkout: ${LATEST_TAG} ($(git -C "${SRC_DIR}" rev-parse --short HEAD 2>/dev/null || echo dry-run))"
        record "Checkout Mixxx ${LATEST_TAG}"
    fi
}

# =============================================================================
# ETAPA 6 — Configurarea build-ului (resurse + CMake)
# =============================================================================
check_build_resources() {
    local avail_mb swap_total_mb need_total_mb
    local probe="${SRC_DIR}"
    while [[ ! -d "${probe}" && "${probe}" != "/" ]]; do probe="$(dirname "${probe}")"; done
    FREE_DISK_GB="$(df -BG --output=avail "${probe}" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
    FREE_DISK_GB="${FREE_DISK_GB:-0}"
    if (( FREE_DISK_GB < MIN_FREE_DISK_GB )); then
        die "Spațiu insuficient: ${FREE_DISK_GB} GB liberi (minim ${MIN_FREE_DISK_GB} GB)." \
            "Eliberează spațiu (sudo apt clean, șterge fișiere mari) sau folosește un SSD/card mai mare."
    elif (( FREE_DISK_GB < RECOMMENDED_FREE_DISK_GB )); then
        warn "Spațiu liber ${FREE_DISK_GB} GB (recomandat ${RECOMMENDED_FREE_DISK_GB} GB)."
    else
        ok "Spațiu liber: ${FREE_DISK_GB} GB"
    fi

    avail_mb="$(awk '/^MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
    swap_total_mb="$(awk '/^SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    ok "Memorie disponibilă: ${avail_mb} MB, swap: ${swap_total_mb} MB"

    # Joburi: max 4 (Pi 5 are 4 nuclee), limitate de RAM (~1.5 GB/job).
    # Nu folosim orbește -j$(nproc).
    local by_ram=$(( (RAM_MB + swap_total_mb / 2) / RAM_PER_JOB_MB ))
    BUILD_JOBS="${CPU_CORES}"
    (( BUILD_JOBS > 4 )) && BUILD_JOBS=4
    (( by_ram < BUILD_JOBS )) && BUILD_JOBS="${by_ram}"
    (( BUILD_JOBS < 1 )) && BUILD_JOBS=1
    ok "Joburi de compilare: -j${BUILD_JOBS}"

    # Swap: recomandăm RAM + swap >= joburi * 1.5 GB + 1 GB rezervă
    need_total_mb=$(( BUILD_JOBS * RAM_PER_JOB_MB + 1024 ))
    if (( RAM_MB + swap_total_mb < need_total_mb )) || (( swap_total_mb < 1024 && RAM_MB < 6000 )); then
        warn "Swap redus (${swap_total_mb} MB) pentru compilare cu -j${BUILD_JOBS} pe ${RAM_MB} MB RAM."
        if ask_yes_no "Creez temporar un swap suplimentar de 2 GB (${TEMP_SWAPFILE}), eliminat automat la final?" "y"; then
            enable_temp_swap
        else
            warn "Continui fără swap suplimentar; dacă build-ul eșuează cu 'Killed', rulează din nou și acceptă swap-ul."
        fi
    else
        ok "Memorie + swap suficiente pentru -j${BUILD_JOBS}."
    fi
}

enable_temp_swap() {
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${TEMP_SWAPFILE}"; then
        ok "Swap temporar deja activ."; return 0
    fi
    local fstype
    fstype="$(df --output=fstype "$(dirname "${TEMP_SWAPFILE}")" | tail -n1)"
    if [[ "${fstype}" != "ext4" && "${fstype}" != "xfs" ]]; then
        warn "Sistemul de fișiere ${fstype} nu e potrivit pentru swapfile; sar peste."; return 0
    fi
    info "Creez swap temporar de 2 GB..."
    if run_root fallocate -l 2G "${TEMP_SWAPFILE}" \
        && run_root chmod 600 "${TEMP_SWAPFILE}" \
        && run_root mkswap "${TEMP_SWAPFILE}" \
        && run_root swapon "${TEMP_SWAPFILE}"; then
        (( OPT_DRY_RUN )) || TEMP_SWAP_ACTIVE=1
        ok "Swap temporar activ (nu este adăugat în /etc/fstab)."
        record "Swap temporar 2 GB activat pe durata build-ului"
    else
        run_root rm -f -- "${TEMP_SWAPFILE}" || true
        warn "Nu am putut crea swap temporar; continui fără."
    fi
}

configure_build() {
    stage "ETAPA 6/14 — Configurarea build-ului"
    if (( OPT_SKIP_BUILD )); then warn "Etapa sărită (--skip-build)."; return 0; fi
    if (( ! NEED_BUILD )); then info "Nu este necesară compilarea; etapă sărită."; return 0; fi

    check_build_resources

    need_cmd ninja && CMAKE_GENERATOR="Ninja"
    # Nu putem schimba generatorul unui build existent: păstrăm generatorul din cache
    if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
        local cached_gen
        cached_gen="$(awk -F= '/^CMAKE_GENERATOR:INTERNAL=/ {print $2}' "${BUILD_DIR}/CMakeCache.txt")"
        [[ -n "${cached_gen}" ]] && CMAKE_GENERATOR="${cached_gen}"
        if (( OPT_FORCE )); then
            info "--force: șterg doar CMakeCache.txt (fișierele obiect sunt păstrate)."
            run rm -f -- "${BUILD_DIR}/CMakeCache.txt"
        fi
    fi
    ok "Generator CMake: ${CMAKE_GENERATOR}"

    run mkdir -p "${BUILD_DIR}"
    local -a cmake_args=(
        -S "${SRC_DIR}" -B "${BUILD_DIR}" -G "${CMAKE_GENERATOR}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
        -DBUILD_TESTING=OFF
        -DBUILD_BENCH=OFF
        -DOPTIMIZE=portable
    )
    # Pe sisteme cu RAM redus: fără -pipe (fișiere temporare pe disc)
    (( RAM_MB < 4096 )) && cmake_args+=(-DBUILD_LOW_MEMORY=ON)
    # Notă: dacă libshout-idjc/libkeyfinder lipsesc, Mixxx folosește copiile interne/descărcate

    info "Rulez CMake (Release)..."
    if ! run cmake "${cmake_args[@]}"; then
        FAILED_COMMAND="cmake ${cmake_args[*]}"
        show_log_tail 80
        die "Configurarea CMake a eșuat. Directorul ${BUILD_DIR} a fost păstrat pentru depanare." \
            "Caută 'Could NOT find' / 'CMake Error' în log; instalează pachetul -dev lipsă și repornește."
    fi
    ok "CMake configurat în ${BUILD_DIR}"
    record "CMake configurat (Release, prefix ${INSTALL_PREFIX})"
}

show_log_tail() {
    local n="${1:-80}"
    [[ -r "${LOG_FILE}" ]] || return 0
    printf '%s--- Ultimele %s linii relevante din log ---%s\n' "${C_BOLD}" "${n}" "${C_RESET}" >&2
    # Preferăm liniile de eroare; dacă nu există, afișăm coada logului
    echo "Linii cu erori (ultimele 25):" >&2
    grep -nE 'error:|CMake Error|Could NOT find|FAILED|Killed|fatal' "${LOG_FILE}" | tail -n 25 >&2 || true
    echo "Sfârșitul logului:" >&2
    tail -n "${n}" "${LOG_FILE}" >&2
    printf '%s-------------------------------------------%s\n' "${C_BOLD}" "${C_RESET}" >&2
}

# =============================================================================
# ETAPA 7 — Compilarea
# =============================================================================
build_mixxx() {
    stage "ETAPA 7/14 — Compilarea"
    if (( OPT_SKIP_BUILD )); then warn "Etapa sărită (--skip-build)."; return 0; fi
    if (( ! NEED_BUILD )); then info "Nu este necesară compilarea; etapă sărită."; return 0; fi

    info "Compilez Mixxx ${LATEST_TAG} cu -j${BUILD_JOBS} (pe Raspberry Pi 5: ~40-90 minute)..."
    if (( OPT_DRY_RUN )); then
        run cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"
        return 0
    fi

    local start end rc=0
    start="$(date +%s)"
    log_raw "[RUN] cmake --build ${BUILD_DIR} --parallel ${BUILD_JOBS}"
    # Ieșirea completă merge în log; în terminal afișăm progresul ([ 42%] sau [123/2000]).
    # Cu pipefail, "|| rc=$?" capturează codul lui cmake (tee/awk nu eșuează).
    cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}" 2>&1 \
        | tee -a "${LOG_FILE}" \
        | awk -v verbose="${OPT_VERBOSE}" -v tty="$([[ -t 1 ]] && echo 1 || echo 0)" '
            verbose == 1 { print; fflush(); next }
            match($0, /^\[ *[0-9]+%\]|^\[[0-9]+\/[0-9]+\]/) {
                p = substr($0, RSTART, RLENGTH)
                if (tty == 1) { printf "\r  Progres build: %-14s", p; fflush() }
                else if (++n % 200 == 0) { print "  Progres build: " p; fflush() }
                next
            }
            /error:|Error [0-9]|FAILED:|Killed/ { if (tty == 1) printf "\n"; print "  " $0; fflush() }
            END { if (tty == 1) printf "\n" }' || rc=$?
    end="$(date +%s)"

    if (( rc != 0 )); then
        FAILED_COMMAND="cmake --build ${BUILD_DIR} --parallel ${BUILD_JOBS} (cod ${rc})"
        show_log_tail 100
        local sugg="Directorul build și sursele au fost păstrate. Repornește scriptul pentru a relua compilarea incremental."
        grep -q -E 'Killed|out of memory|internal compiler error' "${LOG_FILE}" \
            && sugg="Memorie insuficientă (OOM). Repornește scriptul și acceptă swap-ul temporar, sau închide alte aplicații."
        die "Compilarea a eșuat." "${sugg}"
    fi
    [[ -x "${BUILD_DIR}/mixxx" ]] || die "Build terminat, dar ${BUILD_DIR}/mixxx lipsește." "Verifică logul: ${LOG_FILE}"
    ok "Compilare reușită în $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s."
    record "Mixxx ${LATEST_TAG} compilat (-j${BUILD_JOBS})"
}

# =============================================================================
# ETAPA 8 — Instalarea (staging -> verificare -> instalare în sistem)
# =============================================================================
verify_binary() {
    # $1 = executabil, $2 = context (pentru mesaje), $3 = LD_LIBRARY_PATH opțional
    local bin="$1" ctx="$2" desc missing
    [[ -x "${bin}" ]] || { error "${ctx}: ${bin} nu există sau nu e executabil."; return 1; }
    desc="$(file -L "${bin}" 2>/dev/null || true)"
    if [[ "${desc}" != *"ARM aarch64"* ]]; then
        error "${ctx}: arhitectură neașteptată: ${desc}"; return 1
    fi
    missing="$(ldd "${bin}" 2>/dev/null | grep 'not found' || true)"
    if [[ -n "${missing}" ]]; then
        error "${ctx}: biblioteci lipsă:"; printf '    %s\n' "${missing}" >&2; return 1
    fi
    return 0
}

install_mixxx() {
    stage "ETAPA 8/14 — Instalarea"
    if (( ! NEED_BUILD )) || [[ ! -x "${BUILD_DIR}/mixxx" && OPT_DRY_RUN -eq 0 ]]; then
        if [[ -n "${INSTALLED_BIN}" ]]; then
            info "Păstrez instalarea existentă: ${INSTALLED_BIN} (${INSTALLED_VERSION})."
        else
            (( OPT_SKIP_BUILD )) && die "--skip-build: nu există nici build, nici instalare Mixxx." \
                "Rulează scriptul fără --skip-build."
        fi
        return 0
    fi

    # 8.1 Instalare de probă în ${STAGE_DIR} (versiunea existentă rămâne neatinsă)
    info "Instalare de probă (staging) în ${STAGE_DIR} ..."
    safe_rm_dir "${STAGE_DIR}" "${BUILD_DIR}"
    run env DESTDIR="${STAGE_DIR}" cmake --install "${BUILD_DIR}" \
        || die "Instalarea de probă (DESTDIR) a eșuat." "Verifică logul: ${LOG_FILE}"

    if (( ! OPT_DRY_RUN )); then
        local staged="${STAGE_DIR}${INSTALL_PREFIX}/bin/mixxx" staged_ver
        verify_binary "${staged}" "Staging" \
            || die "Executabilul nou nu a trecut verificarea; instalarea existentă a fost păstrată." \
                   "Verifică logul și rulează: ldd ${staged}"
        staged_ver="$(mixxx_version_of "${staged}")"
        info "Versiune build nou: ${staged_ver:-necunoscută (mixxx --version nu a răspuns)}"
        if [[ -n "${staged_ver}" && "${staged_ver}" != "${LATEST_TAG}"* ]]; then
            warn "Versiunea raportată (${staged_ver}) diferă de tag-ul ${LATEST_TAG}."
        fi
        ok "Build-ul nou a fost verificat (arhitectură, biblioteci, --version)."
    fi

    # 8.2 Backup al executabilului vechi (dacă există) înainte de suprascriere
    if [[ -x "${INSTALL_PREFIX}/bin/mixxx" ]]; then
        local backup="${INSTALL_PREFIX}/bin/mixxx.previous"
        info "Păstrez executabilul anterior ca ${backup}"
        run_root cp -a -- "${INSTALL_PREFIX}/bin/mixxx" "${backup}"
        record "Backup executabil anterior: ${backup}"
    fi

    # 8.3 Instalarea reală în ${INSTALL_PREFIX}
    info "Instalez în ${INSTALL_PREFIX} ..."
    run_root cmake --install "${BUILD_DIR}" \
        || die "'cmake --install' a eșuat." "Verifică permisiunile și logul: ${LOG_FILE}"
    run_root ldconfig || true
    safe_rm_dir "${STAGE_DIR}" "${BUILD_DIR}"

    # Starea instalării (pentru idempotență)
    run_root mkdir -p "${STATE_DIR}"
    if (( ! OPT_DRY_RUN )); then
        printf 'installed_tag=%s\ninstalled_at=%s\nsource_dir=%s\nbuild_dir=%s\n' \
            "${LATEST_TAG}" "$(date '+%F %T')" "${SRC_DIR}" "${BUILD_DIR}" \
            | "${SUDO[@]}" tee "${STATE_FILE}" >/dev/null
    fi

    detect_installed_mixxx
    (( OPT_DRY_RUN )) && { ok "(dry-run) Instalare simulată."; return 0; }
    [[ -x "${INSTALL_PREFIX}/bin/mixxx" ]] || die "Executabilul ${INSTALL_PREFIX}/bin/mixxx lipsește după instalare."
    ok "Mixxx instalat: ${INSTALL_PREFIX}/bin/mixxx (versiune ${INSTALLED_VERSION})"
    record "Mixxx ${INSTALLED_VERSION} instalat în ${INSTALL_PREFIX}"

    # 8.4 Reguli udev pentru controllere HID/USB Bulk (CMake le pune doar în share/)
    local rules_src="${INSTALL_PREFIX}/share/mixxx/udev/rules.d/mixxx-usb-uaccess.rules"
    local rules_dst="/etc/udev/rules.d/69-mixxx-usb-uaccess.rules"
    if [[ -f "${rules_src}" ]]; then
        if [[ -f "${rules_dst}" ]] && cmp -s "${rules_src}" "${rules_dst}"; then
            ok "Regulile udev Mixxx sunt deja instalate."
        elif ask_yes_no "Instalez regulile udev Mixxx (acces la controllere HID/USB fără root) în ${rules_dst}?" "y"; then
            run_root install -m 644 -- "${rules_src}" "${rules_dst}"
            run_root udevadm control --reload-rules || true
            run_root udevadm trigger || true
            ok "Reguli udev instalate."
            record "Reguli udev pentru controllere: ${rules_dst}"
        fi
    fi
}

# =============================================================================
# ETAPA 9 — Desktop entry
# =============================================================================
setup_desktop_entry() {
    stage "ETAPA 9/14 — Lansator în meniu (.desktop)"
    local installed_desktop="${INSTALL_PREFIX}/share/applications/org.mixxx.Mixxx.desktop"
    local custom_desktop="${INSTALL_PREFIX}/share/applications/mixxx-rpi5.desktop"

    if [[ -f "${installed_desktop}" ]]; then
        ok "Lansatorul creat de instalare există: ${installed_desktop}"
    elif [[ -f /usr/share/applications/org.mixxx.Mixxx.desktop ]]; then
        ok "Lansator Mixxx existent: /usr/share/applications/org.mixxx.Mixxx.desktop"
    elif [[ -f "${custom_desktop}" ]]; then
        ok "Lansator existent: ${custom_desktop}"
    elif [[ -x "${INSTALL_PREFIX}/bin/mixxx" || OPT_DRY_RUN -eq 1 ]]; then
        info "Nu există lansator; creez ${custom_desktop}"
        # Icon: preferăm tema hicolor instalată, altfel icon-ul din surse
        local icon="mixxx"
        if [[ ! -e "${INSTALL_PREFIX}/share/icons/hicolor/scalable/apps/mixxx.svg" ]]; then
            local src_icon
            src_icon="$(find "${SRC_DIR}/res/images" -maxdepth 2 -name 'mixxx_icon.svg' -print -quit 2>/dev/null || true)"
            [[ -n "${src_icon}" ]] && icon="${src_icon}"
        fi
        local tmp_desktop
        tmp_desktop="$(mktemp)"
        cat >"${tmp_desktop}" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Mixxx
GenericName=Digital DJ interface
GenericName[ro]=Sistem DJ digital
Comment=A digital DJ interface
Exec=${INSTALL_PREFIX}/bin/mixxx
Icon=${icon}
Terminal=false
StartupNotify=true
StartupWMClass=org.mixxx.mixxx
Categories=Qt;AudioVideo;Audio;Midi;Mixer;Player;
Keywords=dj;music;alsa;jack;
EOF
        if need_cmd desktop-file-validate && ! desktop-file-validate "${tmp_desktop}" >>"${LOG_FILE}" 2>&1; then
            warn "desktop-file-validate a raportat probleme (vezi log)."
        fi
        run_root install -m 644 -- "${tmp_desktop}" "${custom_desktop}"
        rm -f -- "${tmp_desktop}"
        record "Lansator creat: ${custom_desktop}"
        ok "Lansator creat."
    else
        warn "Mixxx nu este instalat; nu creez lansator."
        return 0
    fi
    # Reîmprospătăm cache-urile de meniu/icon (fără a modifica configurația desktop)
    need_cmd update-desktop-database && run_root update-desktop-database -q "${INSTALL_PREFIX}/share/applications" || true
    need_cmd gtk-update-icon-cache && [[ -d "${INSTALL_PREFIX}/share/icons/hicolor" ]] \
        && run_root gtk-update-icon-cache -q -f "${INSTALL_PREFIX}/share/icons/hicolor" || true
    return 0
}

# =============================================================================
# ETAPA 10 — Detectarea sistemului audio (fără modificări!)
# =============================================================================
detect_audio() {
    stage "ETAPA 10/14 — Detectarea sistemului audio (doar citire)"
    local -a backends=()

    # ALSA
    if [[ -r /proc/asound/cards ]] && grep -q '^ *[0-9]' /proc/asound/cards; then
        ok "ALSA: activ. Plăci de sunet:"
        grep -E '^ *[0-9]+ \[' /proc/asound/cards | sed 's/^/    /'
        backends+=("ALSA")
    else
        warn "ALSA: nu am găsit plăci de sunet în /proc/asound/cards."
    fi

    # PipeWire (implicit pe Raspberry Pi OS Bookworm/Trixie)
    if pgrep -x pipewire >/dev/null 2>&1; then
        ok "PipeWire: rulează$(pgrep -x wireplumber >/dev/null 2>&1 && echo ' (cu WirePlumber)')"
        backends+=("PipeWire")
        if need_cmd pw-jack || dpkg -s pipewire-jack >/dev/null 2>&1; then
            ok "PipeWire-JACK: disponibil (pw-jack)"
        fi
        pgrep -x pipewire-pulse >/dev/null 2>&1 && ok "PipeWire-Pulse: rulează"
    elif need_cmd pipewire; then
        info "PipeWire: instalat, dar nu rulează (normal dacă nu ești în sesiunea desktop)."
    else
        info "PipeWire: nu este instalat."
    fi
    if pgrep -x pulseaudio >/dev/null 2>&1; then ok "PulseAudio: rulează"; backends+=("PulseAudio"); fi

    # JACK
    if pgrep -x jackd >/dev/null 2>&1 || pgrep -x jackdbus >/dev/null 2>&1; then
        ok "JACK: serverul rulează"; backends+=("JACK")
    elif need_cmd jackd; then
        info "JACK: instalat, serverul nu rulează."
    else
        info "JACK: serverul jackd nu este instalat (nu este necesar)."
    fi

    # Dispozitive audio USB
    USB_AUDIO_DEVICES=""
    local card
    for card in /proc/asound/card[0-9]*; do
        [[ -e "${card}/usbid" ]] || continue
        USB_AUDIO_DEVICES+="$(cat "${card}/id" 2>/dev/null || echo "${card##*/}") [$(cat "${card}/usbid" 2>/dev/null || true)]; "
    done
    USB_AUDIO_DEVICES="${USB_AUDIO_DEVICES%; }"
    if [[ -n "${USB_AUDIO_DEVICES}" ]]; then
        ok "Plăci audio USB: ${USB_AUDIO_DEVICES}"
    else
        info "Nicio placă audio USB detectată."
    fi

    if need_cmd aplay; then
        debug "$(aplay -l 2>&1 || true)"
        aplay -l >>"${LOG_FILE}" 2>&1 || true
    fi

    # Grup audio (acces direct ALSA / realtime)
    if [[ "${TARGET_USER}" == "root" ]]; then
        :
    elif id -nG "${TARGET_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx audio; then
        ok "Utilizatorul ${TARGET_USER} este în grupul 'audio'."
    else
        warn "Utilizatorul ${TARGET_USER} nu este în grupul 'audio' (recomandat pentru ALSA direct): sudo usermod -aG audio ${TARGET_USER}"
    fi

    if (( ${#backends[@]} )); then
        AUDIO_BACKEND="$(printf '%s + ' "${backends[@]}")"
        AUDIO_BACKEND="${AUDIO_BACKEND% + }"
    else
        AUDIO_BACKEND="niciunul detectat"
    fi
    info "NU am modificat configurația audio (etapă doar informativă)."
}

# =============================================================================
# ETAPA 11 — Detectarea controllerelor DJ (MIDI/HID)
# =============================================================================
detect_controllers() {
    stage "ETAPA 11/14 — Detectarea controllerelor DJ"
    if need_cmd lsusb; then
        info "Dispozitive USB conectate:"
        lsusb | sed 's/^/    /' | tee -a "${LOG_FILE}"
    else
        warn "lsusb lipsește (pachetul usbutils); listare limitată."
    fi

    # Controllere MIDI prin ALSA sequencer / rawmidi
    USB_MIDI_DEVICES=""
    if [[ -r /proc/asound/cards ]]; then
        local card
        for card in /proc/asound/card[0-9]*; do
            compgen -G "${card}/midi*" >/dev/null || continue
            USB_MIDI_DEVICES+="$(cat "${card}/id" 2>/dev/null || echo "${card##*/}")"
            if [[ -e "${card}/usbid" ]]; then
                USB_MIDI_DEVICES+=" [$(cat "${card}/usbid" 2>/dev/null || true)]"
            fi
            USB_MIDI_DEVICES+="; "
        done
    fi
    USB_MIDI_DEVICES="${USB_MIDI_DEVICES%; }"
    if need_cmd amidi; then
        local amidi_out
        amidi_out="$(amidi -l 2>/dev/null | tail -n +2 || true)"
        [[ -n "${amidi_out}" ]] && { ok "Porturi MIDI (amidi -l):"; sed 's/^/    /' <<<"${amidi_out}"; }
    fi
    if [[ -n "${USB_MIDI_DEVICES}" ]]; then
        ok "Controllere MIDI: ${USB_MIDI_DEVICES}"
    else
        info "Niciun controller MIDI detectat."
    fi

    # Controllere HID (hidraw) — multe controllere DJ folosesc HID
    local hid dev_name found_hid=0
    for hid in /sys/class/hidraw/hidraw*; do
        [[ -e "${hid}" ]] || continue
        dev_name="$(grep -h '^HID_NAME=' "${hid}/device/uevent" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "${dev_name}" ]] || continue
        if (( ! found_hid )); then ok "Dispozitive HID:"; found_hid=1; fi
        printf '    /dev/%s: %s\n' "$(basename "${hid}")" "${dev_name}"
    done
    (( found_hid )) || info "Niciun dispozitiv HID (hidraw) detectat."

    if [[ -f /etc/udev/rules.d/69-mixxx-usb-uaccess.rules ]]; then
        ok "Reguli udev Mixxx active: controllerele HID/Bulk pot fi accesate fără root."
    else
        info "Regulile udev Mixxx nu sunt instalate în /etc/udev/rules.d (controllerele HID pot necesita permisiuni)."
    fi
    info "Nu au fost instalate drivere proprietare. Mapările controllerelor sunt incluse în Mixxx (Preferences → Controllers)."
}

# =============================================================================
# ETAPA 12 — Test final
# =============================================================================
FINAL_TEST_OK=1
final_tests() {
    stage "ETAPA 12/14 — Test final"
    local bin="${INSTALL_PREFIX}/bin/mixxx"
    [[ -x "${bin}" ]] || bin="${INSTALLED_BIN}"

    if (( OPT_DRY_RUN )) && [[ -z "${bin}" || ! -x "${bin}" ]]; then
        info "(dry-run) Mixxx nu este instalat încă; testele ar rula după instalare."
        return 0
    fi

    # 1. Executabil
    if [[ -n "${bin}" && -x "${bin}" ]]; then ok "Executabil: ${bin}"; else error "Executabilul mixxx nu a fost găsit."; FINAL_TEST_OK=0; return 0; fi

    # 2. mixxx --version
    local ver
    ver="$(mixxx_version_of "${bin}")"
    if [[ -n "${ver}" ]]; then
        ok "mixxx --version: ${ver}"; INSTALLED_VERSION="${ver}"
    else
        warn "mixxx --version nu a răspuns (poate necesita sesiune grafică)."
    fi

    # 3. Arhitectura executabilului + 4. biblioteci dinamice
    if verify_binary "${bin}" "Test final"; then
        ok "Arhitectură: $(file -L "${bin}" | grep -oE 'ARM aarch64[^,]*')"
        ok "ldd: toate bibliotecile dinamice sunt găsite ($(ldd "${bin}" | wc -l) biblioteci)."
    else
        FINAL_TEST_OK=0
    fi

    # 5. Spațiu pe disc
    FREE_DISK_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
    if (( FREE_DISK_GB >= 2 )); then ok "Spațiu liber: ${FREE_DISK_GB} GB"; else warn "Spațiu liber foarte redus: ${FREE_DISK_GB} GB"; fi

    # 6. Sistem audio
    if [[ "${AUDIO_BACKEND}" != "niciunul detectat" ]]; then ok "Audio: ${AUDIO_BACKEND}"; else warn "Niciun sistem audio activ detectat."; fi

    # 7. Acces USB
    if [[ -d /dev/bus/usb ]] && need_cmd lsusb && lsusb >/dev/null 2>&1; then
        ok "Acces USB: OK ($(lsusb | wc -l) dispozitive)"
    elif [[ -d /dev/bus/usb ]]; then
        ok "Acces USB: /dev/bus/usb prezent"
    else
        warn "Acces USB: /dev/bus/usb lipsește."
    fi

    if (( FINAL_TEST_OK )); then
        printf '\n%sMixxx a fost instalat cu succes.%s\n\n' "${C_GREEN}" "${C_RESET}"
        log_raw "Mixxx a fost instalat cu succes."
        echo "  Versiune Mixxx : ${INSTALLED_VERSION:-necunoscută}"
        echo "  Executabil     : ${bin}"
        echo "  Surse          : ${SRC_DIR}"
        echo "  Build          : ${BUILD_DIR}"
        echo "  Log            : ${LOG_FILE}"
        echo "  Pornire        : mixxx   (sau din meniu: Sound & Video → Mixxx)"
    else
        die "Testul final a eșuat." "Verifică mesajele de mai sus și logul ${LOG_FILE}."
    fi
}

print_audio_recommendations() {
    echo
    printf '%sRecomandări configurare audio în Mixxx (Preferences → Sound Hardware):%s\n' "${C_BOLD}" "${C_RESET}"
    if [[ "${AUDIO_BACKEND}" == *PipeWire* ]]; then
        echo "  • PipeWire detectat: alege Sound API 'JACK Audio Connection Kit' și pornește Mixxx"
        echo "    cu 'pw-jack mixxx' pentru latență mică, sau 'ALSA' cu dispozitivul 'pipewire'/'default'."
    fi
    if [[ "${AUDIO_BACKEND}" == *JACK* ]]; then
        echo "  • Server JACK activ: Sound API 'JACK Audio Connection Kit'."
    fi
    if [[ -n "${USB_AUDIO_DEVICES}" ]]; then
        echo "  • Placă USB (${USB_AUDIO_DEVICES}): Sound API 'ALSA', dispozitivul 'hw:<placă>' pentru latență minimă;"
        echo "    buffer 10–23 ms la 44100/48000 Hz. Master pe canalele 1-2, Headphones pe 3-4 (dacă există)."
    else
        echo "  • Fără placă USB: ieșirea HDMI/jack a Pi 5 nu oferă cue separat; o interfață audio USB este recomandată."
    fi
    echo "  • Pe Raspberry Pi 5 folosește skin-ul 'LateNight' sau 'Tango' și dezactivează forma de undă HD dacă apar sacadări."
}

# =============================================================================
# ETAPA 13 — Pornirea Mixxx (doar cu confirmare)
# =============================================================================
maybe_start_mixxx() {
    stage "ETAPA 13/14 — Pornire Mixxx"
    local bin="${INSTALL_PREFIX}/bin/mixxx"
    [[ -x "${bin}" ]] || bin="${INSTALLED_BIN}"
    if [[ -z "${bin}" ]] && (( ! OPT_DRY_RUN )); then warn "Mixxx nu este instalat."; return 0; fi
    if (( OPT_YES )); then info "--yes nu pornește automat Mixxx. Pornire manuală: mixxx"; return 0; fi

    if ! ask_yes_no "Vrei să pornesc Mixxx acum?" "n"; then
        info "Poți porni Mixxx oricând cu: mixxx"; return 0
    fi
    bin="${bin:-${INSTALL_PREFIX}/bin/mixxx}"

    local uid runtime
    uid="$(id -u "${TARGET_USER}")"
    runtime="/run/user/${uid}"
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && ! -S "${runtime}/wayland-0" && ! -S "${runtime}/wayland-1" && ! -e /tmp/.X11-unix/X0 ]]; then
        warn "Nu am găsit o sesiune grafică (DISPLAY/WAYLAND_DISPLAY). Pornește Mixxx din desktop."
        return 0
    fi

    if (( EUID == 0 )) && [[ "${TARGET_USER}" != "root" ]]; then
        # Nu rulăm aplicații grafice ca root: pornim ca utilizatorul real
        local wl="${WAYLAND_DISPLAY:-}"
        [[ -z "${wl}" && -S "${runtime}/wayland-0" ]] && wl="wayland-0"
        [[ -z "${wl}" && -S "${runtime}/wayland-1" ]] && wl="wayland-1"
        run sudo -u "${TARGET_USER}" -H env \
            XDG_RUNTIME_DIR="${runtime}" \
            DISPLAY="${DISPLAY:-:0}" \
            ${wl:+WAYLAND_DISPLAY="${wl}"} \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus" \
            setsid -f "${bin}"
    else
        if (( OPT_DRY_RUN )); then run setsid -f "${bin}"; else setsid -f "${bin}" >/dev/null 2>&1 </dev/null; fi
    fi
    MIXXX_STARTED=1  # pornit la cererea utilizatorului
    ok "Mixxx a fost pornit."
    record "Mixxx pornit de utilizator"
}

# =============================================================================
# ETAPA 14 — Raport final
# =============================================================================
final_report() {
    REPORT_DONE=1
    set +e
    [[ "${INSTALL_STATUS}" == "IN PROGRESS" ]] && INSTALL_STATUS="SUCCESS"
    (( OPT_DRY_RUN )) && [[ "${INSTALL_STATUS}" == "SUCCESS" ]] && INSTALL_STATUS="SUCCESS (DRY-RUN — nimic nu a fost modificat)"
    FREE_DISK_GB="$(df -BG --output=avail / 2>/dev/null | tail -n1 | tr -dc '0-9')"

    local report
    report="$(
        echo
        echo "========================================"
        echo "MIXXX INSTALLATION SUMMARY"
        echo "========================================"
        echo "OS:                ${OS_PRETTY:-?} (Debian ${DEBIAN_VERSION:-?})"
        echo "Architecture:      ${ARCH:-?}"
        echo "Raspberry Pi:      ${PI_MODEL:-?}$( (( IS_PI5 )) && echo ' (Pi 5: da)' || echo ' (Pi 5: nu)')"
        echo "CPU:               ${CPU_CORES:-?} cores${CPU_MODEL:+ (${CPU_MODEL})}"
        echo "RAM:               ${RAM_MB:-?} MB"
        echo "Mixxx version:     ${INSTALLED_VERSION:-neinstalat} (ultimul stabil: ${LATEST_TAG:-?})"
        echo "Install path:      ${INSTALLED_BIN:-${INSTALL_PREFIX}/bin/mixxx}"
        echo "Source path:       ${SRC_DIR:-?}"
        echo "Build path:        ${BUILD_DIR:-?}"
        echo "Audio backend:     ${AUDIO_BACKEND:-nedetectat}"
        echo "USB audio devices: ${USB_AUDIO_DEVICES:-niciunul}"
        echo "USB MIDI devices:  ${USB_MIDI_DEVICES:-niciunul}"
        echo "Free disk space:   ${FREE_DISK_GB:-?} GB"
        echo "Log file:          ${LOG_FILE}"
        echo "Mixxx pornit:      $( (( MIXXX_STARTED )) && echo da || echo nu)"
        echo "Status:            ${INSTALL_STATUS}"
        if [[ "${INSTALL_STATUS}" == FAILED* ]]; then
            echo "----------------------------------------"
            echo "Etapa eșuată:      ${CURRENT_STAGE}"
            echo "Comanda eșuată:    ${FAILED_COMMAND:-?}"
            echo "Cod ieșire:        ${FAILED_EXIT_CODE}"
            echo "Mesaj eroare:"
            if [[ -r "${LOG_FILE}" ]]; then
                grep -E 'error|Error|ERROR|FAILED|Could NOT find|E: ' "${LOG_FILE}" | grep -v '^\s*$' | tail -n 8 | sed 's/^/    /'
            fi
            echo "Sursele și build-ul au fost păstrate pentru depanare."
        fi
        if (( ${#SUMMARY_ACTIONS[@]} )); then
            echo "----------------------------------------"
            echo "Operațiuni efectuate:"
            printf '  - %s\n' "${SUMMARY_ACTIONS[@]}"
        fi
        if (( ${#WARNINGS[@]} )); then
            echo "----------------------------------------"
            echo "Avertismente (${#WARNINGS[@]}):"
            printf '  - %s\n' "${WARNINGS[@]}"
        fi
        echo "========================================"
    )"
    printf '%s\n' "${report}"
    [[ -w "${LOG_FILE}" ]] && printf '%s\n' "${report}" >>"${LOG_FILE}"
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    setup_privileges
    setup_logging

    check_hardware              # Etapa 1
    check_system                # Etapa 2
    update_system               # Etapa 3
    install_dependencies        # Etapa 4
    fetch_sources               # Etapa 5
    configure_build             # Etapa 6
    build_mixxx                 # Etapa 7
    install_mixxx               # Etapa 8
    setup_desktop_entry         # Etapa 9
    detect_audio                # Etapa 10
    detect_controllers          # Etapa 11
    final_tests                 # Etapa 12
    print_audio_recommendations

    # Swap-ul temporar nu mai este necesar după build
    if (( TEMP_SWAP_ACTIVE )); then
        "${SUDO[@]}" swapoff "${TEMP_SWAPFILE}" >>"${LOG_FILE}" 2>&1 && "${SUDO[@]}" rm -f -- "${TEMP_SWAPFILE}"
        TEMP_SWAP_ACTIVE=0
        ok "Swap temporar eliminat."
    fi

    maybe_start_mixxx           # Etapa 13
    stage "ETAPA 14/14 — Raport final"
    final_report                # Etapa 14
}

main "$@"
