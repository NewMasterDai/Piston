#!/usr/bin/env bash
# --- Execution hardening -----------------------------------------------------
set -Eeuo pipefail          # -E: ERR trap inherits into functions/subshells
IFS=$'\n\t'                 # no space-splitting; quote and use arrays anyway
umask 022                   # predictable file modes for anything we create

readonly SCRIPT_NAME="deck-updater"
readonly SCRIPT_VERSION="0.1.0"
readonly LOCK_FILE="/run/${SCRIPT_NAME}.lock"
readonly STATE_DIR="/var/log/${SCRIPT_NAME}"           # /var persists on SteamOS
readonly GL_REF="it.mijorus.gearlever"                  # Gear Lever flatpak id
readonly KEEP_LOGS=14                                    # rotate after N logs

# Timeouts (seconds) for external operations — env-overridable.
T_NET_SMALL="${DECK_UPDATER_T_NET_SMALL:-120}"   # quick queries, pgrep, etc.
T_FLATPAK="${DECK_UPDATER_T_FLATPAK:-3600}"      # flatpak update pass
T_APPIMAGE="${DECK_UPDATER_T_APPIMAGE:-900}"     # per-AppImage Gear Lever pass
T_STEAMOS="${DECK_UPDATER_T_STEAMOS:-7200}"      # full A/B image update

# --- Globals -------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
MODE="menu"            # menu | all | os | flatpak | appimage | reset
UI_BACKEND="text"      # whiptail | gum | text (detected at runtime)
LOG_FILE=""            # set by init_logging; log() degrades to plain echo before
TARGET_USER=""         # the human user (deck) whose flatpaks/AppImages we touch

# --- Small primitives ----------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — updater for SteamOS (immutable-safe)

Updates SteamOS (A/B image), Flatpaks (user + system), and AppImages (Gear Lever).
Never uses pacman. Touches nothing under /usr.

Usage: sudo ./${SCRIPT_NAME}.sh [OPTIONS] [TARGET]

Options:
  --dry-run        Print every mutation, execute none. Use this first.
  --yes, -y        Non-interactive: accept confirmations (incl. defaults-to-No)
  --help, -h       This text.

Targets (skip the interactive menu):
  --all            Everything: flatpaks, AppImages, then SteamOS (reboot prompt)
  --flatpak        Flatpaks only (user + system)
  --appimage       AppImages only (Gear Lever CLI)
  --os             SteamOS A/B update only (via steamos-update-os)
  --reset          Remove this tool's logs/state. Undoes nothing on the system,
                   because this tool never mutates system state directly.

Environment overrides: DECK_UPDATER_T_{NET_SMALL,FLATPAK,APPIMAGE,STEAMOS}
EOF
}

# log LEVEL MESSAGE... — timestamped, to terminal and logfile (if initialised).
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" | tee -a "$LOG_FILE"
    else
        printf '%s\n' "$line"
    fi
}

die() { log "FATAL" "$*"; exit 1; }
warn() { log "WARN" "$*"; }
note() { log "INFO" "$*"; }

# run TIMEOUT CMD ARGS... — the ONE gateway for external commands.
# Echoes the command before executing (audit trail), enforces a timeout,
# streams output to terminal+log, and returns the command's real exit code
# (checked explicitly by callers — set -e alone is not trusted here).
run() {
    local timeout_s="$1"; shift
    log "RUN" "$(printf '%q ' "$@")"
    if (( DRY_RUN )); then
        log "DRY" "skipped: --dry-run is active (no mutation performed)"
        return 0
    fi
    set +e
    timeout "$timeout_s" "$@" 2>&1 | tee -a "$LOG_FILE" 2>/dev/null || true
    local rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" -eq 124 ]]; then
        warn "command timed out after ${timeout_s}s: $*"
    elif [[ "$rc" -ne 0 ]]; then
        warn "command exited with status ${rc}: $*"
    fi
    return "$rc"
}

# run_user TIMEOUT CMD ARGS... — same contract as run(), as the target user.
run_user() {
    local timeout_s="$1"; shift
    if command -v runuser >/dev/null 2>&1; then
        run "$timeout_s" runuser -u "$TARGET_USER" -- "$@"
    else
        run "$timeout_s" sudo -u "$TARGET_USER" -- "$@"
    fi
}

