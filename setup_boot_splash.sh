#!/usr/bin/env bash
# =============================================================================
#  setup_boot_splash.sh
#
#  Splash screen personalizat la pornire (Plymouth) + ascunderea textului de boot
#  pe Raspberry Pi 5 cu Debian 13 Trixie / Raspberry Pi OS.
#
#  Ce face:
#    1. instalează Plymouth (pachet Debian oficial) și creează tema "mixxx-splash"
#       care afișează imaginea centrată, scalată pe ecran, pe fundal negru;
#    2. în cmdline.txt: "quiet splash", loglevel=3, fără logo-urile Raspberry Pi,
#       fără cursor, consola mutată de pe tty1 pe tty3 (textul de boot nu se vede);
#    3. în config.txt: disable_splash=1 (fără ecranul curcubeu al firmware-ului).
#
#  Siguranță:
#    - fișierele originale sunt salvate O SINGURĂ DATĂ în /var/lib/mixxx-installer/splash;
#    - --dry-run arată modificările fără a schimba nimic;
#    - --revert restaurează cmdline.txt, config.txt și tema Plymouth anterioară.
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="setup_boot_splash.sh"
readonly THEME_NAME="mixxx-splash"
readonly THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"
readonly STATE_DIR="/var/lib/mixxx-installer/splash"
readonly PLYMOUTHD_CONF="/etc/plymouth/plymouthd.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Parametri adăugați în cmdline.txt (consola rămâne activă pe tty3, pentru depanare)
readonly -a CMDLINE_ADD=(quiet splash loglevel=3 logo.nologo vt.global_cursor_default=0 plymouth.ignore-serial-consoles)

OPT_DRY_RUN=0; OPT_REVERT=0; OPT_YES=0
IMAGE="${SCRIPT_DIR}/assets/splash.png"
BOOT_DIR=""

if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
info()  { printf '%s[INFO]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s[OK]%s %s\n'      "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%s[WARNING]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()   { printf '%s[ERROR]%s %s\n'   "${C_RED}"    "${C_RESET}" "$1" >&2; [[ -n "${2:-}" ]] && printf '        -> %s\n' "$2" >&2; exit 1; }
trap 'printf "%s[ERROR]%s Comanda a eșuat (linia %s): %s\n" "${C_RED}" "${C_RESET}" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

# Execută o comandă care modifică sistemul (în dry-run doar o afișează)
run() {
    if (( OPT_DRY_RUN )); then printf '%s[DRY-RUN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(printf '%q ' "$@")"; return 0; fi
    "$@"
}

# Scrie conținut într-un fișier (în dry-run doar îl afișează)
write_file() {
    local dest="$1" content="$2" mode="${3:-644}"
    if (( OPT_DRY_RUN )); then
        printf '%s[DRY-RUN]%s scriere %s:\n%s\n' "${C_YELLOW}" "${C_RESET}" "${dest}" "$(sed 's/^/    | /' <<<"${content}")"
        return 0
    fi
    printf '%s\n' "${content}" >"${dest}"
    # Partiția de boot e FAT (vfat): acolo chmod nu are sens și poate eșua
    [[ -n "${mode}" ]] && chmod "${mode}" "${dest}"
    return 0
}

usage() {
    cat <<EOF
${SCRIPT_NAME} — splash screen la pornire + ascunderea textului de boot

Utilizare:
  sudo ./${SCRIPT_NAME}                 activează (imagine: assets/splash.png)
  sudo ./${SCRIPT_NAME} --image FILE    activează cu altă imagine PNG
  sudo ./${SCRIPT_NAME} --revert        revine la configurația de dinainte
  ./${SCRIPT_NAME} --dry-run            arată ce s-ar schimba, fără modificări

Opțiuni: --image FILE, --dry-run, --revert, -y/--yes, --help
Modificările devin vizibile după repornire (sudo reboot).
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --help|-h)  usage; exit 0 ;;
            --dry-run)  OPT_DRY_RUN=1 ;;
            --revert)   OPT_REVERT=1 ;;
            --yes|-y)   OPT_YES=1 ;;
            --image)    [[ $# -ge 2 ]] || die "--image necesită o cale către un fișier PNG"; IMAGE="$2"; shift ;;
            --image=*)  IMAGE="${1#*=}" ;;
            *)          die "Opțiune necunoscută: $1" "Vezi: ./${SCRIPT_NAME} --help" ;;
        esac
        shift
    done
}

