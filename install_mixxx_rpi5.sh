#!/usr/bin/env bash
# =============================================================================
#  install_mixxx_rpi5.sh
#
#  Compilează și instalează ultima versiune STABILĂ Mixxx 2.5.x din sursele
#  oficiale (https://github.com/mixxxdj/mixxx.git) pe:
#
#      Raspberry Pi 5  +  Debian GNU/Linux 13 (Trixie)  +  ARM64 / aarch64
#
#  Scriptul NU presupune Raspberry Pi OS Bookworm: folosește doar
#  repository-urile Debian deja configurate și detectează numele pachetelor.
#
# -----------------------------------------------------------------------------
#  ANALIZA DE COMPATIBILITATE (Mixxx 2.5.x pe Debian 13 Trixie arm64)
# -----------------------------------------------------------------------------
#  Surse verificate:
#    * CMakeLists.txt al tag-ului oficial 2.5.6 (ultimul stabil la redactare);
#    * pachetul Debian "mixxx" 2.5.0+dfsg-3 (Debian Multimedia Team), construit
#      pentru arm64 cu Qt 6.8 / FFmpeg 7 / TagLib 2. Build-Depends-urile lui
#      confirmă numele pachetelor Debian 13 (libtag-dev, qt6-svg-dev, ...).
#
#  Componentă      Debian 13        Cerință Mixxx 2.5.x          Verdict
#  --------------  ---------------  ---------------------------  -------------------------------
#  CMake           3.31.x           >= 3.21                      OK
#  GCC/G++         14.2             C++20                        OK (Debian compilează Mixxx 2.5 cu GCC 14)
#  Qt6             6.8.2            >= 6.2                       OK - de la Qt 6.8 WorkerScript e în
#                                                                QmlMeta; CMake-ul Mixxx tratează explicit
#  FFmpeg          7.1.x            avcodec/avformat/avutil/     OK (pachetul Debian 2.5 e construit pe
#                                   swresample                   FFmpeg 7)
#  TagLib          2.0.x            >= 1.11, suportă TagLib 2    OK - pachetul real e "libtag-dev";
#                                                                "libtag1-dev" e doar tranzițional
#  protobuf        3.21.12          3.x                          OK
#  Rubber Band     3.3.x            rubberband (motor R3)        OK
#  Chromaprint     1.5.x            chromaprint                  OK
#  HIDAPI          0.14.x           >= 0.11.2                    OK
#  libusb          1.0.2x           1.0                          OK
#  SoundTouch      2.3.x            >= 2.1.2                     OK
#  libdjinterop    0.22.x           EXACT 0.24.3 (Mixxx 2.5.6)   NU se potrivește -> CMake-ul Mixxx
#                                                                descarcă 0.24.3, verificat SHA256
#  libkeyfinder    absent din       >= 2.2.4                     CMake-ul Mixxx descarcă sursa oficială
#                  Debian                                        mixxxdj/libkeyfinder, verificat SHA256
#  ALSA/JACK/PA    1.2.x/1.9.x      portaudio19-dev + libjack    OK (PipeWire oferă API JACK/Pulse)
#
#  Probleme cunoscute / adaptări:
#   1. ARM64: singurul patch Debian legat de ARM (remove_inappropriate_arm_flags)
#      privește DOAR ARM 32-bit (armv7: -mfpu=neon). Pe aarch64 nu e necesar
#      niciun patch: NEON face parte din baza ARMv8.
#   2. Optimizări CPU: OPTIMIZE=portable pe aarch64 adaugă doar -O3 (fără
#      -march/-mcpu). NU folosim -mcpu=cortex-a76 / -march=native: Mixxx
#      recomandă "portable" pentru build-uri distribuibile.
#   3. Wayland: Debian lansează Mixxx cu "-platform xcb" (bug Debian #1039859,
#      GUI defect sub Wayland). Scriptul oferă, cu confirmare, un launcher
#      suplimentar "Mixxx (XWayland)" dacă sesiunea este Wayland.
#   4. GPU: formele de undă folosesc OpenGL. Pe Pi 5 accelerarea necesită
#      driverul Mesa "v3d". Fără v3d rulează llvmpipe (software) -> warning.
#   5. Kernelul Raspberry Pi pentru Pi 5 folosește pagini de 16 KB; Mixxx nu
#      are probleme cunoscute cu 16K, dar valoarea este logată pentru depanare.
#   6. /opt/mixxx-source aparține utilizatorului real; compilarea rulează ca
#      acel utilizator (NU root). Doar apt și "cmake --install" folosesc root.
#
#  Etape:
#    1 Detectare sistem   6 Configurare build   11 Controllere USB DJ
#    2 Repository-uri APT 7 Compilare           12 Verificare finală
#    3 Actualizare        8 Instalare           13 Test de pornire
#    4 Dependențe         9 Launcher desktop    14 Raport final
#    5 Surse Mixxx        10 Audio backend
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constante
# -----------------------------------------------------------------------------
readonly SCRIPT_NAME="install_mixxx_rpi5.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly MIXXX_REPO_URL="https://github.com/mixxxdj/mixxx.git"
readonly MIXXX_SERIES="2.5"
readonly SRC_DIR="/opt/mixxx-source"
readonly BUILD_DIR="${SRC_DIR}/build"
readonly STAGE_DIR="${BUILD_DIR}/stage"
readonly INSTALL_PREFIX="/usr/local"
readonly STATE_DIR="/var/lib/mixxx-installer"
readonly STATE_FILE="${STATE_DIR}/state"
readonly TEMP_SWAPFILE="/var/tmp/mixxx-build.swap"
readonly MIN_CMAKE="3.21"
readonly MIN_QT="6.2"
readonly MIN_FREE_DISK_GB=6
readonly RECOMMENDED_FREE_DISK_GB=10
readonly RAM_PER_JOB_MB=1500       # consum estimat per job de compilare C++/Qt
readonly MAX_DEFAULT_JOBS=4        # Pi 5 are 4 nuclee: niciodată -j8 automat

# -----------------------------------------------------------------------------
# Opțiuni
# -----------------------------------------------------------------------------
OPT_NO_UPGRADE=0; OPT_SKIP_DEPS=0; OPT_SKIP_BUILD=0; OPT_FORCE=0
OPT_DRY_RUN=0; OPT_VERBOSE=0; OPT_YES=0; OPT_JOBS=""; OPT_CONFIGURE_SWAP=0
OPT_SYSTEM_INFO=0; OPT_CHECK_DEPS=0; OPT_NO_EXTERNAL=0
READ_ONLY=0                        # 1 pentru --dry-run / --system-info / --check-dependencies

# -----------------------------------------------------------------------------
# Stare globală
# -----------------------------------------------------------------------------
LOG_FILE=""
CURRENT_STAGE="Initializare"
LAST_RUN=""                        # ultima comandă executată prin run_*
FAILED_COMMAND=""; FAILED_EXIT_CODE=0; FAILED_MESSAGE=""
INSTALL_STATUS="IN PROGRESS"
REPORT_DONE=0; EARLY_EXIT=0
declare -a SUDO=()
declare -a SUMMARY_ACTIONS=() WARNINGS=()
declare -A APT_CANDIDATE=()        # pachet -> versiune candidat (apt-cache policy)
declare -A DEP_CHOSEN=()           # nume principal din tabel -> pachetul ales

# Utilizatorul real (cel care a lansat scriptul)
TARGET_USER=""; TARGET_UID=""; TARGET_GID=""; TARGET_HOME=""

# Sistem
ARCH=""; KERNEL=""; OS_ID=""; OS_ID_LIKE=""; OS_VERSION_ID=""; OS_CODENAME=""
OS_PRETTY=""; DEBIAN_VERSION_FULL=""; IS_TRIXIE=0; DPKG_ARCH=""; PAGE_SIZE=""
PI_MODEL="necunoscut"; IS_PI5=0; CPU_CORES=0; CPU_MODEL=""; RAM_MB=0; SWAP_MB=0
GPU_DRIVER="necunoscut"; FREE_DISK_GB=0

# Mixxx / build
LATEST_TAG=""; INSTALLED_VERSION=""; INSTALLED_BIN=""; NEED_BUILD=1
BUILD_JOBS=1; CMAKE_GENERATOR="Unix Makefiles"; CMAKE_VERSION=""; QT_VERSION=""
TEMP_SWAP_ACTIVE=0; BUILD_RESULT="nu a rulat"; MIXXX_STARTED=0
WAYLAND_SESSION=0; XWAYLAND_LAUNCHER=0

# Audio / USB
AUDIO_BACKEND="nedetectat"; AUDIO_ALSA="-"; AUDIO_JACK="-"; AUDIO_PIPEWIRE="-"; AUDIO_PULSE="-"
USB_AUDIO_LIST=""; USB_MIDI_LIST=""; USB_ACCESS="-"

# -----------------------------------------------------------------------------
# Afișare și logging
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'
    C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_BOLD=$'\e[1m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

log_raw() {
    [[ -n "${LOG_FILE}" && -w "${LOG_FILE}" ]] || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}