# capture TIMEOUT CMD ARGS... — stdout captured into $RESULT, stderr to log.
capture() {
    local timeout_s="$1"; shift
    log "RUN" "(capture) $(printf '%q ' "$@")"
    set +e
    RESULT="$(timeout "$timeout_s" "$@" 2>>"${LOG_FILE:-/dev/null}")"
    local rc=$?
    set -e
    if (( rc )); then
        warn "captured command exited with status ${rc}: $*"
    fi
    return "$rc"
}

# --- TUI layer (swappable backend: whiptail > gum > plain text) -----------------

ui_detect() {
    if command -v whiptail >/dev/null 2>&1; then
        UI_BACKEND="whiptail"
    elif command -v gum >/dev/null 2>&1; then
        UI_BACKEND="gum"
    else
        UI_BACKEND="text"
    fi
    note "UI backend: ${UI_BACKEND}"
}

# ui_confirm MESSAGE [ACTION_TEXT] — returns 0 if yes, 1 if no. Defaults to NO.
ui_confirm() {
    local msg="$1"
    if (( ASSUME_YES )); then note "confirm (auto): ${msg}"; return 0; fi
    case "$UI_BACKEND" in
        whiptail)
            # 3>&1 1>&2 2>&3: UI draws on the terminal, result comes back to us.
            whiptail --title "${SCRIPT_NAME}" --yesno "$msg" \
                     --defaultno --yes-button " Yes " --no-button " No " \
                     12 70 3>&1 1>&2 2>&3 3>&-
            ;;
        gum)  gum confirm "$msg" 2>/dev/null ;;
        text)
            local reply=""
            read -r -p "${msg} [y/N] " reply
            [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
            ;;
    esac
}

# ui_msg MESSAGE — informational, dismissible.
ui_msg() {
    local msg="$1"
    case "$UI_BACKEND" in
        whiptail) whiptail --title "${SCRIPT_NAME}" --scrolltext --msgbox "$msg" 16 76 3>&1 1>&2 2>&3 3>&- ;;
        gum)      printf '%s\n' "$msg" | gum pager 2>/dev/null || printf '%s\n' "$msg" ;;
        text)     printf '%s\n' "$msg" ;;
    esac
}