ask_yes_no() {
    local reply
    (( OPT_YES || OPT_DRY_RUN )) && return 0
    { : </dev/tty; } 2>/dev/null || return 1
    read -r -p "[?] $1 [y/N] " reply </dev/tty || reply=""
    [[ "${reply,,}" =~ ^(y|yes|d|da)$ ]]
}

# /boot/firmware pe Debian 12+/Trixie, /boot pe sisteme mai vechi.
# SPLASH_BOOT_DIR permite testarea pe o copie a partiției de boot.
detect_boot_dir() {
    if [[ -n "${SPLASH_BOOT_DIR:-}" ]]; then
        BOOT_DIR="${SPLASH_BOOT_DIR}"
    elif [[ -f /boot/firmware/cmdline.txt ]]; then
        BOOT_DIR="/boot/firmware"
    elif [[ -f /boot/cmdline.txt ]]; then
        BOOT_DIR="/boot"
    else
        die "Nu găsesc cmdline.txt în /boot/firmware sau /boot." "Scriptul este pentru Raspberry Pi."
    fi
    [[ -f "${BOOT_DIR}/cmdline.txt" ]] || die "${BOOT_DIR}/cmdline.txt lipsește."
    [[ -f "${BOOT_DIR}/config.txt" ]] || die "${BOOT_DIR}/config.txt lipsește."
    (( $(grep -cv '^[[:space:]]*$' "${BOOT_DIR}/cmdline.txt") == 1 )) \
        || die "${BOOT_DIR}/cmdline.txt trebuie să conțină o singură linie; nu îl modific." "Verifică manual fișierul."
    ok "Partiția de boot: ${BOOT_DIR}"
}

# Salvează o singură dată originalele (rularea repetată nu suprascrie copia)
backup_originals() {
    run mkdir -p "${STATE_DIR}"
    local f
    for f in cmdline.txt config.txt; do
        if [[ -f "${STATE_DIR}/${f}.orig" ]]; then
            info "Copia originală există deja: ${STATE_DIR}/${f}.orig"
        else
            run cp -- "${BOOT_DIR}/${f}" "${STATE_DIR}/${f}.orig"
            ok "Copie de siguranță: ${STATE_DIR}/${f}.orig"
        fi
    done
    # plymouthd.conf (folosit dacă plymouth-set-default-theme nu există); "absent" = nu exista
    if [[ ! -e "${STATE_DIR}/plymouthd.conf.orig" && ! -e "${STATE_DIR}/plymouthd.conf.absent" ]]; then
        if [[ -f "${PLYMOUTHD_CONF}" ]]; then
            run cp -- "${PLYMOUTHD_CONF}" "${STATE_DIR}/plymouthd.conf.orig"
        else
            run touch "${STATE_DIR}/plymouthd.conf.absent"
        fi
    fi
    if [[ ! -f "${STATE_DIR}/previous-theme" ]]; then
        local prev
        prev="$(current_theme)"
        if [[ -n "${prev}" && "${prev}" != "${THEME_NAME}" ]]; then
            write_file "${STATE_DIR}/previous-theme" "${prev}"
            info "Tema Plymouth anterioară: ${prev}"
        fi
    fi
}

install_plymouth() {
    if dpkg-query -W -f='${Status}' plymouth 2>/dev/null | grep -q 'install ok installed'; then
        ok "Plymouth este deja instalat."
    else
        info "Instalez Plymouth (pachet Debian oficial)..."
        run apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends plymouth \
            || die "Instalarea plymouth a eșuat." "Rulează 'sudo apt update' și încearcă din nou."
    fi
}

# Tema Plymouth activă: plymouth-set-default-theme (Debian) sau cheia Theme= din config
current_theme() {
    local t=""
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        t="$(plymouth-set-default-theme 2>/dev/null || true)"
    fi
    if [[ -z "${t}" ]]; then
        t="$(awk -F= '/^[[:space:]]*Theme[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' \
            "${PLYMOUTHD_CONF}" /usr/share/plymouth/plymouthd.defaults 2>/dev/null | head -n1 || true)"
    fi
    printf '%s' "${t}"
}