info()  { printf '%s[INFO]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*"; log_raw "[INFO] $*"; }
ok()    { printf '%s[OK]%s %s\n'      "${C_GREEN}"  "${C_RESET}" "$*"; log_raw "[OK] $*"; }
warn()  { printf '%s[WARNING]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; log_raw "[WARNING] $*"; WARNINGS+=("$*"); }
error() { printf '%s[ERROR]%s %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; log_raw "[ERROR] $*"; }
hint()  { printf '        %s-> Recomandare:%s %s\n' "${C_BOLD}" "${C_RESET}" "$*" >&2; log_raw "[HINT] $*"; }

# Scrie în log un bloc de text (ieșirea unei comenzi de diagnostic)
log_block() {
    local title="$1"; shift
    log_raw "----- ${title} -----"
    if [[ -n "${LOG_FILE}" && -w "${LOG_FILE}" ]]; then printf '%s\n' "$@" >>"${LOG_FILE}"; fi
    return 0
}

stage() {
    CURRENT_STAGE="$*"
    printf '\n%s========== %s ==========%s\n' "${C_BOLD}" "$*" "${C_RESET}"
    log_raw "========== $* =========="
}

record() {
    local msg="$*"
    (( OPT_DRY_RUN )) && msg="[simulat] ${msg}"
    SUMMARY_ACTIONS+=("${msg}")
    log_raw "[ACTION] ${msg}"
}

# Blocul standard de eșec
print_failure_block() {
    error "Installation failed"
    error "Stage: ${CURRENT_STAGE}"
    error "Command: ${FAILED_COMMAND:-?}"
    error "Exit code: ${FAILED_EXIT_CODE}"
    error "Log: ${LOG_FILE:-?}"
}

# Oprire controlată: mesaj + bloc de eșec + recomandare
die() {
    local msg="$1" suggestion="${2:-}" cmd="${3:-${LAST_RUN:-}}"
    FAILED_MESSAGE="${msg}"
    FAILED_COMMAND="${cmd:-${msg}}"
    (( FAILED_EXIT_CODE == 0 )) && FAILED_EXIT_CODE=1
    INSTALL_STATUS="FAILED"
    error "${msg}"
    print_failure_block
    [[ -n "${suggestion}" ]] && hint "${suggestion}"
    exit "${FAILED_EXIT_CODE}"
}

# -----------------------------------------------------------------------------
# Execuție comenzi
# -----------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Rulează ca utilizatorul real (nu root) atunci când scriptul rulează cu sudo
as_user() {
    if (( EUID == 0 )) && [[ "${TARGET_USER}" != "root" ]]; then
        if need_cmd runuser; then
            runuser -u "${TARGET_USER}" -- "$@"
        else
            sudo -u "${TARGET_USER}" -H -- "$@"
        fi
    else
        "$@"
    fi
}

# Ca as_user, cu variabilele sesiunii (necesare pentru systemctl --user, pactl)
as_user_session() {
    local rt="/run/user/${TARGET_UID}"
    as_user env XDG_RUNTIME_DIR="${rt}" DBUS_SESSION_BUS_ADDRESS="unix:path=${rt}/bus" "$@"
}

# Execută și loghează; reține comanda pentru raportul de eroare
_exec_logged() {
    LAST_RUN="$*"
    log_raw "[RUN] $*"
    if (( OPT_VERBOSE )); then
        "$@" 2>&1 | tee -a "${LOG_FILE}"
    else
        "$@" >>"${LOG_FILE}" 2>&1
    fi
}

_print_dry() {
    printf '%s[DRY-RUN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"
    log_raw "[DRY-RUN] $*"
}

# Comenzi care MODIFICĂ sistemul. În modurile read-only doar se afișează.
run_root() {
    if (( READ_ONLY )); then _print_dry "${SUDO[*]:+${SUDO[*]} }$(printf '%q ' "$@")"; return 0; fi
    _exec_logged "${SUDO[@]}" "$@"
}
run_user() {
    if (( READ_ONLY )); then _print_dry "(ca ${TARGET_USER}) $(printf '%q ' "$@")"; return 0; fi
    _exec_logged as_user "$@"
}

# Întrebare da/nu; $2 = răspuns implicit (y/n). În dry-run/--yes: 'y' fără interacțiune.
ask_yes_no() {
    local question="$1" default="${2:-n}" reply prompt
    if (( OPT_DRY_RUN )); then info "${question} -> (dry-run: se presupune 'y')"; return 0; fi
    if (( OPT_YES )); then info "${question} -> (--yes: 'y')"; return 0; fi
    if ! { : </dev/tty; } 2>/dev/null; then
        info "${question} -> (fără terminal interactiv: implicit '${default}')"
        [[ "${default}" == "y" ]]; return
    fi
    [[ "${default}" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    read -r -p "${C_BOLD}[?]${C_RESET} ${question} ${prompt} " reply </dev/tty || reply=""
    log_raw "[QUESTION] ${question} -> '${reply}'"
    reply="${reply:-${default}}"
    [[ "${reply,,}" =~ ^(y|yes|d|da)$ ]]
}

# Ștergere sigură: doar sub un părinte permis, niciodată căi de sistem sau home
safe_rm_dir() {
    local target="$1" allowed_parent="$2" real_target real_parent
    [[ -n "${target}" && -n "${allowed_parent}" ]] || die "safe_rm_dir: argumente goale"
    [[ -e "${target}" ]] || return 0
    real_target="$(readlink -f -- "${target}")"
    real_parent="$(readlink -f -- "${allowed_parent}")"
    case "${real_target}" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/opt|/proc|/root|/sbin|/sys|/usr|/usr/local|/var|"${TARGET_HOME}"|"${SRC_DIR}"|"${BUILD_DIR}")
            die "Refuz să șterg calea protejată: ${real_target}" ;;
    esac
    [[ "${real_target}" == "${real_parent}/"* ]] \
        || die "Refuz să șterg ${real_target}: nu se află în ${real_parent}"
    run_user rm -rf -- "${real_target}"
}

version_ge() { [[ -n "$1" ]] && dpkg --compare-versions "$1" ge "$2" 2>/dev/null; }

# -----------------------------------------------------------------------------
# Tratare erori și curățenie
# -----------------------------------------------------------------------------
on_error() {
    local rc=$? cmd="${BASH_COMMAND}" line="${BASH_LINENO[0]:-?}"
    [[ "${INSTALL_STATUS}" == "FAILED" ]] && return 0
    FAILED_COMMAND="${cmd}"; FAILED_EXIT_CODE="${rc}"; INSTALL_STATUS="FAILED"
    FAILED_MESSAGE="Eroare neașteptată la linia ${line}"
    print_failure_block
    if [[ -n "${LOG_FILE}" && -r "${LOG_FILE}" ]]; then
        printf '%s--- Ultimele 60 de linii din log ---%s\n' "${C_BOLD}" "${C_RESET}" >&2
        tail -n 60 "${LOG_FILE}" >&2 || true
    fi
    hint "Directorul ${BUILD_DIR} și sursele au fost păstrate pentru depanare."
}

cleanup() {
    local rc=$?
    set +e
    remove_temp_swap
    if (( rc != 0 )) && [[ "${INSTALL_STATUS}" != "FAILED" && "${INSTALL_STATUS}" != STOPPED* ]]; then
        INSTALL_STATUS="FAILED"; FAILED_EXIT_CODE="${rc}"
    fi
    if (( ! REPORT_DONE && ! EARLY_EXIT )); then final_report; fi
    exit "${rc}"
}

on_interrupt() {
    FAILED_COMMAND="Întrerupt de utilizator (Ctrl+C)"; FAILED_EXIT_CODE=130
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
Instalează ultima versiune stabilă Mixxx ${MIXXX_SERIES}.x (compilată din sursele oficiale)
pe Raspberry Pi 5 cu Debian 13 Trixie ARM64.

Utilizare:
  sudo ./${SCRIPT_NAME} [opțiuni]     (recomandat)
  ./${SCRIPT_NAME} [opțiuni]          (cere parola sudo doar când e necesar)

Opțiuni:
  --help                   Afișează acest ajutor.
  --version                Afișează versiunea scriptului.
  --system-info            Doar detectează și afișează informațiile sistemului.
  --check-dependencies     Doar verifică dependențele (nume, versiuni, instalabilitate).
  --dry-run                Arată ce ar face, fără a modifica apt, fișiere, swap sau audio.
  --no-upgrade             Rulează 'apt update', dar nu 'apt full-upgrade'.
  --skip-dependencies      Nu verifică/instalează dependențele.
  --skip-build             Nu configurează/compilează; instalează un build existent, dacă există.
  --force                  Recompilează/reinstalează chiar dacă versiunea e deja instalată.
  --jobs N                 Joburi de compilare (implicit: valoare sigură pentru Pi 5, max 4).
  --configure-swap         Permite crearea (cu confirmare) a unui swap TEMPORAR pentru build.
  --no-external-downloads  Dezactivează Engine Prime export și KeyFinder, pe care CMake-ul
                           Mixxx le descarcă altfel (surse oficiale, verificate SHA256).
  --verbose                Afișează ieșirea completă a comenzilor.
  -y, --yes                Răspunde 'da' la întrebări (NU pornește Mixxx automat).

Locații:
  Surse: ${SRC_DIR}    Build: ${BUILD_DIR}    Instalare: ${INSTALL_PREFIX}
  Log:   /var/log/mixxx-install.log (sau \$HOME/mixxx-install.log)

Scriptul nu modifică repository-urile apt, configurația audio, ~/.mixxx,
biblioteca muzicală, /boot sau firmware-ul și nu rulează Mixxx ca root.
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --help|-h)            usage; EARLY_EXIT=1; exit 0 ;;
            --version|-V)         echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; EARLY_EXIT=1; exit 0 ;;
            --system-info)        OPT_SYSTEM_INFO=1 ;;
            --check-dependencies) OPT_CHECK_DEPS=1 ;;
            --dry-run)            OPT_DRY_RUN=1 ;;
            --no-upgrade)         OPT_NO_UPGRADE=1 ;;
            --skip-dependencies)  OPT_SKIP_DEPS=1 ;;
            --skip-build)         OPT_SKIP_BUILD=1 ;;
            --force)              OPT_FORCE=1 ;;
            --configure-swap)     OPT_CONFIGURE_SWAP=1 ;;
            --no-external-downloads) OPT_NO_EXTERNAL=1 ;;
            --verbose|-v)         OPT_VERBOSE=1 ;;
            --yes|-y)             OPT_YES=1 ;;
            --jobs|-j)
                if [[ $# -lt 2 ]]; then echo "--jobs necesită un număr" >&2; EARLY_EXIT=1; exit 2; fi
                OPT_JOBS="$2"; shift ;;
            --jobs=*)             OPT_JOBS="${1#*=}" ;;
            *)
                echo "Opțiune necunoscută: $1 (vezi --help)" >&2
                EARLY_EXIT=1; exit 2 ;;
        esac
        shift
    done
    if [[ -n "${OPT_JOBS}" ]] && ! [[ "${OPT_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "--jobs trebuie să fie un număr întreg >= 1 (primit: '${OPT_JOBS}')" >&2
        EARLY_EXIT=1; exit 2
    fi
    if (( OPT_DRY_RUN || OPT_SYSTEM_INFO || OPT_CHECK_DEPS )); then READ_ONLY=1; fi
    return 0
}

# -----------------------------------------------------------------------------
# Utilizator real, privilegii, log
# -----------------------------------------------------------------------------
# Ordine: utilizatorul curent (dacă nu e root) -> SUDO_USER -> logname -> root
detect_real_user() {
    local u=""
    if (( EUID != 0 )); then
        u="$(id -un)"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        u="${SUDO_USER}"
    else
        u="$(logname 2>/dev/null || true)"
        [[ -n "${u}" ]] || u="root"
    fi
    getent passwd "${u}" >/dev/null 2>&1 || u="$(id -un)"
    TARGET_USER="${u}"
    TARGET_UID="$(id -u "${u}")"
    TARGET_GID="$(id -g "${u}")"
    TARGET_HOME="$(getent passwd "${u}" | cut -d: -f6 || true)"
    [[ -n "${TARGET_HOME}" ]] || TARGET_HOME="${HOME}"
}

setup_privileges() {
    detect_real_user
    if (( EUID == 0 )); then
        SUDO=()                          # deja root: fără sudo
    elif need_cmd sudo; then
        SUDO=(sudo)
        if (( ! READ_ONLY )); then
            echo "[INFO] Unele etape (apt, instalare) necesită sudo."
            sudo -v || { echo "[ERROR] Autentificarea sudo a eșuat." >&2; EARLY_EXIT=1; exit 1; }
        fi
    elif (( ! READ_ONLY )); then
        echo "[ERROR] Scriptul nu rulează ca root și 'sudo' nu este instalat." >&2
        echo "        -> Recomandare: su -c './${SCRIPT_NAME}'   sau instalează sudo." >&2
        EARLY_EXIT=1; exit 1
    fi
}

setup_logging() {
    if (( READ_ONLY )); then
        # Modurile read-only nu scriu în /var/log; singurul fișier scris: log temporar în /tmp
        LOG_FILE="${TMPDIR:-/tmp}/mixxx-install-readonly-$(id -un).log"
        : >"${LOG_FILE}" 2>/dev/null || LOG_FILE="/dev/null"
    else
        LOG_FILE="/var/log/mixxx-install.log"
        if ! { "${SUDO[@]}" touch "${LOG_FILE}" && "${SUDO[@]}" chown "$(id -u):$(id -g)" "${LOG_FILE}" \
               && "${SUDO[@]}" chmod 644 "${LOG_FILE}"; } 2>/dev/null; then
            LOG_FILE="${TARGET_HOME}/mixxx-install.log"
            : >>"${LOG_FILE}"
            if (( EUID == 0 )); then chown "${TARGET_UID}:${TARGET_GID}" "${LOG_FILE}" 2>/dev/null || true; fi
            echo "[WARNING] Nu pot scrie în /var/log; folosesc ${LOG_FILE}" >&2
        fi
    fi
    {
        echo
        echo "#####################################################################"
        echo "# ${SCRIPT_NAME} v${SCRIPT_VERSION} - $(date '+%F %T')"
        echo "# user=${TARGET_USER} euid=${EUID} dry-run=${OPT_DRY_RUN} system-info=${OPT_SYSTEM_INFO} check-deps=${OPT_CHECK_DEPS}"
        echo "# no-upgrade=${OPT_NO_UPGRADE} skip-deps=${OPT_SKIP_DEPS} skip-build=${OPT_SKIP_BUILD} force=${OPT_FORCE}"
        echo "# jobs=${OPT_JOBS:-auto} configure-swap=${OPT_CONFIGURE_SWAP} no-external=${OPT_NO_EXTERNAL}"
        echo "#####################################################################"
    } >>"${LOG_FILE}" 2>/dev/null || true
    info "Log: ${LOG_FILE}"
    info "Utilizator real: ${TARGET_USER} (home: ${TARGET_HOME})"
    if (( OPT_DRY_RUN )); then warn "Mod DRY-RUN: apt, fișierele, swap-ul și audio NU vor fi modificate."; fi
    if [[ "${TARGET_USER}" == "root" ]] && (( ! READ_ONLY )); then
        warn "Nu am găsit un utilizator non-root (rulezi direct ca root). Build-ul va rula ca root, iar Mixxx NU va fi pornit."
    fi
    return 0
}

# =============================================================================
# ETAPA 1 — Detectarea sistemului
# =============================================================================
# Citește o cheie din /etc/os-release fără a executa fișierul
os_release_get() {
    awk -F= -v k="$1" '$1==k { v=substr($0, index($0,"=")+1); gsub(/^"|"$/, "", v); print v; exit }' /etc/os-release 2>/dev/null || true
}

detect_system() {
    stage "ETAPA 1/14 — Detectarea sistemului"
    local c
    for c in uname nproc awk grep df free dpkg getconf; do
        need_cmd "${c}" || die "Comanda necesară '${c}' lipsește." "sudo apt install coreutils procps gawk grep dpkg libc-bin" "command -v ${c}"
    done

    # --- Arhitectură (uname -m) ---------------------------------------------
    ARCH="$(uname -m)"
    KERNEL="$(uname -r)"
    if [[ "${ARCH}" != "aarch64" ]]; then
        die "Arhitectură nesuportată: ${ARCH}. Scriptul necesită ARM64 (aarch64)." \
            "Instalează Debian 13 arm64 (sau alt sistem 64-bit)." "uname -m"
    fi
    DPKG_ARCH="$(dpkg --print-architecture)"
    if [[ "${DPKG_ARCH}" != "arm64" || "$(getconf LONG_BIT)" != "64" ]]; then
        die "Kernel aarch64, dar userland ${DPKG_ARCH}/$(getconf LONG_BIT)-bit: este necesar un sistem ARM64 complet." \
            "Reinstalează Debian 13 arm64." "dpkg --print-architecture"
    fi
    ok "ARM64 architecture detected (uname -m: ${ARCH}, dpkg: ${DPKG_ARCH})"

    # --- Sistem de operare (cat /etc/os-release; fără a presupune Raspberry Pi OS)
    [[ -r /etc/os-release ]] || die "/etc/os-release lipsește; nu pot identifica sistemul." "" "cat /etc/os-release"
    log_block "cat /etc/os-release" "$(cat /etc/os-release)"
    OS_ID="$(os_release_get ID)"
    OS_ID_LIKE="$(os_release_get ID_LIKE)"
    OS_VERSION_ID="$(os_release_get VERSION_ID)"
    OS_CODENAME="$(os_release_get VERSION_CODENAME)"
    OS_PRETTY="$(os_release_get PRETTY_NAME)"
    DEBIAN_VERSION_FULL="$(os_release_get DEBIAN_VERSION_FULL)"
    [[ -n "${DEBIAN_VERSION_FULL}" ]] || DEBIAN_VERSION_FULL="$(cat /etc/debian_version 2>/dev/null || echo '?')"

    if [[ "${OS_ID}" == "debian" && ( "${OS_VERSION_ID}" == "13" || "${OS_CODENAME}" == "trixie" ) ]]; then
        IS_TRIXIE=1
        ok "Debian 13 Trixie ARM64 detected (${OS_PRETTY}, ${DEBIAN_VERSION_FULL})"
    elif [[ "${OS_CODENAME}" == "trixie" && ( "${OS_ID_LIKE}" == *debian* || "${OS_ID}" == "raspbian" ) ]]; then
        IS_TRIXIE=1
        ok "Distribuție bazată pe Debian 13 Trixie: ${OS_PRETTY} (ID=${OS_ID})"
    elif [[ "${OS_CODENAME}" == "bookworm" ]]; then
        warn "Debian 12 Bookworm detectat. Scriptul este optimizat pentru Debian 13 Trixie; pachetele vor fi detectate automat (Qt 6.4)."
        ask_yes_no "Continui pe Bookworm?" "y" || die "Anulat de utilizator." "" "confirmare Bookworm"
    elif [[ "${OS_CODENAME}" =~ ^(stretch|buster|bullseye)$ ]]; then
        die "${OS_PRETTY} este prea vechi: Mixxx ${MIXXX_SERIES} necesită Qt >= ${MIN_QT} și CMake >= ${MIN_CMAKE}." \
            "Folosește Debian 13 Trixie." "cat /etc/os-release"
    elif [[ "${OS_ID}" == "debian" || "${OS_ID_LIKE}" == *debian* ]]; then
        warn "Sistem Debian netestat: ${OS_PRETTY:-?} (${OS_CODENAME:-fără codename}). Verificarea dependențelor va decide."
    else
        die "Sistem ne-Debian (${OS_PRETTY:-?}); scriptul folosește apt/dpkg." "" "cat /etc/os-release"
    fi
    ok "Kernel (uname -r): ${KERNEL}"
    PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo '?')"
    if [[ "${PAGE_SIZE}" == "16384" ]]; then
        ok "Page size: 16 KB (kernel Raspberry Pi 2712; fără probleme cunoscute pentru Mixxx)"
    else
        ok "Page size: ${PAGE_SIZE} bytes"
    fi

    # --- Raspberry Pi 5 (device-tree; metode standard, fără fișiere Raspberry Pi OS)
    local compat=""
    if [[ -r /proc/device-tree/model ]]; then
        PI_MODEL="$(tr -d '\0' </proc/device-tree/model)"
    elif [[ -r /sys/firmware/devicetree/base/model ]]; then
        PI_MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
    else
        PI_MODEL="$(awk -F': ' '/^Model/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    fi
    if [[ -r /proc/device-tree/compatible ]]; then compat="$(tr '\0' ' ' </proc/device-tree/compatible)"; fi
    PI_MODEL="${PI_MODEL:-necunoscut}"
    if [[ "${PI_MODEL}" == *"Raspberry Pi 5"* || "${compat}" == *"raspberrypi,5-model-b"* || "${compat}" == *"brcm,bcm2712"* ]]; then
        IS_PI5=1
        ok "Raspberry Pi 5 detectat: ${PI_MODEL}"
    else
        warn "Nu este Raspberry Pi 5 (model: ${PI_MODEL})."
        # Modurile doar-citire (--system-info / --check-dependencies) continuă fără întrebare
        if (( ! OPT_SYSTEM_INFO && ! OPT_CHECK_DEPS )); then
            ask_yes_no "Vrei să continui oricum?" "n" || die "Anulat de utilizator (hardware diferit de Raspberry Pi 5)." "" "detectare model"
        fi
    fi

    # --- CPU / RAM / swap / disc --------------------------------------------
    CPU_CORES="$(nproc)"
    if need_cmd lscpu; then
        CPU_MODEL="$(LC_ALL=C lscpu | awk -F': +' '/^Model name/ {print $2; exit}' || true)"
    fi
    if [[ -z "${CPU_MODEL}" ]] && grep -qi 'CPU part.*0xd0b' /proc/cpuinfo 2>/dev/null; then
        CPU_MODEL="Cortex-A76"        # MIDR part 0xd0b = ARM Cortex-A76 (BCM2712)
    fi
    RAM_MB="$(awk '/^MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    SWAP_MB="$(awk '/^SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    FREE_DISK_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
    ok "CPU: ${CPU_CORES} cores${CPU_MODEL:+ (${CPU_MODEL})}"
    ok "RAM: aproximativ $(( (RAM_MB + 512) / 1024 )) GB (${RAM_MB} MB), swap: ${SWAP_MB} MB"
    ok "Spațiu liber pe /: ${FREE_DISK_GB} GB"

    detect_gpu
    detect_installed_mixxx
    if [[ -n "${INSTALLED_BIN}" ]]; then
        ok "Mixxx deja instalat: ${INSTALLED_VERSION} (${INSTALLED_BIN})"
    else
        info "Mixxx nu este instalat."
    fi
    if dpkg -s mixxx >/dev/null 2>&1; then
        warn "Pachetul Debian 'mixxx' ($(dpkg-query -W -f='${Version}' mixxx)) este instalat; NU îl șterg. ${INSTALL_PREFIX}/bin are prioritate în PATH."
    fi
    if [[ -d "${TARGET_HOME}/.mixxx" ]]; then ok "Configurația ${TARGET_HOME}/.mixxx există și rămâne neatinsă."; fi

    log_block "Sistem detectat" \
        "arch=${ARCH} dpkg=${DPKG_ARCH} kernel=${KERNEL} os=${OS_PRETTY} debian=${DEBIAN_VERSION_FULL}" \
        "model=${PI_MODEL} cpu=${CPU_CORES}x ${CPU_MODEL} ram=${RAM_MB}MB swap=${SWAP_MB}MB page=${PAGE_SIZE} gpu=${GPU_DRIVER}"
    log_block "free -h" "$(free -h 2>&1)"
    log_block "swapon --show" "$(swapon --show 2>&1 || true)"
    return 0
}

# GPU: formele de undă Mixxx folosesc OpenGL; pe Pi 5 driverul accelerat e "v3d"
detect_gpu() {
    local d drv drivers=""
    for d in /sys/class/drm/card[0-9]*; do
        [[ -e "${d}/device/driver" ]] || continue
        drv="$(basename "$(readlink -f "${d}/device/driver")")"
        [[ " ${drivers} " == *" ${drv} "* ]] || drivers+="${drv} "
    done
    drivers="${drivers% }"
    GPU_DRIVER="${drivers:-niciunul}"
    if [[ "${drivers}" == *v3d* ]]; then
        ok "GPU: ${GPU_DRIVER} (OpenGL accelerat prin Mesa V3D)"
    elif (( IS_PI5 )); then
        warn "GPU: driverul 'v3d' nu este încărcat (drivere: ${GPU_DRIVER}). Mixxx va folosi randare software (llvmpipe): alege forme de undă simple."
    else
        info "GPU: ${GPU_DRIVER}"
    fi
}

# Versiunea instalată, verificată ca utilizator normal (nu root)
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

# "mixxx --version" fără GUI (QT_QPA_PLATFORM=offscreen), ca utilizator normal
mixxx_version_of() {
    local out
    out="$(as_user env QT_QPA_PLATFORM=offscreen timeout 30 "$1" --version 2>/dev/null || true)"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.+~-]+)?' <<<"${out}" | head -n1 || true
}