# ui_menu TITLE DESC ITEM_TAG ITEM_LABEL ... -> echoes the chosen tag.
# Selections only — the user never types free text.
ui_menu() {
    local title="$1" desc="$2"; shift 2
    local -a args=()
    case "$UI_BACKEND" in
        whiptail)
            local choice=""
            choice="$(whiptail --title "${title}" --menu "${desc}" \
                        16 76 8 "$@" 3>&1 1>&2 2>&3 3>&-)" || return 1
            printf '%s\n' "$choice"
            ;;
        gum)
            local -a labels=() tags=()
            local i tag label
            local -a all=("$@")
            for (( i=0; i<${#all[@]}; i+=2 )); do
                tags+=("${all[$i]}"); labels+=("${all[$((i+1))]}")
            done
            local sel=""
            sel="$(gum choose --header "${desc}" "${labels[@]}" 2>/dev/null)" || return 1
            for (( i=0; i<${#labels[@]}; i++ )); do
                [[ "${labels[$i]}" == "$sel" ]] && { printf '%s\n' "${tags[$i]}"; return 0; }
            done
            return 1
            ;;
        text)
            local -a pairs=()
            local n=1 idx pick pair
            pairs=("$@")
            printf '%s\n' "--- ${title} ---"
            for (( idx=0; idx<${#pairs[@]}; idx+=2 )); do
                printf '  %d) %s\n' "$n" "${pairs[$((idx+1))]}"; n=$((n+1))
            done
            read -r -p "Choice [1-$((n-1))] (blank=quit): " pick
            [[ "$pick" =~ ^[0-9]+$ ]] || return 1
            (( pick >= 1 && pick <= n-1 )) || return 1
            printf '%s\n' "${pairs[$(( (pick-1)*2 ))]}"
            ;;
    esac
}

# --- Environment guards ---------------------------------------------------------

require_bash5() {
    if (( BASH_VERSINFO[0] < 5 )); then
        printf 'FATAL: bash 5.x required (found %s). Run with: bash %s\n' \
               "${BASH_VERSION}" "$0" >&2
        exit 1
    fi
}

reexec_as_root() {
    # Script runs many privileged ops; escalate once, transparently, keeping args.
    if [[ ${EUID} -ne 0 ]]; then
        exec sudo "$0" "$@"        # preserve env: whiptail/newt use /dev/tty
    fi
}

require_stamos() {
    # SteamOS-only. Refuse anywhere else — behaviours below are Valve-specific.
    [[ -r /etc/steamos-release ]] || die "Refusing to run: /etc/steamos-release not found (not SteamOS)."
}

pick_target_user() {
    # Flatpak user installs and Gear Lever data live in the human user's home.
    if [[ -n "${SUDO_USER}" ]]; then
        TARGET_USER="${SUDO_USER}"
    elif getent passwd deck >/dev/null 2>&1; then
        TARGET_USER="deck"
    else
        die "Could not identify the target user (no \$SUDO_USER, no 'deck')."
    fi
    getent passwd "$TARGET_USER" >/dev/null 2>&1 \
        || die "Target user '${TARGET_USER}' does not exist."
    note "target user: ${TARGET_USER}"
}

open_lock() {
    exec 9>"${LOCK_FILE}" || die "cannot open lock file ${LOCK_FILE}"
    if ! flock -n 9; then
        die "Another ${SCRIPT_NAME} instance holds ${LOCK_FILE}. Aborting."
    fi
}

warn_if_steam_running() {
    # An OS image update requires a reboot; a live session deserves a heads-up.
    if timeout "$T_NET_SMALL" pgrep -x steam >/dev/null 2>&1; then
        warn "Steam is currently running."
        ui_confirm "Steam is running. An OS update will ask you to reboot afterwards (save your games). Continue?" \
            || die "Aborted: Steam session active."
    fi
}

init_logging() {
    mkdir -p "$STATE_DIR" || die "cannot create ${STATE_DIR}"
    LOG_FILE="${STATE_DIR}/update-$(date '+%Y%m%d-%H%M%S').log"
    ln -sfn "$LOG_FILE" "${STATE_DIR}/current.log"
    # Rotate: keep newest KEEP_LOGS logs (deletion is a list of our own files only).
    local -a old=()
    mapfile -t old < <(find "$STATE_DIR" -maxdepth 1 -type f \
                      -name 'update-*.log' -printf '%T@ %p\n' 2>/dev/null \
                      | sort -rn | tail -n +"$((KEEP_LOGS + 1))" \
                      | while read -r _ p; do printf '%s\n' "$p"; done)
    local f
    for f in "${old[@]:-}"; do
        [[ -n "$f" ]] && rm -f -- "$f"
    done
    note "logging to ${LOG_FILE}"
    note "dry-run: $(( DRY_RUN ? 1 : 0 ))  target mode: ${MODE}"
}

# Traps: ERR logs the failing line; EXIT reports final status and syncs the log.
set_traps() {
    trap 'log "ERROR" "unhandled failure (status $?) near line ${BASH_LINENO[0]}"' ERR
    trap '
        rc=$?
        trap - ERR EXIT
        log "INFO" "finished, exit status ${rc}"
        sync
        exit "$rc"
    ' EXIT
}

# --- Feature: Flatpak updates ----------------------------------------------------

update_flatpaks() {
    if ! command -v flatpak >/dev/null 2>&1; then
        warn "flatpak not found — skipping Flatpak pass."; return 0
    fi
    note "== Flatpaks =="

    # Per-user installation (where most Deck apps live)
    run_user "$T_FLATPAK" flatpak update --user --noninteractive -y \
        || warn "some user flatpaks may not have updated"

    # System-wide installation (Discover defaults to this on Deck)
    run "$T_FLATPAK" flatpak update --system --noninteractive -y \
        || warn "some system flatpaks may not have updated"

    # Post-change verification: a satisfied installation reports nothing to do.
    capture "$T_NET_SMALL" runuser -u "$TARGET_USER" -- flatpak update --user
    [[ -z "$RESULT" || "$RESULT" == *"Nothing to do"* || "$RESULT" == *"No updates"* ]] \
        && note "verify(user): up to date" || warn "verify(user): leftover output — check log"

    # Housekeeping (destructive-ish -> explicit confirm, defaults to No)
    if ui_confirm "Remove unused Flatpak runtimes/extensions? (optional)"; then
        run_user "$T_FLATPAK" flatpak uninstall --user --unused --noninteractive \
            || warn "user unused-uninstall incomplete"
        run "$T_FLATPAK" flatpak uninstall --system --unused --noninteractive \
            || warn "system unused-uninstall incomplete"
    fi
}

# --- Feature: AppImage updates (Gear Lever CLI, >= 3.0.0) ------------------------

update_appimages() {
    note "== AppImages (Gear Lever) =="

    # Engine present?
    capture "$T_NET_SMALL" runuser -u "$TARGET_USER" -- flatpak info "$GL_REF"
    if (( $? != 0 )); then
        warn "Gear Lever (${GL_REF}) not installed — skipping AppImage pass."
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found (needed to parse Gear Lever's JSON safely) — skipping."
        return 0
    fi

    # Read-only inventory — runs even in --dry-run so we can show real work.
    capture "$T_NET_SMALL" runuser -u "$TARGET_USER" -- \
        flatpak run "$GL_REF" --list-updates --json
    if (( $? != 0 )); then
        warn "Gear Lever could not list updates (GUI version may predate its CLI). Skipping."
        return 0
    fi
    printf '%s\n' "$RESULT" >>"${LOG_FILE}"   # audit: raw JSON in the log

    local -a names=()
    local rc=0
    mapfile -t names < <(printf '%s\n' "$RESULT" \
        | jq -r '(.updates // [])[] | (.name // .path // empty)') || rc=$?
    if (( rc != 0 )) || (( ${#names[@]} == 0 )); then
        note "no AppImage updates available."
        return 0
    fi

    note "${#names[@]} AppImage update(s) available:"
    local n
    for n in "${names[@]}"; do note "  - ${n}"; done

    if ! ui_confirm "Update these AppImages via Gear Lever?"; then
        note "AppImage pass declined."; return 0
    fi

    local failed=0
    for n in "${names[@]}"; do
        # Gear Lever itself is transactional: it keeps the previous version,
        # verifies the new download, and can restore — that contract is respected
        # here, not reimplemented badly. Failure is logged, not fatal.
        run_user "$T_APPIMAGE" flatpak run "$GL_REF" --update "$n" \
            || { warn "AppImage update failed: ${n}"; failed=$((failed+1)); }
    done
    (( failed == 0 )) && note "AppImage pass complete." \
                       || warn "${failed} AppImage update(s) failed (previous versions retained)."
    return 0
}

# --- Feature: SteamOS A/B image update -------------------------------------------

update_os() {
    note "== SteamOS (A/B image update) =="
    if ! command -v steamos-update-os >/dev/null 2>&1; then
        die "steamos-update-os not found. On your SteamOS build the supported CLI entry point is missing — do NOT substitute steamos-update/pacman. Update from Game Mode's Settings > System instead, or investigate your OS version."
    fi

    warn_if_steam_running

    # Valve's transaction: it stages the update onto the inactive partition,
    # verifies it, flips the boot slot, and keeps the old image as rollback.
    # We deliberately do not reimplement any of that. 'now' = update in place
    # with a reboot prompt at the end (the other mode is scheduled at reboot
    # via steamos-set-bootmode — out of scope here).
    run "$T_STEAMOS" steamos-update-os now \
        || die "SteamOS update failed. The A/B layout keeps your current image; nothing was lost. Check ${LOG_FILE}."

    note "SteamOS image update complete."
    if ui_confirm "Reboot now to finish the update? (unsaved work will be lost)"; then
        run "$T_NET_SMALL" systemctl --no-block reboot
        note "Reboot requested — goodbye."
        exit 0
    fi
    note "Reboot when convenient; the new image boots on the next start."
}

# --- Feature: reset (this tool's footprint only) ----------------------------------

reset_state() {
    note "== Reset tool state =="
    # Honesty clause: this script never edits system files directly, so there is
    # nothing of Valve's to restore. Its only footprint is its own log dir.
    ui_confirm "Delete ALL logs under ${STATE_DIR}? (irreversible)" \
        || die "Reset cancelled."
    run "$T_NET_SMALL" rm -rf -- "$STATE_DIR" \
        || die "could not remove ${STATE_DIR}"
    note "Tool state cleared. The system itself was never touched."
}

# --- Orchestrators --------------------------------------------------------------

update_all() {
    note "===== FULL PASS ====="
    update_flatpaks
    update_appimages
    update_os
    note "===== FULL PASS COMPLETE ====="
}

dispatch_mode() {
    case "$MODE" in
        all)      update_all ;;
        os)       update_os ;;
        flatpak)  update_flatpaks ;;
        appimage) update_appimages ;;
        reset)    reset_state ;;
        *)        return 1 ;;   # menu handled by caller
    esac
    return 254   # dispatched
}

main_menu() {
    local choice
    while true; do
        choice="$(ui_menu "${SCRIPT_NAME}" \
            "Select an operation. (v${SCRIPT_VERSION})\nDry-run: $(( DRY_RUN ? 1 : 0 ))" \
            "all"      "Update EVERYTHING (recommended)" \
            "os"       "Update SteamOS only" \
            "flatpak"  "Update Flatpaks only" \
            "appimage" "Update AppImages only (Gear Lever)" \
            "toggle"   "Toggle dry-run (currently: $(( DRY_RUN ? 1 : 0 )))" \
            "log"      "Show current log path" \
            "reset"    "Reset tool state (clear logs)" \
            "exit"     "Quit" )" || { note "bye."; return 0; }
        case "$choice" in
            all)      update_all ;;
            os)       update_os ;;
            flatpak)  update_flatpaks ;;
            appimage) update_appimages ;;
            toggle)   if (( DRY_RUN )); then DRY_RUN=0; else DRY_RUN=1;
                          note "dry-run toggled; logging will resume on next run line"; fi
                      # restart logging so toggled state is recorded
                      init_logging ;;
            log)      ui_msg "Log: ${LOG_FILE}\nTail it with: tail -f ${STATE_DIR}/current.log" ;;
            reset)    reset_state ;;
            exit)     note "bye."; return 0 ;;
            *)        warn "unreachable menu tag" ;;
        esac
    done
}