# Setează tema: prin plymouth-set-default-theme dacă există, altfel în plymouthd.conf
set_theme() {
    local theme="$1" content
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        run plymouth-set-default-theme "${theme}"
        return 0
    fi
    if [[ -f "${PLYMOUTHD_CONF}" ]] && grep -q '^\[Daemon\]' "${PLYMOUTHD_CONF}"; then
        content="$(awk -v t="${theme}" '
            /^\[Daemon\]/ {print; print "Theme=" t; d=1; next}
            /^\[/ {d=0}
            d && /^[[:space:]]*Theme[[:space:]]*=/ {next}
            {print}' "${PLYMOUTHD_CONF}")"
    else
        content="$( [[ -f "${PLYMOUTHD_CONF}" ]] && cat "${PLYMOUTHD_CONF}"; printf '[Daemon]\nTheme=%s' "${theme}")"
    fi
    run install -d -m 755 "$(dirname "${PLYMOUTHD_CONF}")"
    write_file "${PLYMOUTHD_CONF}" "${content}" 644
}

create_theme() {
    info "Creez tema Plymouth '${THEME_NAME}' în ${THEME_DIR}"
    run install -d -m 755 "${THEME_DIR}"
    run install -m 644 -- "${IMAGE}" "${THEME_DIR}/splash.png"
    write_file "${THEME_DIR}/${THEME_NAME}.plymouth" "[Plymouth Theme]
Name=Mixxx splash
Description=Imagine personalizată la pornire (creată de ${SCRIPT_NAME})
ModuleName=script

[script]
ImageDir=${THEME_DIR}
ScriptFile=${THEME_DIR}/${THEME_NAME}.script"
    # Imaginea e scalată proporțional ca să încapă pe ecran și centrată pe fundal negru
    write_file "${THEME_DIR}/${THEME_NAME}.script" 'Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);

logo.image = Image("splash.png");
screen_w = Window.GetWidth();
screen_h = Window.GetHeight();
scale = Math.Min(screen_w / logo.image.GetWidth(), screen_h / logo.image.GetHeight());
logo.scaled = logo.image.Scale(logo.image.GetWidth() * scale, logo.image.GetHeight() * scale);
logo.sprite = Sprite(logo.scaled);
logo.sprite.SetX(Window.GetX() + screen_w / 2 - logo.scaled.GetWidth() / 2);
logo.sprite.SetY(Window.GetY() + screen_h / 2 - logo.scaled.GetHeight() / 2);
logo.sprite.SetZ(10);'
}

# Activează tema și regenerează initramfs (Plymouth pornește din initramfs pe Raspberry Pi)
activate_theme() {
    local theme="$1"
    set_theme "${theme}"
    ok "Tema Plymouth activă: ${theme}"
    if compgen -G "${BOOT_DIR}/initramfs*" >/dev/null || grep -qsE '^[[:space:]]*auto_initramfs=1' "${BOOT_DIR}/config.txt"; then
        info "Regenerez initramfs (poate dura 1-2 minute)..."
        run update-initramfs -u || die "update-initramfs a eșuat." "Verifică spațiul din ${BOOT_DIR} (df -h ${BOOT_DIR})."
        ok "initramfs actualizat."
    else
        warn "Nu văd un initramfs în ${BOOT_DIR}: splash-ul va apărea puțin mai târziu în procesul de boot."
    fi
}

edit_cmdline() {
    local file="${BOOT_DIR}/cmdline.txt" line new tok
    local -a words=() out=()
    line="$(grep -v '^[[:space:]]*$' "${file}")"
    read -r -a words <<<"${line}"
    for tok in "${words[@]}"; do
        # Consola text pe tty3: mesajele de boot nu mai apar pe ecran, dar rămân în jurnal
        [[ "${tok}" == "console=tty1" ]] && tok="console=tty3"
        out+=("${tok}")
    done
    for tok in "${CMDLINE_ADD[@]}"; do
        [[ " ${out[*]} " == *" ${tok} "* ]] || out+=("${tok}")
    done
    new="${out[*]}"
    if [[ "${new}" == "${line}" ]]; then
        ok "cmdline.txt este deja configurat."
        return 0
    fi
    info "cmdline.txt:"
    printf '    înainte: %s\n    după:    %s\n' "${line}" "${new}"
    write_file "${file}" "${new}" ""
    ok "cmdline.txt actualizat."
}

edit_config() {
    local file="${BOOT_DIR}/config.txt"
    if grep -qE '^[[:space:]]*disable_splash[[:space:]]*=[[:space:]]*1' "${file}"; then
        ok "config.txt: disable_splash=1 este deja setat."
        return 0
    fi
    info "config.txt: adaug disable_splash=1 (fără ecranul curcubeu)"
    if (( OPT_DRY_RUN )); then
        printf '%s[DRY-RUN]%s adăugare la %s: [all] / disable_splash=1\n' "${C_YELLOW}" "${C_RESET}" "${file}"
    else
        printf '\n# Adăugat de %s: fără ecranul curcubeu la pornire\n[all]\ndisable_splash=1\n' "${SCRIPT_NAME}" >>"${file}"
    fi
    ok "config.txt actualizat."
}

enable_splash() {
    [[ -f "${IMAGE}" ]] || die "Imaginea nu există: ${IMAGE}" "Folosește --image /cale/catre/imagine.png"
    file -b "${IMAGE}" | grep -q '^PNG image' || die "Imaginea trebuie să fie PNG: ${IMAGE}" "Convertește-o în PNG și încearcă din nou."
    ok "Imagine: ${IMAGE} ($(file -b "${IMAGE}" | cut -d, -f2 | xargs))"

    info "Voi modifica: ${BOOT_DIR}/cmdline.txt, ${BOOT_DIR}/config.txt și tema Plymouth (cu copii de siguranță)."
    ask_yes_no "Continui?" || die "Anulat de utilizator."

    backup_originals
    install_plymouth
    create_theme
    activate_theme "${THEME_NAME}"
    edit_cmdline
    edit_config

    echo
    ok "Splash screen configurat. Repornește pentru a-l vedea: sudo reboot"
    info "Revenire oricând la configurația anterioară: sudo ./${SCRIPT_NAME} --revert"
}

revert_splash() {
    local f prev=""
    [[ -d "${STATE_DIR}" ]] || die "Nu există copii de siguranță în ${STATE_DIR}; nimic de restaurat."
    ask_yes_no "Restaurez cmdline.txt, config.txt și tema Plymouth anterioară?" || die "Anulat de utilizator."
    for f in cmdline.txt config.txt; do
        if [[ -f "${STATE_DIR}/${f}.orig" ]]; then
            # cp fără -a: vfat nu păstrează proprietar/permisiuni
            run cp -- "${STATE_DIR}/${f}.orig" "${BOOT_DIR}/${f}"
            ok "Restaurat: ${BOOT_DIR}/${f}"
        fi
    done
    # Configurația Plymouth: fișierul original sau ștergerea celui creat de noi
    if [[ -f "${STATE_DIR}/plymouthd.conf.orig" ]]; then
        run cp -- "${STATE_DIR}/plymouthd.conf.orig" "${PLYMOUTHD_CONF}"
    elif [[ -f "${STATE_DIR}/plymouthd.conf.absent" && -f "${PLYMOUTHD_CONF}" ]]; then
        run rm -f -- "${PLYMOUTHD_CONF}"
    fi
    [[ -f "${STATE_DIR}/previous-theme" ]] && prev="$(cat "${STATE_DIR}/previous-theme")"
    if [[ -n "${prev}" ]] && command -v plymouth-set-default-theme >/dev/null 2>&1; then
        run plymouth-set-default-theme "${prev}"
    fi
    info "Tema Plymouth restaurată${prev:+: ${prev}}."
    # Tema noastră se șterge doar dacă e exact directorul creat de acest script
    if [[ -d "${THEME_DIR}" && "${THEME_DIR}" == "/usr/share/plymouth/themes/${THEME_NAME}" ]]; then
        run rm -rf -- "${THEME_DIR}"
        ok "Tema ${THEME_NAME} a fost ștearsă."
    fi
    if (( ! OPT_DRY_RUN )); then
        run rm -f -- "${STATE_DIR}/cmdline.txt.orig" "${STATE_DIR}/config.txt.orig" "${STATE_DIR}/previous-theme" \
            "${STATE_DIR}/plymouthd.conf.orig" "${STATE_DIR}/plymouthd.conf.absent"
    fi
    # initramfs trebuie regenerat și la revenire, ca să nu mai conțină tema ștearsă
    if compgen -G "${BOOT_DIR}/initramfs*" >/dev/null || grep -qsE '^[[:space:]]*auto_initramfs=1' "${BOOT_DIR}/config.txt"; then
        info "Regenerez initramfs..."
        run update-initramfs -u || warn "update-initramfs a eșuat; rulează manual: sudo update-initramfs -u"
    fi
    ok "Configurația de boot a fost restaurată. Repornește: sudo reboot"
}

main() {
    parse_args "$@"
    if (( ! OPT_DRY_RUN )) && (( EUID != 0 )); then
        die "Sunt necesare privilegii root." "Rulează: sudo ./${SCRIPT_NAME}"
    fi
    (( OPT_DRY_RUN )) && warn "Mod DRY-RUN: nimic nu va fi modificat."
    detect_boot_dir
    if (( OPT_REVERT )); then revert_splash; else enable_splash; fi
}

main "$@"; exit "$?"