# =============================================================================
# ETAPA 2 — Repository-urile APT (doar citire: nu se modifică nimic)
# =============================================================================
check_repositories() {
    stage "ETAPA 2/14 — Repository-uri APT (doar verificare)"
    { need_cmd apt-get && need_cmd apt-cache; } || die "apt nu este disponibil." "" "command -v apt-get"

    local policy sources line foreign=0
    policy="$(LC_ALL=C apt-cache policy 2>&1 || true)"
    log_block "apt-cache policy" "${policy}"
    sources="$(grep -Rhv '^[[:space:]]*#' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null | grep -v '^[[:space:]]*$' || true)"
    log_block "Surse APT (fără comentarii)" "${sources}"

    # Rezumat: origine / suită / codename / componentă (din liniile "release" ale apt-cache policy)
    info "Repository-uri active (apt-cache policy):"
    grep -oE 'release .*o=.*' <<<"${policy}" \
        | sed -E 's/^release .*o=([^,]*),a=([^,]*),n=([^,]*).*c=([^,]*).*/\1 | suite=\2 | codename=\3 | \4/' \
        | sort -u | sed 's/^/    /' || true

    # Surse care nu aparțin lui Trixie (bookworm, Ubuntu, PPA): doar avertisment
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        if [[ "${line}" =~ (bookworm|bullseye|buster|ppa\.launchpad|ubuntu) ]]; then
            warn "Sursă APT străină de Trixie: ${line}"
            foreign=1
        fi
    done < <(grep -E '^[[:space:]]*(deb|URIs:|Suites:)' <<<"${sources}" || true)
    if grep -q 'archive.raspberrypi' <<<"${sources}"; then
        info "Repository Raspberry Pi prezent (kernel/firmware). Dependențele Mixxx sunt luate conform priorităților apt existente."
    fi
    if (( IS_TRIXIE )) && ! grep -q 'n=trixie' <<<"${policy}"; then
        warn "Nu văd repository-ul Debian 'trixie' în apt-cache policy (poate e necesar 'apt update')."
    fi
    if (( foreign )); then
        hint "Nu modific sursele automat. Sursele mixte (ex. bookworm + trixie) pot cauza conflicte de dependențe."
    fi
    ok "Configurația repository-urilor NU a fost modificată."
}

# =============================================================================
# ETAPA 3 — Actualizarea sistemului
# =============================================================================
update_system() {
    stage "ETAPA 3/14 — Actualizarea sistemului"
    export DEBIAN_FRONTEND=noninteractive
    info "apt update..."
    run_root apt-get update \
        || die "'apt update' a eșuat (Debian ${DEBIAN_VERSION_FULL})." "Verifică rețeaua și sursele APT (etapa 2), apoi: sudo apt update"
    record "apt update"

    local upgradable
    upgradable="$(apt list --upgradable 2>/dev/null | grep -c -- '/' || true)"
    if (( upgradable == 0 )); then
        ok "Sistemul este actualizat."
    elif (( OPT_NO_UPGRADE )); then
        warn "${upgradable} pachete pot fi actualizate (--no-upgrade activ)."
    else
        info "${upgradable} pachete de actualizat: apt full-upgrade..."
        run_root apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade \
            || die "'apt full-upgrade' a eșuat (Debian ${DEBIAN_VERSION_FULL})." \
                   "Rulează 'sudo dpkg --configure -a' și 'sudo apt -f install', apoi repornește scriptul."
        ok "Sistem actualizat (${upgradable} pachete)."
        record "apt full-upgrade (${upgradable} pachete)"
    fi
    check_reboot_required
}

check_reboot_required() {
    local reason=""
    if [[ -f /var/run/reboot-required ]]; then
        reason="/var/run/reboot-required există"
    elif [[ ! -d "/lib/modules/$(uname -r)" ]]; then
        reason="modulele kernelului rulat ($(uname -r)) nu mai sunt instalate (kernel nou)"
    fi
    [[ -n "${reason}" ]] || { ok "Nu este necesar reboot."; return 0; }
    warn "Reboot recomandat: ${reason}. Scriptul NU repornește automat."
    if ask_yes_no "Continui fără reboot? (N = opresc; repornești și rulezi din nou)" "y"; then
        record "Reboot recomandat, amânat"
    else
        INSTALL_STATUS="STOPPED (reboot necesar)"
        info "Rulează 'sudo reboot', apoi scriptul din nou (reia de unde a rămas)."
        exit 0
    fi
}

# =============================================================================
# ETAPA 4 — Dependențe (Debian 13 Trixie)
# =============================================================================
# Format: nivel|alternative (în ordinea preferinței)|versiune minimă|descriere
#   critical -> fără el build-ul nu e posibil: oprire
#   optional -> funcționalitate redusă: warning
# Lista e derivată din CMakeLists.txt-ul Mixxx 2.5.x și din Build-Depends ale
# pachetului Debian mixxx 2.5. Numele REAL din Debian 13 este primul; numele
# vechi rămân doar ca rezervă. Numele virtuale (ex. libqt6svg6-dev, furnizat de
# qt6-svg-dev pe Trixie) sunt rezolvate automat prin "Reverse Provides".
dependency_table() {
    cat <<'EOF'
critical|build-essential||Compilator C/C++ (GCC 14 pe Trixie)
critical|git||Git
critical|cmake|3.21|CMake
critical|pkgconf pkg-config||pkg-config
critical|file||Verificare arhitectură ELF
optional|ninja-build||Ninja (build mai rapid)
optional|ccache||Cache de compilare (rebuild rapid)
optional|mold lld||Linker rapid, RAM redus la link
critical|qt6-base-dev|6.2|Qt6 Core/Gui/Widgets/Sql/DBus/OpenGL
critical|qt6-base-private-dev|6.2|Qt6 private headers (GuiPrivate)
critical|qt6-svg-dev libqt6svg6-dev|6.2|Qt6 SVG / SvgWidgets
critical|qt6-declarative-dev|6.2|Qt6 QML / Quick
critical|qt6-declarative-private-dev|6.2|Qt6 QuickShapesPrivate
critical|qt6-shadertools-dev libqt6shadertools6-dev||Qt6 ShaderTools
critical|qt6-5compat-dev libqt6core5compat6-dev||Qt6 Core5Compat
critical|libqt6sql6-sqlite||Driver Qt6 SQLite (biblioteca Mixxx)
critical|qt6-qpa-plugins||Plugin-uri platformă Qt6 (xcb/wayland)
optional|qt6-multimedia-dev||Qt6 Multimedia
optional|qt6-tools-dev||Qt6 Tools
optional|qt6-svg-plugins||Plugin imagini SVG
optional|qt6-wayland||Qt6 Wayland
optional|qt6-translations-l10n||Traduceri Qt6
critical|qml6-module-qtquick-controls||QML Controls
critical|qml6-module-qtquick-layouts||QML Layouts
critical|qml6-module-qtquick-shapes||QML Shapes
critical|qml6-module-qtquick-templates||QML Templates
critical|qml6-module-qtquick-window||QML Window
critical|qml6-module-qt-labs-qmlmodels||QML Labs QmlModels
critical|qml6-module-qt5compat-graphicaleffects||QML GraphicalEffects
optional|qml6-module-qtquick-nativestyle||QML NativeStyle
optional|qml6-module-qtqml-workerscript||QML WorkerScript (Qt < 6.8)
critical|qtkeychain-qt6-dev||QtKeychain
critical|libgl-dev libgl1-mesa-dev||OpenGL
critical|libglu1-mesa-dev||GLU
critical|libx11-dev||X11
critical|libasound2-dev||ALSA
critical|libjack-jackd2-dev libjack-dev||JACK
critical|portaudio19-dev||PortAudio
critical|libportmidi-dev||PortMidi (MIDI)
critical|libsndfile1-dev libsndfile-dev||libsndfile
critical|libogg-dev||Ogg
critical|libvorbis-dev||Vorbis
critical|libflac-dev||FLAC
critical|libmp3lame-dev||LAME (MP3)
critical|libopus-dev||Opus
critical|libopusfile-dev||Opusfile
critical|libchromaprint-dev||Chromaprint
critical|libfftw3-dev||FFTW3
critical|libebur128-dev||libebur128
critical|libhidapi-dev|0.11.2|HIDAPI (controllere HID)
critical|libusb-1.0-0-dev||libusb (controllere USB Bulk)
critical|libudev-dev||udev
critical|libprotobuf-dev||Protocol Buffers
critical|protobuf-compiler||protoc
critical|libavcodec-dev||FFmpeg libavcodec
critical|libavformat-dev||FFmpeg libavformat
critical|libavutil-dev||FFmpeg libavutil
critical|libswresample-dev||FFmpeg libswresample
critical|libtag-dev libtag1-dev|1.11|TagLib (2.x pe Trixie)
critical|librubberband-dev||Rubber Band
critical|libsoundtouch-dev|2.1.2|SoundTouch
critical|libupower-glib-dev||UPower
critical|libsqlite3-dev||SQLite3
critical|zlib1g-dev||zlib
critical|libssl-dev||OpenSSL
optional|libmad0-dev||MAD (decoder MP3 alternativ)
optional|libid3tag0-dev||ID3 tags
optional|libfaad-dev||AAC (FAAD)
optional|libmodplug-dev||Tracker modules
optional|libwavpack-dev||WavPack
optional|liblilv-dev||LV2 host (lilv)
optional|lv2-dev||LV2 headers
optional|libshout-idjc-dev||Live Broadcasting (altfel copie internă)
optional|libmsgsl-dev||Microsoft GSL
optional|fonts-open-sans||Font Open Sans
optional|desktop-file-utils||Validare .desktop
optional|usbutils||lsusb
optional|alsa-utils||aplay / arecord
EOF
}