parse_args() {
    # Whitelist, don't blacklist: unknown anything => hard stop.
    while (( $# )); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  ASSUME_YES=1 ;;
            --help|-h) usage; exit 0 ;;
            --all)     MODE="all" ;;
            --os)      MODE="os" ;;
            --flatpak) MODE="flatpak" ;;
            --appimage) MODE="appimage" ;;
            --reset)   MODE="reset" ;;
            *) usage >&2; printf '\nFATAL: unknown argument: %s\n' "$1" >&2; exit 2 ;;
        esac
        shift
    done
    if [[ "$MODE" == "all" || "$MODE" == "os" ]] && (( ! ASSUME_YES )) && [[ ! -t 0 ]]; then
        # Reboot-class action driven non-interactively without --yes: demand clarity.
        :
    fi
}

main() {
    require_bash5
    parse_args "$@"
    require_stamos          # refuse anywhere else, before any privilege use
    reexec_as_root "$@"     # then re-parse identically as root below

    init_logging
    set_traps
    open_lock
    ui_detect
    pick_target_user

    # Immutable-root tripwire: if this tool ever finds itself about to touch
    # /usr or use pacman, that code does not exist yet — and it must not. Any
    # future contribution violating this must be rejected at review.
    if command -v pacman >/dev/null 2>&1; then
        note "pacman detected on PATH (normal on SteamOS) — it will NOT be used."
    fi

    dispatch_mode && return 0 || true
    # MODE was "menu":
    main_menu
}

main "$@"