# Pachete ale căror versiuni sunt raportate explicit
readonly -a QT_REPORT_PKGS=(qt6-base-dev qt6-tools-dev qt6-declarative-dev qt6-multimedia-dev)
readonly -a LIB_REPORT=(
    "ALSA|libasound2-dev" "JACK|libjack-jackd2-dev" "PipeWire|pipewire" "PortAudio|portaudio19-dev"
    "FFmpeg|libavcodec-dev" "libsndfile|libsndfile1-dev" "FLAC|libflac-dev" "Vorbis|libvorbis-dev"
    "Opus|libopus-dev" "LAME|libmp3lame-dev" "Chromaprint|libchromaprint-dev" "FFTW|libfftw3-dev"
    "libebur128|libebur128-dev" "HIDAPI|libhidapi-dev" "libusb|libusb-1.0-0-dev" "TagLib|libtag-dev"
    "Rubber Band|librubberband-dev" "protobuf|libprotobuf-dev" "CMake|cmake" "GCC/G++|g++"
)

# Încarcă versiunile candidat pentru o listă de pachete (un singur apel apt-cache policy)
load_apt_info() {
    local pkg="" line
    while IFS= read -r line; do
        if [[ "${line}" =~ ^([A-Za-z0-9.+-]+)(:[a-z0-9]+)?:$ ]]; then
            pkg="${BASH_REMATCH[1]}"
            APT_CANDIDATE["${pkg}"]="(none)"
        elif [[ -n "${pkg}" && "${line}" =~ ^[[:space:]]+Candidate:[[:space:]]+(.+)$ ]]; then
            APT_CANDIDATE["${pkg}"]="${BASH_REMATCH[1]}"
        fi
    done < <(LC_ALL=C apt-cache policy -- "$@" 2>/dev/null || true)
}

pkg_candidate() {
    local c="${APT_CANDIDATE[$1]:-}"
    [[ "${c}" == "(none)" ]] && c=""
    printf '%s' "${c}"
}

pkg_installed_ver() {
    local v
    v="$(dpkg-query -W -f='${Status}|${Version}' -- "$1" 2>/dev/null || true)"
    if [[ "${v}" == "install ok installed|"* ]]; then printf '%s' "${v#*|}"; fi
    return 0
}

# Furnizorii reali ai unui nume virtual/redenumit (apt-cache showpkg: Reverse Provides)
virtual_providers() {
    LC_ALL=C apt-cache showpkg -- "$1" 2>/dev/null \
        | awk '/^Reverse Provides:/ {f=1; next} f && NF {print $1}' | sort -u || true
}

# Alege pachetul pentru o intrare. Setează RESOLVED (gol dacă nimic nu e disponibil).
# Ordine: 1) alternativă deja instalată; 2) prima cu candidat real; 3) furnizorul unui nume virtual.
RESOLVED=""
resolve_dependency() {
    local alt prov
    RESOLVED=""
    for alt in "$@"; do
        if [[ -n "$(pkg_installed_ver "${alt}")" ]]; then RESOLVED="${alt}"; return 0; fi
    done
    for alt in "$@"; do
        if [[ -n "$(pkg_candidate "${alt}")" ]]; then RESOLVED="${alt}"; return 0; fi
    done
    for alt in "$@"; do
        for prov in $(virtual_providers "${alt}"); do
            [[ -n "${APT_CANDIDATE[${prov}]+x}" ]] || load_apt_info "${prov}"
            if [[ -n "$(pkg_candidate "${prov}")" || -n "$(pkg_installed_ver "${prov}")" ]]; then
                RESOLVED="${prov}"; return 0
            fi
        done
    done
    return 0
}

DEPS_TO_INSTALL=()
DEPS_CRITICAL_MISSING=()
DEPS_OPTIONAL_MISSING=()

analyze_dependencies() {
    local level alts minver desc chosen primary cand inst status ver
    local -a all_names
    DEPS_TO_INSTALL=(); DEPS_CRITICAL_MISSING=(); DEPS_OPTIONAL_MISSING=()

    mapfile -t all_names < <(dependency_table | cut -d'|' -f2 | tr ' ' '\n' | sort -u)
    load_apt_info "${all_names[@]}" pipewire pipewire-jack g++ "${QT_REPORT_PKGS[@]}"

    printf '    %-40s %-30s %s\n' "PACHET" "VERSIUNE" "STARE"
    while IFS='|' read -r level alts minver desc; do
        [[ -n "${level}" ]] || continue
        primary="${alts%% *}"
        # shellcheck disable=SC2086  # alternativele sunt separate intenționat prin spații
        resolve_dependency ${alts}
        chosen="${RESOLVED}"
        if [[ -z "${chosen}" ]]; then
            if [[ "${level}" == "critical" ]]; then
                DEPS_CRITICAL_MISSING+=("${primary}|${desc}|nu există în repository-urile configurate (încercat: ${alts}; apt-cache policy: fără candidat)")
                printf '    %-40s %-30s %s\n' "${primary}" "-" "LIPSĂ (critic)"
            else
                DEPS_OPTIONAL_MISSING+=("${primary}")
                printf '    %-40s %-30s %s\n' "${primary}" "-" "indisponibil (opțional)"
            fi
            log_raw "[DEP] ${level} '${desc}': ${alts} -> INDISPONIBIL"
            continue
        fi
        DEP_CHOSEN["${primary}"]="${chosen}"
        cand="$(pkg_candidate "${chosen}")"
        inst="$(pkg_installed_ver "${chosen}")"
        ver="${cand:-${inst}}"
        if [[ -n "${minver}" ]] && ! version_ge "${ver}" "${minver}"; then
            if [[ "${level}" == "critical" ]]; then
                DEPS_CRITICAL_MISSING+=("${chosen}|${desc}|versiunea ${ver} < minimul ${minver} cerut de Mixxx ${MIXXX_SERIES}")
            else
                DEPS_OPTIONAL_MISSING+=("${chosen}")
            fi
            status="VERSIUNE PREA VECHE (< ${minver})"
        elif [[ -n "${inst}" ]]; then
            status="instalat"
        else
            status="de instalat"
            [[ " ${DEPS_TO_INSTALL[*]} " == *" ${chosen} "* ]] || DEPS_TO_INSTALL+=("${chosen}")
        fi
        [[ "${chosen}" != "${primary}" ]] && status+="  [nume efectiv: ${chosen}]"
        printf '    %-40s %-30s %s\n' "${chosen}" "${ver}" "${status}"
        log_raw "[DEP] ${level} '${desc}': ${chosen} candidate=${cand:-none} installed=${inst:-none} min=${minver:-none}"
    done < <(dependency_table)
}

# Qt6 disponibil pe sistem și compatibilitatea cu Mixxx 2.5.x
report_qt6() {
    local p cand inst
    info "Qt6 (apt-cache policy):"
    for p in "${QT_REPORT_PKGS[@]}"; do
        cand="$(pkg_candidate "${p}")"; inst="$(pkg_installed_ver "${p}")"
        printf '    %-22s candidate: %-26s installed: %s\n' "${p}" "${cand:-(none)}" "${inst:-(none)}"
    done
    log_block "apt-cache policy (Qt6)" "$(LC_ALL=C apt-cache policy "${QT_REPORT_PKGS[@]}" 2>&1 || true)"
    QT_VERSION="$(pkg_candidate qt6-base-dev)"
    [[ -n "${QT_VERSION}" ]] || QT_VERSION="$(pkg_installed_ver qt6-base-dev)"
    QT_VERSION="$(grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"${QT_VERSION}" || true)"
    if [[ -z "${QT_VERSION}" ]]; then
        return 0                           # lipsa e raportată ca dependență critică
    elif ! version_ge "${QT_VERSION}" "${MIN_QT}"; then
        DEPS_CRITICAL_MISSING+=("qt6-base-dev|Qt6|Qt ${QT_VERSION} < ${MIN_QT} cerut de Mixxx ${MIXXX_SERIES}")
    elif version_ge "${QT_VERSION}" "6.10"; then
        ok "Qt ${QT_VERSION}: compatibil (de la Qt 6.10 Mixxx cere GuiPrivate, inclus în qt6-base-private-dev)."
    elif version_ge "${QT_VERSION}" "6.8"; then
        ok "Qt ${QT_VERSION}: compatibil cu Mixxx ${MIXXX_SERIES} (de la Qt 6.8 WorkerScript e în QmlMeta; tratat de CMake-ul Mixxx)."
    else
        ok "Qt ${QT_VERSION}: compatibil cu Mixxx ${MIXXX_SERIES} (>= ${MIN_QT})."
    fi
}

# Versiunile bibliotecilor audio / codec / USB și note de compatibilitate
report_libraries() {
    local entry label pkg ver inst note
    info "Biblioteci audio / codec / USB (Debian ${DEBIAN_VERSION_FULL}):"
    printf '    %-12s %-20s %-30s %s\n' "COMPONENTA" "PACHET" "VERSIUNE" "NOTA"
    for entry in "${LIB_REPORT[@]}"; do
        label="${entry%%|*}"; pkg="${entry#*|}"
        # numele efectiv ales (ex. libjack-dev dacă jackd1 e deja instalat)
        [[ -n "${DEP_CHOSEN[${pkg}]:-}" ]] && pkg="${DEP_CHOSEN[${pkg}]}"
        inst="$(pkg_installed_ver "${pkg}")"
        ver="${inst:-$(pkg_candidate "${pkg}")}"
        note=""
        case "${label}" in
            FFmpeg)   if version_ge "${ver}" "7:7"; then note="FFmpeg 7.x: compatibil (Debian compilează Mixxx 2.5 cu FFmpeg 7)"; fi ;;
            TagLib)   if version_ge "${ver}" "2"; then note="TagLib 2.x: compatibil"; fi ;;
            CMake)    if [[ -n "${ver}" ]]; then
                          if version_ge "${ver}" "${MIN_CMAKE}"; then note=">= ${MIN_CMAKE}: OK"; else note="PREA VECHI (< ${MIN_CMAKE})"; fi
                      fi ;;
            PipeWire) note="runtime (nu e necesar la compilare)" ;;
        esac
        [[ -n "${inst}" ]] && ver="${ver} (inst.)"
        printf '    %-12s %-20s %-30s %s\n' "${label}" "${pkg}" "${ver:-(indisponibil)}" "${note}"
    done
}

# Simulare apt (fără modificări, fără root): detectează conflictele înainte de instalare
simulate_install() {
    (( ${#DEPS_TO_INSTALL[@]} )) || return 0
    local out rc=0
    info "Simulez instalarea (apt-get -s install) pentru a detecta conflicte..."
    # Rulată ca utilizator normal și fără logul "planner" (/var/log/apt/eipp.log.xz),
    # astfel încât simularea să nu scrie absolut nimic pe disc
    out="$(as_user env LC_ALL=C apt-get -s -o Dir::Log::Planner=/dev/null install --no-install-recommends -- "${DEPS_TO_INSTALL[@]}" 2>&1)" || rc=$?
    log_block "apt-get -s install" "${out}"
    if (( rc != 0 )); then
        error "Simularea apt a eșuat pe ${OS_PRETTY} (${DEBIAN_VERSION_FULL}):"
        grep -E '^(E:|[[:space:]]+[A-Za-z0-9.+-]+ : (Depends|Conflicts|Breaks|PreDepends):|[[:space:]]+(Depends|Conflicts|Breaks):)' <<<"${out}" \
            | head -n 20 | sed 's/^/    /' >&2 || true
        FAILED_EXIT_CODE="${rc}"
        die "Dependențele nu pot fi instalate: conflict sau pachet lipsă în apt." \
            "Verifică sursele mixte (etapa 2), apoi 'sudo apt update && sudo apt -f install'. Nu amesteca bookworm cu trixie." \
            "apt-get -s install --no-install-recommends ${DEPS_TO_INSTALL[*]}"
    fi
    ok "Simulare apt reușită: $(grep -c '^Inst ' <<<"${out}" || true) pachete (inclusiv dependențele lor) ar fi instalate."
}

fail_on_missing_critical() {
    (( ${#DEPS_CRITICAL_MISSING[@]} )) || return 0
    local e name desc reason
    error "Dependențe critice care nu pot fi satisfăcute:"
    for e in "${DEPS_CRITICAL_MISSING[@]}"; do
        IFS='|' read -r name desc reason <<<"${e}"
        error "  Pachet: ${name} (${desc})"
        error "    Motiv: ${reason}"
    done
    error "Sistem: ${OS_PRETTY} (Debian ${DEBIAN_VERSION_FULL}), arhitectură ${DPKG_ARCH}"
    die "${#DEPS_CRITICAL_MISSING[@]} dependențe critice lipsesc." \
        "Rulează 'sudo apt update'; verifică 'apt-cache policy <pachet>' și că repository-ul Debian trixie 'main' e activ. Nu am adăugat surse terțe." \
        "apt-cache policy ${DEPS_CRITICAL_MISSING[0]%%|*}"
}

install_dependencies() {
    stage "ETAPA 4/14 — Dependențe Mixxx ${MIXXX_SERIES}.x (Debian ${DEBIAN_VERSION_FULL})"
    if (( OPT_SKIP_DEPS && ! OPT_CHECK_DEPS )); then
        warn "Etapa sărită (--skip-dependencies)."
        return 0
    fi
    info "Rezolv dependențele cu apt-cache policy / showpkg (numele Debian 12 sunt doar rezervă)..."
    analyze_dependencies
    report_qt6
    report_libraries
    fail_on_missing_critical

    if (( ${#DEPS_OPTIONAL_MISSING[@]} )); then
        warn "Opționale indisponibile: ${DEPS_OPTIONAL_MISSING[*]} (Mixxx folosește copii interne sau dezactivează funcția)."
    fi
    if (( ${#DEPS_TO_INSTALL[@]} == 0 )); then
        ok "Toate dependențele sunt deja instalate."
        return 0
    fi
    info "${#DEPS_TO_INSTALL[@]} pachete de instalat: ${DEPS_TO_INSTALL[*]}"
    simulate_install
    (( OPT_CHECK_DEPS )) && return 0

    export DEBIAN_FRONTEND=noninteractive
    if ! run_root apt-get install -y --no-install-recommends -- "${DEPS_TO_INSTALL[@]}"; then
        local reason
        reason="$(grep -E '^E: ' "${LOG_FILE}" | tail -n 3 | tr '\n' ' ' || true)"
        die "Instalarea dependențelor a eșuat (Debian ${DEBIAN_VERSION_FULL}): ${reason:-vezi logul}" \
            "Rulează 'sudo dpkg --configure -a && sudo apt -f install', apoi repornește scriptul."
    fi
    # Verificare post-instalare: fiecare pachet trebuie să fie efectiv instalat
    if (( ! READ_ONLY )); then
        local p
        for p in "${DEPS_TO_INSTALL[@]}"; do
            [[ -n "$(pkg_installed_ver "${p}")" ]] \
                || die "Pachetul ${p} nu apare instalat după apt (Debian ${DEBIAN_VERSION_FULL})." "sudo apt install ${p}" "dpkg-query -W ${p}"
        done
    fi
    ok "Dependențe instalate: ${#DEPS_TO_INSTALL[@]} pachete."
    record "Instalate ${#DEPS_TO_INSTALL[@]} pachete Debian: ${DEPS_TO_INSTALL[*]}"
}

# =============================================================================
# ETAPA 5 — Sursele Mixxx (ultimul tag stabil 2.5.x)
# =============================================================================
# Doar tag-uri X.Y.Z pure: exclude alpha, beta, rc, dev, nightly, -pre etc.
filter_latest_stable_tag() {
    grep -E "^${MIXXX_SERIES//./\\.}\.[0-9]+$" | sort -V | tail -n1
}

prepare_source_dir() {
    if [[ ! -e "${SRC_DIR}" ]]; then
        info "Creez ${SRC_DIR} (proprietar: ${TARGET_USER})"
        run_root mkdir -p "${SRC_DIR}"
        run_root chown "${TARGET_UID}:${TARGET_GID}" "${SRC_DIR}"
        return 0
    fi
    local owner
    owner="$(stat -c %U "${SRC_DIR}")"
    [[ "${owner}" == "${TARGET_USER}" ]] && return 0
    # Director creat anterior de root: îl predăm utilizatorului, dar doar dacă e sursa Mixxx
    if [[ -d "${SRC_DIR}/.git" ]] && git -c safe.directory="${SRC_DIR}" -C "${SRC_DIR}" remote get-url origin 2>/dev/null | grep -q 'mixxxdj/mixxx'; then
        warn "${SRC_DIR} aparține lui '${owner}', dar compilarea rulează ca '${TARGET_USER}'."
        if ask_yes_no "Schimb proprietarul ${SRC_DIR} în ${TARGET_USER} (necesar pentru build fără root)?" "y"; then
            run_root chown -R "${TARGET_UID}:${TARGET_GID}" "${SRC_DIR}"
            record "Proprietar ${SRC_DIR} -> ${TARGET_USER}"
        else
            die "Nu pot compila ca ${TARGET_USER} în ${SRC_DIR} (proprietar ${owner})." "sudo chown -R ${TARGET_USER}: ${SRC_DIR}" "stat ${SRC_DIR}"
        fi
    elif [[ -z "$(ls -A "${SRC_DIR}" 2>/dev/null)" ]]; then
        run_root chown "${TARGET_UID}:${TARGET_GID}" "${SRC_DIR}"
    else
        die "${SRC_DIR} există, nu este repository-ul Mixxx și aparține lui ${owner}." \
            "Mută directorul și repornește scriptul (nu îl șterg automat)." "ls -la ${SRC_DIR}"
    fi
}

fetch_sources() {
    stage "ETAPA 5/14 — Sursele Mixxx (${MIXXX_REPO_URL})"
    if ! need_cmd git; then
        if (( READ_ONLY )); then warn "git nu este instalat încă (se instalează în etapa 4)."; LATEST_TAG="${MIXXX_SERIES}.x"; return 0; fi
        die "git nu este instalat." "sudo apt install git" "command -v git"
    fi

    # Tag-urile se citesc din repository-ul oficial (doar citire)
    info "Interoghez tag-urile oficiale ${MIXXX_SERIES}.x..."
    local remote_tags all_tags skipped git_err rc=0
    git_err="$(mktemp)"
    remote_tags="$(as_user git ls-remote --tags --refs "${MIXXX_REPO_URL}" "refs/tags/${MIXXX_SERIES}.*" 2>"${git_err}")" || rc=$?
    if (( rc != 0 )); then
        local reason; reason="$(tail -n 2 "${git_err}" | tr '\n' ' ')"
        log_block "git ls-remote stderr" "${reason}"
        rm -f -- "${git_err}"
        FAILED_EXIT_CODE="${rc}"
        die "Nu pot contacta ${MIXXX_REPO_URL}: ${reason:-eroare necunoscută}" \
            "Verifică rețeaua, DNS, ora sistemului (certificatele TLS depind de ea) și pachetul ca-certificates." \
            "git ls-remote --tags ${MIXXX_REPO_URL}"
    fi
    rm -f -- "${git_err}"
    all_tags="$(awk -F'refs/tags/' '{print $2}' <<<"${remote_tags}")"
    log_block "Tag-uri ${MIXXX_SERIES}.*" "${all_tags}"
    LATEST_TAG="$(filter_latest_stable_tag <<<"${all_tags}" || true)"
    [[ -n "${LATEST_TAG}" ]] || die "Niciun tag stabil ${MIXXX_SERIES}.x găsit." "" "git ls-remote --tags ${MIXXX_REPO_URL}"
    skipped="$(grep -cvE "^${MIXXX_SERIES//./\\.}\.[0-9]+$" <<<"${all_tags}" || true)"
    ok "Ultima versiune stabilă Mixxx ${MIXXX_SERIES}.x: ${LATEST_TAG} (tag-uri ignorate alpha/beta/rc/dev: ${skipped})"

    # Idempotență: dacă versiunea e deja instalată, nu se recompilează
    if [[ "${INSTALLED_VERSION}" == "${LATEST_TAG}" ]] && (( ! OPT_FORCE )); then
        ok "Mixxx ${LATEST_TAG} este deja instalat."
        if (( ! OPT_DRY_RUN )) && ask_yes_no "Versiunea este deja cea mai nouă. Recompilezi totuși?" "n"; then
            NEED_BUILD=1
        else
            NEED_BUILD=0
            record "Mixxx ${LATEST_TAG} deja instalat — fără recompilare (--force pentru a forța)"
        fi
    fi
    if (( OPT_SKIP_BUILD )) && [[ ! -x "${BUILD_DIR}/mixxx" ]]; then NEED_BUILD=0; fi
    if (( ! NEED_BUILD )) && [[ ! -d "${SRC_DIR}/.git" ]]; then
        info "Compilarea nu este necesară: descărcarea surselor este sărită."
        return 0
    fi

    prepare_source_dir
    if [[ -d "${SRC_DIR}/.git" ]]; then
        local origin
        origin="$(as_user git -C "${SRC_DIR}" remote get-url origin 2>/dev/null || true)"
        [[ "${origin}" == *"mixxxdj/mixxx"* ]] \
            || die "${SRC_DIR} nu este repository-ul oficial Mixxx (origin: ${origin:-?})." "Mută directorul; nu îl șterg." "git remote get-url origin"
        if [[ -n "$(as_user git -C "${SRC_DIR}" status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
            die "Sursele din ${SRC_DIR} au modificări locale; nu le suprascriu." \
                "git -C ${SRC_DIR} stash (sau commit), apoi repornește." "git status"
        fi
        info "Repository existent: git fetch --tags (fără reclonare, fără ștergere)."
        run_user git -C "${SRC_DIR}" fetch --tags --force --prune origin \
            || die "git fetch a eșuat." "Verifică rețeaua."
        record "Repository actualizat (git fetch --tags)"
    else
        info "Clonez repository-ul oficial în ${SRC_DIR} (clone parțial --filter=blob:none)..."
        run_user git clone --filter=blob:none --no-checkout "${MIXXX_REPO_URL}" "${SRC_DIR}" \
            || die "git clone a eșuat." "Verifică rețeaua și spațiul pe disc."
        record "Repository clonat în ${SRC_DIR}"
    fi

    if (( ! OPT_DRY_RUN )); then
        local local_latest
        local_latest="$(as_user git -C "${SRC_DIR}" tag -l "${MIXXX_SERIES}.*" | filter_latest_stable_tag || true)"
        [[ "${local_latest}" == "${LATEST_TAG}" ]] || warn "Tag local (${local_latest:-niciunul}) diferă de cel remote (${LATEST_TAG}); folosesc ${LATEST_TAG}."
        as_user git -C "${SRC_DIR}" rev-parse -q --verify "refs/tags/${LATEST_TAG}" >/dev/null \
            || die "Tag-ul ${LATEST_TAG} nu există local." "git -C ${SRC_DIR} fetch --tags" "git rev-parse refs/tags/${LATEST_TAG}"
    fi
    local current_tag=""
    if [[ -d "${SRC_DIR}/.git" ]]; then
        current_tag="$(as_user git -C "${SRC_DIR}" describe --tags --exact-match 2>/dev/null || true)"
    fi
    if [[ "${current_tag}" == "${LATEST_TAG}" ]]; then
        ok "Sursele sunt deja pe ${LATEST_TAG}."
    else
        run_user git -C "${SRC_DIR}" -c advice.detachedHead=false checkout --detach "refs/tags/${LATEST_TAG}" \
            || die "Checkout ${LATEST_TAG} a eșuat." "git -C ${SRC_DIR} status"
        ok "Checkout: ${LATEST_TAG}"
        record "Checkout Mixxx ${LATEST_TAG}"
    fi
}

# =============================================================================
# ETAPA 6 — Configurarea build-ului (resurse, joburi, swap, CMake)
# =============================================================================
compute_jobs() {
    local swap_mb safe by_ram need_mb
    swap_mb="$(awk '/^SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    # Implicit sigur: min(4, nuclee, (RAM + swap/2) / 1.5 GB). Pi 5 8 GB -> -j4.
    by_ram=$(( (RAM_MB + swap_mb / 2) / RAM_PER_JOB_MB ))
    safe="${CPU_CORES}"
    (( safe > MAX_DEFAULT_JOBS )) && safe="${MAX_DEFAULT_JOBS}"
    (( by_ram < safe )) && safe="${by_ram}"
    (( safe < 1 )) && safe=1
    BUILD_JOBS="${safe}"

    if [[ -n "${OPT_JOBS}" ]]; then
        need_mb=$(( OPT_JOBS * RAM_PER_JOB_MB + 1024 ))
        if (( OPT_JOBS > CPU_CORES )); then
            warn "--jobs ${OPT_JOBS} depășește numărul de nuclee (${CPU_CORES}): câștig minim, consum de RAM mai mare."
        fi
        if (( need_mb > RAM_MB + swap_mb )); then
            warn "--jobs ${OPT_JOBS} poate necesita ~$(( need_mb / 1024 )) GB; RAM+swap: $(( (RAM_MB + swap_mb) / 1024 )) GB."
            if ask_yes_no "Folosesc totuși -j${OPT_JOBS}? (N = -j${safe}, valoarea sigură)" "n"; then
                BUILD_JOBS="${OPT_JOBS}"
            fi
        else
            BUILD_JOBS="${OPT_JOBS}"
        fi
    fi
    ok "Joburi de compilare: -j${BUILD_JOBS} (valoarea sigură implicită: -j${safe})"
}

check_build_resources() {
    local probe="${SRC_DIR}" swap_mb need_mb swaps
    while [[ ! -d "${probe}" && "${probe}" != "/" ]]; do probe="$(dirname "${probe}")"; done
    FREE_DISK_GB="$(df -BG --output=avail "${probe}" | tail -n1 | tr -dc '0-9')"
    if (( FREE_DISK_GB < MIN_FREE_DISK_GB )); then
        die "Spațiu insuficient pe ${probe}: ${FREE_DISK_GB} GB (minim ${MIN_FREE_DISK_GB} GB)." \
            "Eliberează spațiu (sudo apt clean) sau folosește un SSD NVMe/USB." "df -h ${probe}"
    elif (( FREE_DISK_GB < RECOMMENDED_FREE_DISK_GB )); then
        warn "Spațiu liber ${FREE_DISK_GB} GB (recomandat ${RECOMMENDED_FREE_DISK_GB} GB)."
    else
        ok "Spațiu liber pentru build: ${FREE_DISK_GB} GB"
    fi

    info "free -h:"; free -h | sed 's/^/    /'
    swaps="$(swapon --show 2>/dev/null || true)"
    if [[ -n "${swaps}" ]]; then info "swapon --show:"; sed 's/^/    /' <<<"${swaps}"; else info "swapon --show: niciun swap activ"; fi
    swap_mb="$(awk '/^SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    log_raw "MemAvailable=$(awk '/^MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)MB SwapTotal=${swap_mb}MB"

    compute_jobs

    # Necesar estimat: joburi x 1.5 GB + 1 GB (link-ul final al mixxx-lib)
    need_mb=$(( BUILD_JOBS * RAM_PER_JOB_MB + 1024 ))
    if (( RAM_MB + swap_mb < need_mb )); then
        warn "RAM+swap ($(( RAM_MB + swap_mb )) MB) sub necesarul estimat (${need_mb} MB) pentru -j${BUILD_JOBS}."
        if (( OPT_CONFIGURE_SWAP )); then
            local gb=$(( (need_mb - RAM_MB - swap_mb + 1023) / 1024 ))
            (( gb < 2 )) && gb=2
            (( gb > 4 )) && gb=4
            if ask_yes_no "Creez un swap TEMPORAR de ${gb} GB (${TEMP_SWAPFILE}), eliminat automat, fără /etc/fstab?" "y"; then
                enable_temp_swap "${gb}"
            fi
        else
            hint "Swap-ul NU este modificat automat. Rulează cu --configure-swap (swap temporar) sau --jobs $(( BUILD_JOBS > 1 ? BUILD_JOBS - 1 : 1 ))."
        fi
    else
        ok "Memorie + swap suficiente pentru -j${BUILD_JOBS} (necesar estimat ${need_mb} MB)."
        if (( OPT_CONFIGURE_SWAP )); then info "--configure-swap: swap suplimentar nu este necesar."; fi
    fi
    return 0
}

enable_temp_swap() {
    local gb="$1" fstype
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${TEMP_SWAPFILE}"; then ok "Swap temporar deja activ."; return 0; fi
    fstype="$(df --output=fstype "$(dirname "${TEMP_SWAPFILE}")" | tail -n1)"
    if [[ "${fstype}" != "ext4" && "${fstype}" != "xfs" ]]; then
        warn "Sistemul de fișiere ${fstype} nu e potrivit pentru swapfile; sar peste."; return 0
    fi
    if run_root fallocate -l "${gb}G" "${TEMP_SWAPFILE}" && run_root chmod 600 "${TEMP_SWAPFILE}" \
       && run_root mkswap "${TEMP_SWAPFILE}" && run_root swapon "${TEMP_SWAPFILE}"; then
        (( READ_ONLY )) || TEMP_SWAP_ACTIVE=1
        ok "Swap temporar ${gb} GB activ (nepermanent)."
        record "Swap temporar ${gb} GB pe durata build-ului"
    else
        run_root rm -f -- "${TEMP_SWAPFILE}" || true
        warn "Nu am putut crea swap temporar; continui fără."
    fi
}

remove_temp_swap() {
    (( TEMP_SWAP_ACTIVE )) || return 0
    info "Elimin swap-ul temporar ${TEMP_SWAPFILE}"
    "${SUDO[@]}" swapoff "${TEMP_SWAPFILE}" >>"${LOG_FILE}" 2>&1 || true
    "${SUDO[@]}" rm -f -- "${TEMP_SWAPFILE}" >>"${LOG_FILE}" 2>&1 || true
    TEMP_SWAP_ACTIVE=0
}

configure_build() {
    stage "ETAPA 6/14 — Configurarea build-ului"
    if (( OPT_SKIP_BUILD )); then warn "Sărită (--skip-build)."; return 0; fi
    if (( ! NEED_BUILD )); then info "Compilarea nu este necesară."; return 0; fi

    check_build_resources

    # cmake --version: Mixxx 2.5.x cere >= 3.21 (Debian 13: 3.31)
    if need_cmd cmake; then
        CMAKE_VERSION="$(cmake --version | awk 'NR==1 {print $3}')"
        version_ge "${CMAKE_VERSION}" "${MIN_CMAKE}" \
            || die "CMake ${CMAKE_VERSION} < ${MIN_CMAKE} cerut de Mixxx ${MIXXX_SERIES}." "sudo apt install cmake (Debian 13 are 3.31)" "cmake --version"
        ok "CMake ${CMAKE_VERSION} (>= ${MIN_CMAKE}): compatibil"
    elif (( READ_ONLY )); then
        info "CMake nu este încă instalat (etapa 4)."
    else
        die "cmake lipsește." "sudo apt install cmake" "command -v cmake"
    fi
    if need_cmd g++; then ok "Compilator: $(g++ --version | head -n1)"; fi

    if need_cmd ninja; then CMAKE_GENERATOR="Ninja"; fi
    if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
        # Un build existent nu își poate schimba generatorul
        local cached
        cached="$(awk -F= '/^CMAKE_GENERATOR:INTERNAL=/ {print $2}' "${BUILD_DIR}/CMakeCache.txt")"
        [[ -n "${cached}" ]] && CMAKE_GENERATOR="${cached}"
        if (( OPT_FORCE )); then
            info "--force: șterg doar CMakeCache.txt (fișierele obiect rămân)."
            run_user rm -f -- "${BUILD_DIR}/CMakeCache.txt"
        fi
    fi

    local -a args=(
        -S "${SRC_DIR}" -B "${BUILD_DIR}" -G "${CMAKE_GENERATOR}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
        # "portable" pe aarch64 = doar -O3, fără -mcpu/-march: build ARM64 portabil
        -DOPTIMIZE=portable
        # Fără teste/benchmark: compilare mai scurtă și mai puțină memorie pe Pi 5
        -DBUILD_TESTING=OFF
        -DBUILD_BENCH=OFF
    )
    if (( OPT_NO_EXTERNAL )); then
        # Evită descărcările făcute de CMake (libdjinterop 0.24.3, libkeyfinder)
        args+=(-DENGINEPRIME=OFF -DKEYFINDER=OFF)
        info "--no-external-downloads: Engine Prime export și KeyFinder dezactivate."
    else
        info "CMake-ul Mixxx va descărca libdjinterop 0.24.3 (Debian are 0.22.x; Mixxx cere versiunea EXACTĂ) și libkeyfinder (absent din Debian), din surse oficiale verificate SHA256. Dezactivare: --no-external-downloads"
    fi
    ok "Generator: ${CMAKE_GENERATOR}; CMAKE_BUILD_TYPE=Release; OPTIMIZE=portable; prefix ${INSTALL_PREFIX}"
    log_block "Configurare CMake" "cmake ${args[*]}"

    run_user mkdir -p "${BUILD_DIR}"
    info "Rulez CMake (ca ${TARGET_USER})..."
    if ! run_user cmake "${args[@]}"; then
        show_log_tail 80
        die "Configurarea CMake a eșuat; ${BUILD_DIR} a fost păstrat." \
            "Caută 'Could NOT find' / 'CMake Error' în log; verifică: ./${SCRIPT_NAME} --check-dependencies"
    fi
    ok "CMake configurat."
    record "CMake: Release, OPTIMIZE=portable, prefix ${INSTALL_PREFIX}, generator ${CMAKE_GENERATOR}"
}

show_log_tail() {
    local n="${1:-80}"
    [[ -r "${LOG_FILE}" ]] || return 0
    printf '%s--- Linii cu erori (ultimele 25) ---%s\n' "${C_BOLD}" "${C_RESET}" >&2
    grep -nE 'error:|CMake Error|Could NOT find|FAILED:|Killed|fatal' "${LOG_FILE}" | tail -n 25 >&2 || true
    printf '%s--- Ultimele %s linii din log ---%s\n' "${C_BOLD}" "${n}" "${C_RESET}" >&2
    tail -n "${n}" "${LOG_FILE}" >&2
}

# =============================================================================
# ETAPA 7 — Compilarea (ca utilizator normal)
# =============================================================================
build_mixxx() {
    stage "ETAPA 7/14 — Compilarea"
    if (( OPT_SKIP_BUILD )); then warn "Sărită (--skip-build)."; BUILD_RESULT="sărit (--skip-build)"; return 0; fi
    if (( ! NEED_BUILD )); then info "Compilarea nu este necesară."; BUILD_RESULT="nu a fost necesar"; return 0; fi

    info "Compilez Mixxx ${LATEST_TAG} (Release, -j${BUILD_JOBS}, ca ${TARGET_USER}); pe Pi 5 durează ~40–90 min."
    if (( READ_ONLY )); then
        run_user cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"
        BUILD_RESULT="simulat"; return 0
    fi

    local start end rc=0 tty=0
    [[ -t 1 ]] && tty=1
    start="$(date +%s)"
    LAST_RUN="cmake --build ${BUILD_DIR} --parallel ${BUILD_JOBS}"
    log_raw "[RUN] ${LAST_RUN}"
    # Log complet în fișier; în terminal doar progresul ([ 42%] sau [123/2000]) și erorile.
    # Cu pipefail, "|| rc=$?" preia codul lui cmake (tee/awk nu eșuează).
    as_user cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}" 2>&1 \
        | tee -a "${LOG_FILE}" \
        | awk -v verbose="${OPT_VERBOSE}" -v tty="${tty}" '
            verbose == 1 { print; fflush(); next }
            match($0, /^\[ *[0-9]+%\]|^\[[0-9]+\/[0-9]+\]/) {
                p = substr($0, RSTART, RLENGTH)
                if (tty == 1) { printf "\r  Progres: %-14s", p; fflush() }
                else if (++n % 200 == 0) { print "  Progres: " p; fflush() }
                next
            }
            /error:|FAILED:|Killed/ { if (tty == 1) printf "\n"; print "  " $0; fflush() }
            END { if (tty == 1) printf "\n" }' || rc=$?
    end="$(date +%s)"

    if (( rc != 0 )); then
        BUILD_RESULT="EȘUAT (cod ${rc})"
        FAILED_EXIT_CODE="${rc}"
        show_log_tail 100
        local sugg="Build-ul și sursele au fost păstrate; rularea din nou reia compilarea incremental."
        if grep -qE 'Killed|out of memory|internal compiler error' "${LOG_FILE}"; then
            sugg="Memorie insuficientă (OOM): rulează cu --jobs 2 sau --configure-swap."
        fi
        die "Compilarea a eșuat." "${sugg}" "cmake --build ${BUILD_DIR} --parallel ${BUILD_JOBS}"
    fi
    [[ -x "${BUILD_DIR}/mixxx" ]] || die "Build terminat, dar ${BUILD_DIR}/mixxx lipsește." "" "test -x ${BUILD_DIR}/mixxx"
    BUILD_RESULT="SUCCESS în $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s (-j${BUILD_JOBS})"
    ok "Compilare reușită: ${BUILD_RESULT}"
    record "Mixxx ${LATEST_TAG} compilat (${BUILD_RESULT})"
}

# =============================================================================
# ETAPA 8 — Instalarea (staging verificat, apoi /usr/local)
# =============================================================================
# Verifică: ELF ARM64 și toate bibliotecile dinamice găsite
verify_binary() {
    local bin="$1" ctx="$2" desc missing
    [[ -x "${bin}" ]] || { error "${ctx}: ${bin} lipsește."; return 1; }
    desc="$(file -L "${bin}" 2>/dev/null || true)"
    [[ "${desc}" == *"ARM aarch64"* ]] || { error "${ctx}: nu este ARM64: ${desc}"; return 1; }
    missing="$(ldd "${bin}" 2>/dev/null | grep 'not found' || true)"
    if [[ -n "${missing}" ]]; then error "${ctx}: biblioteci lipsă:"; printf '    %s\n' "${missing}" >&2; return 1; fi
    return 0
}

install_mixxx() {
    stage "ETAPA 8/14 — Instalarea"
    if (( ! NEED_BUILD )) || { [[ ! -x "${BUILD_DIR}/mixxx" ]] && (( ! READ_ONLY )); }; then
        if [[ -n "${INSTALLED_BIN}" ]]; then
            info "Păstrez instalarea existentă: ${INSTALLED_BIN} (${INSTALLED_VERSION})."
        elif (( OPT_SKIP_BUILD )); then
            die "--skip-build: nu există nici build, nici instalare Mixxx." "Rulează fără --skip-build." "--skip-build"
        fi
        return 0
    fi

    # 8.1 Instalare de probă în build/stage: versiunea existentă rămâne neatinsă
    info "Instalare de probă în ${STAGE_DIR}..."
    safe_rm_dir "${STAGE_DIR}" "${BUILD_DIR}"
    run_user env DESTDIR="${STAGE_DIR}" cmake --install "${BUILD_DIR}" \
        || die "Instalarea de probă a eșuat; instalarea existentă este neatinsă." "Vezi logul."
    if (( ! READ_ONLY )); then
        local staged="${STAGE_DIR}${INSTALL_PREFIX}/bin/mixxx" staged_ver
        verify_binary "${staged}" "Staging" \
            || die "Noul executabil nu a trecut verificarea (ARM64/ldd); instalarea existentă este păstrată." "ldd ${staged}" "ldd ${staged}"
        staged_ver="$(mixxx_version_of "${staged}")"
        info "Versiune build nou: ${staged_ver:-necunoscută}"
        if [[ -n "${staged_ver}" && "${staged_ver}" != "${LATEST_TAG}"* ]]; then
            warn "Versiunea raportată (${staged_ver}) diferă de ${LATEST_TAG}."
        fi
        ok "Build verificat (ARM64, biblioteci, --version)."
    fi

    # 8.2 Backup al executabilului anterior
    if [[ -x "${INSTALL_PREFIX}/bin/mixxx" ]]; then
        run_root cp -a -- "${INSTALL_PREFIX}/bin/mixxx" "${INSTALL_PREFIX}/bin/mixxx.previous"
        record "Backup executabil anterior: ${INSTALL_PREFIX}/bin/mixxx.previous"
    fi

    # 8.3 Instalarea reală (singurul pas legat de build care necesită root)
    info "Instalez în ${INSTALL_PREFIX}..."
    run_root cmake --install "${BUILD_DIR}" || die "'cmake --install' a eșuat." "Vezi logul: ${LOG_FILE}"
    # install_manifest.txt e scris de root: îl redăm utilizatorului pentru build-urile viitoare
    if [[ -e "${BUILD_DIR}/install_manifest.txt" ]]; then
        run_root chown "${TARGET_UID}:${TARGET_GID}" "${BUILD_DIR}/install_manifest.txt"
    fi
    run_root ldconfig || true
    safe_rm_dir "${STAGE_DIR}" "${BUILD_DIR}"

    run_root mkdir -p "${STATE_DIR}"
    if (( ! READ_ONLY )); then
        printf 'installed_tag=%s\ninstalled_at=%s\nsource_dir=%s\nbuild_dir=%s\n' \
            "${LATEST_TAG}" "$(date '+%F %T')" "${SRC_DIR}" "${BUILD_DIR}" | "${SUDO[@]}" tee "${STATE_FILE}" >/dev/null
    fi
    detect_installed_mixxx
    if (( READ_ONLY )); then ok "(dry-run) Instalare simulată."; return 0; fi
    [[ -x "${INSTALL_PREFIX}/bin/mixxx" ]] || die "${INSTALL_PREFIX}/bin/mixxx lipsește după instalare." "" "test -x ${INSTALL_PREFIX}/bin/mixxx"
    ok "Mixxx ${INSTALLED_VERSION} instalat în ${INSTALL_PREFIX}"
    record "Mixxx ${INSTALLED_VERSION} instalat în ${INSTALL_PREFIX}"

    # 8.4 Reguli udev (acces fără root la controllere HID/USB Bulk) — doar cu confirmare
    local rules_src="${INSTALL_PREFIX}/share/mixxx/udev/rules.d/mixxx-usb-uaccess.rules"
    local rules_dst="/etc/udev/rules.d/69-mixxx-usb-uaccess.rules"
    if [[ -f "${rules_src}" ]]; then
        if [[ -f "${rules_dst}" ]] && cmp -s "${rules_src}" "${rules_dst}"; then
            ok "Regulile udev Mixxx sunt deja instalate."
        elif ask_yes_no "Instalez regulile udev Mixxx (acces la controllere HID/USB fără root) în ${rules_dst}?" "y"; then
            if run_root install -D -m 644 -- "${rules_src}" "${rules_dst}"; then
                run_root udevadm control --reload-rules || true
                run_root udevadm trigger --subsystem-match=usb --subsystem-match=hidraw || true
                record "Reguli udev: ${rules_dst}"
            else
                warn "Nu am putut instala regulile udev (vezi log); Mixxx funcționează, dar controllerele HID pot cere permisiuni."
            fi
        else
            info "Regulile udev nu au fost instalate (controllerele HID pot necesita permisiuni)."
        fi
    fi
}

# =============================================================================
# ETAPA 9 — Launcher desktop (Mixxx rulează ca utilizator normal)
# =============================================================================
detect_wayland_session() {
    local rt="/run/user/${TARGET_UID}" s
    WAYLAND_SESSION=0
    if compgen -G "${rt}/wayland-*" >/dev/null 2>&1; then WAYLAND_SESSION=1; fi
    if need_cmd loginctl; then
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="${TARGET_USER}" '$3==u {print $1}' || true); do
            if [[ "$(loginctl show-session "${s}" -p Type --value 2>/dev/null || true)" == "wayland" ]]; then WAYLAND_SESSION=1; fi
        done
    fi
    return 0
}

write_desktop_file() {
    local dest="$1" name="$2" exec_line="$3" content
    content="[Desktop Entry]
Version=1.0
Type=Application
Name=${name}
GenericName=Digital DJ interface
GenericName[ro]=Sistem DJ digital
Comment=A digital DJ interface
Exec=${exec_line}
Icon=mixxx
Terminal=false
StartupNotify=true
StartupWMClass=org.mixxx.mixxx
Categories=Qt;AudioVideo;Audio;Midi;Mixer;Player;
Keywords=dj;music;alsa;jack;"
    if (( READ_ONLY )); then _print_dry "scriere ${dest} (Exec=${exec_line})"; return 0; fi
    LAST_RUN="tee ${dest}"
    printf '%s\n' "${content}" | "${SUDO[@]}" tee "${dest}" >/dev/null
    "${SUDO[@]}" chmod 644 "${dest}"
    if need_cmd desktop-file-validate && ! desktop-file-validate "${dest}" >>"${LOG_FILE}" 2>&1; then
        warn "desktop-file-validate a raportat probleme pentru ${dest} (vezi log)."
    fi
}

setup_desktop_entry() {
    stage "ETAPA 9/14 — Launcher desktop"
    local apps="${INSTALL_PREFIX}/share/applications"
    local upstream="${apps}/org.mixxx.Mixxx.desktop" fallback="${apps}/mixxx-rpi5.desktop"
    local xwl="${apps}/org.mixxx.Mixxx-xwayland.desktop"

    if [[ ! -x "${INSTALL_PREFIX}/bin/mixxx" ]] && (( ! READ_ONLY )); then
        warn "Mixxx nu este instalat în ${INSTALL_PREFIX}; nu configurez launcher-ul."; return 0
    fi

    if [[ -f "${upstream}" ]]; then
        ok "Launcher creat de instalarea CMake: ${upstream}"
        # Launcher-ul NU trebuie să ruleze Mixxx cu privilegii elevate
        if grep -qE '^Exec=.*(sudo|pkexec|gksu|su -c)' "${upstream}"; then
            warn "Launcher-ul conține o comandă de elevare a privilegiilor! Verifică ${upstream}."
        else
            ok "Exec: $(grep -m1 '^Exec=' "${upstream}" | cut -d= -f2-)  (utilizator normal, fără sudo)"
        fi
    elif [[ -f "${fallback}" ]]; then
        ok "Launcher existent: ${fallback}"
    else
        info "Instalarea nu a creat un launcher; creez ${fallback}"
        write_desktop_file "${fallback}" "Mixxx" "${INSTALL_PREFIX}/bin/mixxx"
        record "Launcher creat: ${fallback}"
    fi

    # Wayland: Debian pornește Mixxx cu -platform xcb (bug Debian #1039859)
    detect_wayland_session
    if (( WAYLAND_SESSION )); then
        if [[ -f "${xwl}" ]]; then
            XWAYLAND_LAUNCHER=1; ok "Launcher XWayland existent: ${xwl}"
        else
            warn "Sesiune Wayland detectată: GUI-ul Mixxx poate avea probleme sub Wayland nativ (Debian folosește XWayland)."
            if ask_yes_no "Creez un launcher suplimentar 'Mixxx (XWayland)' cu QT_QPA_PLATFORM=xcb?" "y"; then
                write_desktop_file "${xwl}" "Mixxx (XWayland)" "env QT_QPA_PLATFORM=xcb ${INSTALL_PREFIX}/bin/mixxx"
                XWAYLAND_LAUNCHER=1
                record "Launcher XWayland: ${xwl}"
            fi
        fi
    fi

    if need_cmd update-desktop-database; then run_root update-desktop-database -q "${apps}" || true; fi
    if need_cmd gtk-update-icon-cache && [[ -d "${INSTALL_PREFIX}/share/icons/hicolor" ]]; then
        run_root gtk-update-icon-cache -q -f "${INSTALL_PREFIX}/share/icons/hicolor" || true
    fi
    return 0
}

# =============================================================================
# ETAPA 10 — Audio backend (doar detectare; nimic nu este modificat)
# =============================================================================
detect_audio() {
    stage "ETAPA 10/14 — Audio backend (doar detectare)"
    local out cards=0 play=0 cap=0 pw_state pwp_state pactl_out dev

    # ALSA (aplay -l / arecord -l)
    if [[ -r /proc/asound/cards ]]; then
        cards="$(grep -cE '^ *[0-9]+ \[' /proc/asound/cards || true)"
    fi
    if need_cmd aplay; then
        out="$(aplay -l 2>&1 || true)";   log_block "aplay -l" "${out}";   play="$(grep -c '^card ' <<<"${out}" || true)"
        out="$(arecord -l 2>&1 || true)"; log_block "arecord -l" "${out}"; cap="$(grep -c '^card ' <<<"${out}" || true)"
    fi
    if (( cards > 0 )); then
        AUDIO_ALSA="activ (${cards} plăci; ${play} playback, ${cap} capture)"
        ok "ALSA: ${AUDIO_ALSA}"
        grep -E '^ *[0-9]+ \[' /proc/asound/cards | sed 's/^/    /' || true
    else
        AUDIO_ALSA="nicio placă de sunet"; warn "ALSA: nicio placă de sunet detectată."
    fi

    # PipeWire (systemctl --user în sesiunea utilizatorului real)
    pw_state="$(as_user_session timeout 5 systemctl --user is-active pipewire 2>/dev/null || true)"
    pwp_state="$(as_user_session timeout 5 systemctl --user is-active pipewire-pulse 2>/dev/null || true)"
    if [[ "${pw_state}" != "active" ]] && pgrep -u "${TARGET_UID}" -x pipewire >/dev/null 2>&1; then pw_state="active"; fi
    if [[ "${pw_state}" == "active" ]]; then
        AUDIO_PIPEWIRE="activ $(pipewire --version 2>/dev/null | awk '/Linked with libpipewire/ {print $NF}' || true)"
        [[ "${pwp_state}" == "active" ]] && AUDIO_PIPEWIRE+=", pipewire-pulse activ"
    elif need_cmd pipewire; then
        AUDIO_PIPEWIRE="instalat, inactiv (nicio sesiune grafică activă?)"
    else
        AUDIO_PIPEWIRE="neinstalat"
    fi
    if [[ "${pw_state}" == "active" ]]; then ok "PipeWire: ${AUDIO_PIPEWIRE}"; else info "PipeWire: ${AUDIO_PIPEWIRE}"; fi

    # PulseAudio (pactl info: server nativ sau API-ul Pulse furnizat de PipeWire)
    if need_cmd pactl; then
        pactl_out="$(as_user_session timeout 5 pactl info 2>/dev/null || true)"
        log_block "pactl info" "${pactl_out}"
        if grep -q 'Server Name:.*PipeWire' <<<"${pactl_out}"; then
            AUDIO_PULSE="API PulseAudio furnizat de PipeWire"
        elif grep -q 'Server Name:' <<<"${pactl_out}"; then
            AUDIO_PULSE="server PulseAudio nativ ($(awk -F': ' '/Server Name/ {print $2}' <<<"${pactl_out}"))"
        else
            AUDIO_PULSE="niciun server accesibil"
        fi
    else
        AUDIO_PULSE="pactl neinstalat"
    fi
    ok "PulseAudio: ${AUDIO_PULSE}"

    # JACK (server jackd real sau API JACK prin pipewire-jack)
    if pgrep -x jackd >/dev/null 2>&1 || pgrep -x jackdbus >/dev/null 2>&1; then
        AUDIO_JACK="server jackd activ"
    elif [[ -n "$(pkg_installed_ver pipewire-jack)" ]]; then
        AUDIO_JACK="API JACK prin PipeWire (pipewire-jack; pornire: pw-jack mixxx)"
    elif need_cmd jackd; then
        AUDIO_JACK="jackd instalat, inactiv"
    else
        AUDIO_JACK="indisponibil"
    fi
    ok "JACK: ${AUDIO_JACK}"

    if [[ "${pw_state}" == "active" ]]; then AUDIO_BACKEND="PipeWire"
    elif [[ "${AUDIO_PULSE}" == server* ]]; then AUDIO_BACKEND="PulseAudio"
    elif [[ "${AUDIO_JACK}" == "server jackd activ" ]]; then AUDIO_BACKEND="JACK"
    elif (( cards > 0 )); then AUDIO_BACKEND="ALSA (direct)"
    else AUDIO_BACKEND="niciunul"; fi
    ok "Audio backend detected: ${AUDIO_BACKEND}"

    # Accesul utilizatorului real la /dev/snd (grup audio sau ACL logind/uaccess)
    dev="$(compgen -G '/dev/snd/controlC*' | head -n1 || true)"
    if [[ -n "${dev}" ]]; then
        if as_user test -r "${dev}" -a -w "${dev}"; then
            ok "${TARGET_USER} are acces la dispozitivele audio (/dev/snd)."
        else
            warn "${TARGET_USER} NU are acces la /dev/snd. Recomandare: sudo usermod -aG audio ${TARGET_USER} (apoi re-login)."
        fi
    fi
    info "Configurația audio NU a fost modificată."
}

print_audio_recommendations() {
    echo
    printf '%sRecomandări Mixxx (Preferences -> Sound Hardware):%s\n' "${C_BOLD}" "${C_RESET}"
    case "${AUDIO_BACKEND}" in
        PipeWire)
            echo "  - PipeWire: pornește 'pw-jack mixxx' și alege Sound API 'JACK Audio Connection Kit' (latență mică,"
            echo "    celelalte aplicații rămân funcționale), sau API 'ALSA' cu dispozitivul 'pipewire'." ;;
        PulseAudio)
            echo "  - PulseAudio: launcher-ul oficial folosește 'pasuspender' ca Mixxx să primească placa exclusiv; API 'ALSA'." ;;
        JACK)
            echo "  - JACK activ: Sound API 'JACK Audio Connection Kit'." ;;
        *)
            echo "  - ALSA direct: Sound API 'ALSA', dispozitivul 'hw:<placă>' pentru latență minimă." ;;
    esac
    if [[ -n "${USB_AUDIO_LIST}" ]]; then
        echo "  - Interfață USB detectată: Master pe ieșirile 1-2, Headphones pe 3-4; buffer 10-23 ms la 44.1/48 kHz."
    else
        echo "  - Fără interfață audio USB: ieșirea HDMI a Pi 5 nu permite cue separat; recomand o placă USB cu 4 ieșiri."
    fi
    [[ "${GPU_DRIVER}" == *v3d* ]] || echo "  - Fără accelerare GPU (v3d): alege forme de undă 'Simple' în Preferences -> Waveforms."
    (( XWAYLAND_LAUNCHER )) && echo "  - Sub Wayland folosește launcher-ul 'Mixxx (XWayland)' dacă interfața are probleme."
    return 0
}

# =============================================================================
# ETAPA 11 — Controllere DJ / interfețe USB (doar detectare)
# =============================================================================
# Producători frecvenți de echipament DJ/audio (ID vendor USB)
declare -rA DJ_VENDORS=(
    [2b73]="Pioneer DJ/AlphaTheta" [08e4]="Pioneer" [17cc]="Native Instruments" [15e4]="Numark/Denon DJ"
    [09e8]="Akai Professional" [06f8]="Hercules" [200c]="Reloop" [1397]="Behringer" [22f0]="Allen & Heath"
    [0582]="Roland" [0763]="M-Audio" [1235]="Focusrite/Novation" [1c75]="Arturia" [0944]="Korg"
    [194f]="PreSonus" [1686]="Zoom" [0499]="Yamaha"
)

detect_controllers() {
    stage "ETAPA 11/14 — Controllere DJ și interfețe USB"
    if need_cmd lsusb; then
        info "lsusb:"; lsusb | sed 's/^/    /' | tee -a "${LOG_FILE}"
    else
        warn "lsusb lipsește (pachetul usbutils)."
    fi

    # Clasificare după clasa interfeței USB (sysfs): 01/02 audio, 01/03 MIDI, 03 HID
    local dev vid pid name intf cls sub proto kinds dj label out
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "${dev}/idVendor" ]] || continue
        vid="$(cat "${dev}/idVendor")"; pid="$(cat "${dev}/idProduct")"
        name="$(cat "${dev}/manufacturer" 2>/dev/null || true) $(cat "${dev}/product" 2>/dev/null || true)"
        name="${name# }"; name="${name% }"; name="${name:-${vid}:${pid}}"
        kinds=""
        for intf in "${dev}"/*:*; do
            [[ -f "${intf}/bInterfaceClass" ]] || continue
            cls="$(cat "${intf}/bInterfaceClass")"; sub="$(cat "${intf}/bInterfaceSubClass")"
            proto="$(cat "${intf}/bInterfaceProtocol" 2>/dev/null || echo 00)"
            case "${cls}:${sub}" in
                01:02) [[ "${kinds}" == *audio* ]] || kinds+="audio " ;;
                01:03) [[ "${kinds}" == *midi* ]]  || kinds+="midi " ;;
                03:*)  # exclude tastaturi (01) și mouse-uri (02)
                       if [[ "${proto}" != "01" && "${proto}" != "02" && "${kinds}" != *hid* ]]; then kinds+="hid "; fi ;;
            esac
        done
        [[ -n "${kinds}" ]] || continue
        kinds="${kinds% }"
        dj="${DJ_VENDORS[${vid}]:-}"
        label="${name} [${vid}:${pid}]${dj:+ (${dj})}"
        [[ "${kinds}" == *audio* ]] && USB_AUDIO_LIST+="${label}; "
        if [[ "${kinds}" == *midi* || "${kinds}" == *hid* ]]; then USB_MIDI_LIST+="${label} (${kinds// /+}); "; fi
    done
    USB_AUDIO_LIST="${USB_AUDIO_LIST%; }"; USB_MIDI_LIST="${USB_MIDI_LIST%; }"

    if [[ -n "${USB_AUDIO_LIST}" ]]; then ok "Interfețe audio USB: ${USB_AUDIO_LIST}"; else info "Nicio interfață audio USB."; fi
    if [[ -n "${USB_MIDI_LIST}" ]]; then ok "Controllere MIDI/HID: ${USB_MIDI_LIST}"; else info "Niciun controller MIDI/HID detectat."; fi
    if need_cmd amidi; then
        out="$(amidi -l 2>/dev/null | tail -n +2 || true)"
        if [[ -n "${out}" ]]; then info "Porturi MIDI (amidi -l):"; sed 's/^/    /' <<<"${out}"; fi
    fi

    # Accesul utilizatorului real la dispozitivele HID/USB
    local denied=0 h g groups
    for h in /dev/hidraw*; do
        [[ -e "${h}" ]] || continue
        as_user test -r "${h}" -a -w "${h}" || denied=$(( denied + 1 ))
    done
    if [[ ! -d /dev/bus/usb ]]; then
        USB_ACCESS="/dev/bus/usb lipsește"; warn "USB: ${USB_ACCESS}"
    elif (( denied > 0 )); then
        USB_ACCESS="${denied} dispozitive hidraw fără acces pentru ${TARGET_USER}"
        warn "${USB_ACCESS}. Instalează regulile udev Mixxx (etapa 8) și reconectează controllerul."
    else
        USB_ACCESS="OK"
        ok "Acces USB/HID pentru ${TARGET_USER}: OK"
    fi
    groups="$(id -nG "${TARGET_USER}" 2>/dev/null || true)"
    for g in audio plugdev; do
        if [[ " ${groups} " == *" ${g} "* ]]; then ok "${TARGET_USER} este în grupul '${g}'."
        else info "${TARGET_USER} nu este în grupul '${g}' (pe Debian accesul se poate face și prin ACL logind/uaccess)."; fi
    done
    info "Nu au fost instalate drivere. Mapări controllere: Mixxx -> Preferences -> Controllers."
}

# =============================================================================
# ETAPA 12 — Verificare finală (ca utilizator normal, fără sudo)
# =============================================================================
final_verification() {
    stage "ETAPA 12/14 — Verificare finală"
    local which_out ver fdesc bin final_ok=1
    # "which mixxx" cu PATH-ul unui shell de login al utilizatorului normal
    which_out="$(as_user bash -lc 'command -v mixxx' 2>/dev/null | tail -n1 || true)"
    bin="${which_out:-${INSTALLED_BIN}}"
    if [[ -z "${bin}" || ! -x "${bin}" ]]; then
        if (( READ_ONLY )); then info "(read-only) Mixxx nu este instalat încă; verificarea ar rula după instalare."; return 0; fi
        die "Executabilul mixxx nu este accesibil utilizatorului ${TARGET_USER}." "Verifică PATH (trebuie să conțină ${INSTALL_PREFIX}/bin)." "which mixxx"
    fi
    if [[ -n "${which_out}" ]]; then
        ok "which mixxx (${TARGET_USER}): ${which_out}"
    else
        warn "${INSTALL_PREFIX}/bin nu este în PATH-ul lui ${TARGET_USER}; executabil: ${bin}"; final_ok=0
    fi
    INSTALLED_BIN="${bin}"

    ver="$(mixxx_version_of "${bin}")"
    if [[ -n "${ver}" ]]; then ok "mixxx --version (fără sudo): ${ver}"; INSTALLED_VERSION="${ver}"
    else warn "mixxx --version nu a răspuns în mod offscreen."; fi

    fdesc="$(file -L "${bin}" 2>/dev/null || true)"
    log_block "file ${bin}" "${fdesc}"
    log_block "ldd ${bin}" "$(ldd "${bin}" 2>&1 || true)"
    if verify_binary "${bin}" "Verificare finală"; then
        ok "file: $(grep -oE 'ELF 64-bit[^,]*, ARM aarch64' <<<"${fdesc}" || echo 'ARM aarch64')"
        ok "ldd: $(ldd "${bin}" | wc -l) biblioteci, niciuna lipsă"
    else
        final_ok=0
    fi

    echo
    echo "  Mixxx version:         ${INSTALLED_VERSION:-?}"
    echo "  Architecture:          $([[ "${fdesc}" == *"ARM aarch64"* ]] && echo 'ARM64 (aarch64)' || echo '?')"
    echo "  Executable:            ${bin}"
    echo "  Install prefix:        ${INSTALL_PREFIX}"
    echo "  Audio backend:         ${AUDIO_BACKEND}"
    echo "  USB audio devices:     ${USB_AUDIO_LIST:-niciunul}"
    echo "  USB MIDI/HID devices:  ${USB_MIDI_LIST:-niciunul}"
    echo "  Free disk:             $(df -h --output=avail / | tail -n1 | tr -d ' ')"
    echo "  Free RAM:              $(free -h | awk '/^Mem:/ {print $7}')"
    echo "  Swap:                  $(free -h | awk '/^Swap:/ {print $2}')"
    echo
    log_raw "Verificare finală: which=${which_out:-none} version=${ver:-?} arm64=$([[ "${fdesc}" == *"ARM aarch64"* ]] && echo yes || echo no)"

    if (( final_ok )); then
        printf '%sMixxx a fost instalat cu succes.%s  Pornire: mixxx  (sau din meniu: Sound & Video -> Mixxx)\n' "${C_GREEN}" "${C_RESET}"
    else
        die "Verificarea finală a eșuat." "Vezi mesajele de mai sus și ${LOG_FILE}." "verificare finală (which/file/ldd)"
    fi
}

# =============================================================================
# ETAPA 13 — Test de pornire (doar cu confirmare, NICIODATĂ ca root)
# =============================================================================
maybe_launch_mixxx() {
    stage "ETAPA 13/14 — Test de pornire"
    local bin="${INSTALLED_BIN:-${INSTALL_PREFIX}/bin/mixxx}"
    if (( OPT_YES )); then info "--yes nu pornește Mixxx automat. Pornire manuală: mixxx"; return 0; fi
    if [[ "${TARGET_USER}" == "root" ]]; then
        warn "Nu pornesc Mixxx ca root. Autentifică-te ca utilizator normal și rulează: mixxx"; return 0
    fi
    if [[ ! -x "${bin}" ]] && (( ! OPT_DRY_RUN )); then warn "Mixxx nu este instalat."; return 0; fi

    ask_yes_no "Do you want to launch Mixxx now?" "n" || { info "Pornire manuală: mixxx"; return 0; }

    local rt="/run/user/${TARGET_UID}" wl="${WAYLAND_DISPLAY:-}" disp="${DISPLAY:-}" sock
    if [[ -z "${wl}" ]]; then
        sock="$(compgen -G "${rt}/wayland-[0-9]" | head -n1 || true)"
        [[ -n "${sock}" ]] && wl="$(basename "${sock}")"
    fi
    [[ -z "${disp}" && -e /tmp/.X11-unix/X0 ]] && disp=":0"
    if [[ -z "${wl}" && -z "${disp}" ]]; then
        warn "Nu găsesc o sesiune grafică pentru ${TARGET_USER}. Pornește Mixxx din desktop."; return 0
    fi
    local -a envs=("XDG_RUNTIME_DIR=${rt}" "DBUS_SESSION_BUS_ADDRESS=unix:path=${rt}/bus")
    [[ -n "${wl}" ]] && envs+=("WAYLAND_DISPLAY=${wl}")
    [[ -n "${disp}" ]] && envs+=("DISPLAY=${disp}")
    if (( XWAYLAND_LAUNCHER )) && [[ -n "${disp}" ]]; then envs+=("QT_QPA_PLATFORM=xcb"); fi

    if (( READ_ONLY )); then
        _print_dry "(ca ${TARGET_USER}) env ${envs[*]} setsid -f ${bin}"
    else
        LAST_RUN="setsid -f ${bin} (ca ${TARGET_USER})"
        as_user env "${envs[@]}" setsid -f "${bin}" >/dev/null 2>&1 </dev/null
        MIXXX_STARTED=1
        ok "Mixxx pornit ca ${TARGET_USER} (nu root)."
        record "Mixxx pornit ca ${TARGET_USER}"
    fi
}

# =============================================================================
# ETAPA 14 — Raport final
# =============================================================================
final_report() {
    REPORT_DONE=1
    set +e
    [[ "${INSTALL_STATUS}" == "IN PROGRESS" ]] && INSTALL_STATUS="SUCCESS"
    local status="${INSTALL_STATUS}"
    if [[ "${status}" == "SUCCESS" ]]; then
        (( OPT_DRY_RUN )) && status="SUCCESS (DRY-RUN — nimic nu a fost modificat)"
        (( OPT_SYSTEM_INFO )) && status="SYSTEM INFO (nimic nu a fost modificat)"
        (( OPT_CHECK_DEPS )) && status="DEPENDENCIES OK (nimic nu a fost modificat)"
    fi

    local report
    report="$(
        echo
        echo "========================================"
        echo " MIXXX INSTALLATION SUMMARY"
        echo "========================================"
        echo
        echo "System:";       echo "${OS_PRETTY:-?} — Debian ${DEBIAN_VERSION_FULL:-?}, kernel ${KERNEL:-?}"; echo
        echo "Architecture:"; echo "${ARCH:-?}"; echo
        echo "Hardware:";     echo "${PI_MODEL:-?} (GPU: ${GPU_DRIVER})"; echo
        echo "RAM:";          echo "$(( (RAM_MB + 512) / 1024 )) GB (${RAM_MB} MB)"; echo
        echo "CPU:";          echo "${CPU_CORES} cores${CPU_MODEL:+ (${CPU_MODEL})}"; echo
        echo "Mixxx:";        echo "${INSTALLED_VERSION:-neinstalat} (ultimul stabil ${MIXXX_SERIES}.x: ${LATEST_TAG:-?})"; echo
        echo "Build:";        echo "Release — ${BUILD_RESULT}"; echo
        echo "Audio:"
        echo "Audio backend detected: ${AUDIO_BACKEND}"
        echo "ALSA:       ${AUDIO_ALSA}"
        echo "JACK:       ${AUDIO_JACK}"
        echo "PipeWire:   ${AUDIO_PIPEWIRE}"
        echo "PulseAudio: ${AUDIO_PULSE}"
        echo
        echo "USB:"
        echo "Audio:     ${USB_AUDIO_LIST:-niciunul}"
        echo "MIDI/HID:  ${USB_MIDI_LIST:-niciunul}"
        echo "Access:    ${USB_ACCESS}"
        echo
        echo "Installation:"; echo "${status}"; echo
        echo "Executable:";   echo "${INSTALLED_BIN:-${INSTALL_PREFIX}/bin/mixxx}$( (( MIXXX_STARTED )) && echo ' (pornit acum ca utilizator normal)')"; echo
        echo "Source / Build:"; echo "${SRC_DIR} / ${BUILD_DIR}"; echo
        echo "Log:";          echo "${LOG_FILE}"
        if [[ "${status}" == FAILED* ]]; then
            echo
            echo "---- Error details ----"
            echo "Stage:     ${CURRENT_STAGE}"
            echo "Command:   ${FAILED_COMMAND:-?}"
            echo "Exit code: ${FAILED_EXIT_CODE}"
            echo "Message:   ${FAILED_MESSAGE:-vezi logul}"
            echo "Directorul build/ și sursele au fost păstrate pentru depanare."
        fi
        if (( ${#SUMMARY_ACTIONS[@]} )); then
            echo; echo "---- Operațiuni ----"; printf ' - %s\n' "${SUMMARY_ACTIONS[@]}"
        fi
        if (( ${#WARNINGS[@]} )); then
            echo; echo "---- Avertismente (${#WARNINGS[@]}) ----"; printf ' - %s\n' "${WARNINGS[@]}"
        fi
        echo
        echo "========================================"
    )"
    printf '%s\n' "${report}"
    if [[ -n "${LOG_FILE}" && -w "${LOG_FILE}" ]]; then printf '%s\n' "${report}" >>"${LOG_FILE}"; fi
    return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    setup_privileges
    setup_logging

    detect_system                         # 1
    check_repositories                    # 2

    if (( OPT_SYSTEM_INFO )); then        # doar informații: nimic instalat/modificat
        detect_audio
        detect_controllers
        stage "ETAPA 14/14 — Raport final"
        final_report
        return 0
    fi
    if (( OPT_CHECK_DEPS )); then         # doar dependențele
        install_dependencies
        stage "ETAPA 14/14 — Raport final"
        final_report
        return 0
    fi

    update_system                         # 3
    install_dependencies                  # 4
    fetch_sources                         # 5
    configure_build                       # 6
    build_mixxx                           # 7
    remove_temp_swap                      #   swap-ul temporar nu mai e necesar
    install_mixxx                         # 8
    setup_desktop_entry                   # 9
    detect_audio                          # 10
    detect_controllers                    # 11
    final_verification                    # 12
    print_audio_recommendations
    maybe_launch_mixxx                    # 13
    stage "ETAPA 14/14 — Raport final"
    final_report                          # 14
}

# "exit" pe aceeași linie: bash nu mai citește din fișier după main, chiar dacă
# scriptul este înlocuit (ex. git pull) în timp ce rulează.
main "$@"; exit "$?"
