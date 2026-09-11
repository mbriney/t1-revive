#!/usr/bin/env bash
# lib/common.sh - logging, redaction, confirm, exit codes, dirs, lock, T1 USB state, diag.
#
# Sourced by bin/t1-revive after T1R_ROOT is resolved. Defines functions and default T1R_*
# variables only; nothing runs at source time. Every function reads only its parameters and
# T1R_* variables so the test suite can point them at fixtures.
#
# shellcheck shell=bash

# ----- exit codes (see AGENTS.md) ------------------------------------------------------
# shellcheck disable=SC2034  # exported for the other libraries
{
  T1R_EX_OK=0; T1R_EX_FAIL=1; T1R_EX_USAGE=2; T1R_EX_PREFLIGHT=3
  T1R_EX_REFUSED=4; T1R_EX_DEVICE=5; T1R_EX_NETWORK=6; T1R_EX_REBOOT=7
}

# ----- paths and switches (all overridable) --------------------------------------------
: "${T1R_ROOT:?T1R_ROOT must be set by bin/t1-revive before sourcing lib/common.sh}"
# T1R_PRESET records which T1R_* the environment or bin/t1-revive's flags set explicitly, so
# that load_conf fills in only the ones that would otherwise keep the default below.
T1R_PRESET=" ${T1R_PRESET:-} "
for _t1r_v in T1R_PREFIX T1R_STATE T1R_LOG T1R_CACHE T1R_CONF T1R_SYSFS T1R_DMI \
              T1R_ACPI_TABLES T1R_LSBLK_JSON T1R_NO_CONFIRM T1R_DEMO T1R_DRY_RUN; do
  [[ -n "${!_t1r_v:-}" ]] && T1R_PRESET="$T1R_PRESET$_t1r_v "
done
unset _t1r_v
if [[ -z "${T1R_PREFIX:-}" ]]; then
  if [[ -d "$T1R_ROOT/prefix" ]]; then T1R_PREFIX=$T1R_ROOT/prefix; else T1R_PREFIX=/usr/lib/t1-revive/prefix; fi
fi
: "${T1R_STATE:=/var/lib/t1-revive}"
: "${T1R_LOG:=/var/log/t1-revive}"
: "${T1R_CACHE:=/var/cache/t1-revive}"
: "${T1R_CONF:=/etc/t1-revive}"
: "${T1R_SYSFS:=/sys}"
: "${T1R_DMI:=$T1R_SYSFS/class/dmi/id}"
: "${T1R_ACPI_TABLES:=$T1R_SYSFS/firmware/acpi/tables}"
: "${T1R_NO_CONFIRM:=0}"
: "${T1R_DEMO:=0}"
: "${T1R_DRY_RUN:=0}"
: "${T1R_COMPONENT:=t1-revive}"
: "${T1R_LOGFILE:=}"
: "${T1R_SCREEN_FD:=}"     # set by open_log: fd that still reaches the terminal
: "${T1R_COLOR:=}"         # 1 when the terminal takes colours (decided in open_log / on demand)
export T1R_ROOT T1R_PREFIX T1R_STATE T1R_LOG T1R_CACHE T1R_CONF T1R_SYSFS T1R_DMI T1R_ACPI_TABLES
export T1R_NO_CONFIRM T1R_DEMO T1R_DRY_RUN T1R_COMPONENT

# ----- output --------------------------------------------------------------------------
# Screen/log model (from one-shot.sh):
#   normal mode: after open_log, stdout+stderr go through `redact | tee LOG`; the screen shows all.
#   demo mode:   after open_log, stdout+stderr go through `redact > LOG`; only show() reaches the
#                screen (fd 3). say/note/warn/die details land in the log only.
_t1r_color() {
  if [[ -z "$T1R_COLOR" ]]; then
    if [[ -t 2 ]] || [[ -t 1 ]]; then T1R_COLOR=1; else T1R_COLOR=0; fi
  fi
  [[ "$T1R_COLOR" = 1 ]]
}

_t1r_screen() {  # print a complete line to the terminal, wherever it is right now
  if [[ -n "$T1R_SCREEN_FD" ]]; then printf '%s\n' "$*" >&"$T1R_SCREEN_FD"; else printf '%s\n' "$*"; fi
}

say() {
  if _t1r_color; then printf '\n\e[1;32m==== %s  (%s)\e[0m\n' "$*" "$(date +%T)" >&2
  else printf '\n==== %s  (%s)\n' "$*" "$(date +%T)" >&2; fi
}

note() { printf '   %s\n' "$*" >&2; }

warn() {
  if _t1r_color; then printf '   \e[33mwarning: %s\e[0m\n' "$*" >&2
  else printf '   warning: %s\n' "$*" >&2; fi
}

# show: a line that always reaches the screen. In demo mode the ordinary output is diverted
# into the log, so it goes to the saved terminal fd; in normal mode it goes through the same
# redact|tee pipeline as everything else, which keeps it in order with say/note/warn.
show() {
  if [[ "$T1R_DEMO" = 1 ]]; then _t1r_screen "$*"; else printf '%s\n' "$*"; fi
}

die() {
  local code=${1:-1}; shift || true
  local msg=$*
  case "$code" in ''|*[!0-9]*) msg="$code $msg"; code=1;; *) ;; esac
  if _t1r_color; then printf '\n\e[31mSTOPPED: %s\e[0m\n' "$msg" >&2; else printf '\nSTOPPED: %s\n' "$msg" >&2; fi
  if [[ "$T1R_DEMO" = 1 ]]; then
    show ""; show "  x step did not complete: $msg"
    [[ -n "$T1R_LOGFILE" ]] && show "    log: $T1R_LOGFILE"
  fi
  diag result=error code="$code"
  exit "$code"
}

confirm() {
  [[ "$T1R_NO_CONFIRM" = 1 ]] && return 0
  [[ "$T1R_DEMO" = 1 ]] && return 0
  # A full line with a newline: the sed|tee filter only passes complete lines.
  show "   >> ${1:-continue?} [Enter to continue, Ctrl-C to stop]"
  if [[ -r /dev/tty ]]; then read -r _ </dev/tty || die 4 "no answer on the terminal; use --no-confirm for unattended runs"
  else read -r _ || die 4 "no terminal to confirm on; use --no-confirm for unattended runs"; fi
  return 0
}

# ----- redaction -----------------------------------------------------------------------
# stdin -> stdout, line-buffered. Order matters: labelled identifiers first, then MACs, then
# long hex runs (ECIDs, nonces, hashes, UDIDs). Serial-looking tokens are 10-12 alphanumerics
# after the word "serial" (any case, optional "number" and separators).
redact() {
  sed -u -E \
    -e 's/\b(ECID|ecid|Ecid)[[:space:]]*[=:]?[[:space:]]*(0x)?[0-9A-Fa-f]+\b/\1=<id>/g' \
    -e 's/(serial[ _-]?(number|no)?[^A-Za-z0-9]{0,6})[A-Za-z0-9]{10,12}\b/\1<id>/gI' \
    -e 's/\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/<mac>/g' \
    -e 's/[0-9A-Fa-f]{16,}/<hex>/g'
}

# ----- diagnostics ---------------------------------------------------------------------
# diag K=V ... : one structured, identifier-free line to the command log, to $T1R_LOG/diagnostics.log
# and to the journal. Values are clamped to [A-Za-z0-9._:-].
diag() {
  local kv line="t1-revive-diagnostic v=1 component=$T1R_COMPONENT" k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    k=$(printf '%s' "$k" | tr -c 'A-Za-z0-9_' '_')
    v=$(printf '%s' "$v" | tr -c 'A-Za-z0-9._:-' '_')
    line="$line $k=$v"
  done
  if [[ -n "$T1R_LOGFILE" ]] && [[ -w "$T1R_LOGFILE" ]]; then printf '%s\n' "$line" >>"$T1R_LOGFILE"; fi
  if [[ -d "$T1R_LOG" ]] && [[ -w "$T1R_LOG" ]]; then printf '%s\n' "$line" >>"$T1R_LOG/diagnostics.log" 2>/dev/null; fi
  command -v logger >/dev/null 2>&1 && logger -t t1-revive -- "$line" 2>/dev/null
  return 0
}

# ----- privileges, dirs, log, lock -----------------------------------------------------
require_root() { [[ "${EUID:-$(id -u)}" = 0 ]] || die 4 "this command needs root: sudo t1-revive ${T1R_CMD:-...}"; }

ensure_dirs() {
  local rc=0
  install -d -m 0700 "$T1R_STATE" 2>/dev/null || rc=1
  install -d -m 0700 "$T1R_LOG" 2>/dev/null || rc=1
  install -d -m 0755 "$T1R_CACHE" 2>/dev/null || rc=1
  return "$rc"
}

# open_log NAME: start the redacted log for this command. Sets T1R_LOGFILE (empty when the
# log directory is not writable, e.g. a status run as a normal user) and T1R_SCREEN_FD=3.
open_log() {
  local name=${1:-run} stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  _t1r_color >/dev/null       # decide colours while fd 1/2 are still the terminal
  if [[ -d "$T1R_LOG" ]] && [[ -w "$T1R_LOG" ]]; then
    T1R_LOGFILE=$T1R_LOG/$name-$stamp.log
    ( umask 077; : >"$T1R_LOGFILE" ) || T1R_LOGFILE=
  fi
  if [[ -z "$T1R_LOGFILE" ]]; then
    if [[ "$T1R_DEMO" = 1 ]]; then
      # demo mode without a log would swallow everything: keep the screen instead
      warn "log directory $T1R_LOG is not writable; demo output stays on screen"
    fi
    return 1
  fi
  ln -sfn "$T1R_LOGFILE" "$T1R_LOG/latest.log" 2>/dev/null
  exec 3>&1
  T1R_SCREEN_FD=3
  if [[ "$T1R_DEMO" = 1 ]]; then
    exec > >(redact >>"$T1R_LOGFILE") 2>&1
  else
    exec > >(redact | tee -a "$T1R_LOGFILE") 2>&1
  fi
  T1R_LOG_PID=$!
  trap 'log_close' EXIT
  printf '# t1-revive %s %s %s\n' "$(version)" "$name" "$(date -Is)" >&2
  return 0
}

# log_close: drain the redaction pipeline (called from the EXIT trap set by open_log; other
# libraries that install their own EXIT trap must call it themselves).
log_close() {
  [[ -n "${T1R_LOG_PID:-}" ]] || return 0
  exec >&3 2>&3 3>&-
  wait "$T1R_LOG_PID" 2>/dev/null
  T1R_LOG_PID=
  T1R_SCREEN_FD=
  return 0
}

lock_acquire() {
  [[ -d "$T1R_STATE" ]] || die 4 "state directory $T1R_STATE does not exist (run ensure_dirs as root)"
  exec 9>>"$T1R_STATE/lock" || die 4 "cannot open $T1R_STATE/lock"
  flock -n 9 || die 4 "another t1-revive run holds $T1R_STATE/lock"
  return 0
}

# ----- T1 USB state (pure: reads $T1R_SYSFS only) --------------------------------------
_t1r_usb_scan() {  # prints "PRODUCT PATH" for each Apple 05ac device that is a T1 personality
  local d v p
  for d in "$T1R_SYSFS"/bus/usb/devices/*; do
    [[ -r "$d/idVendor" ]] || continue
    read -r v <"$d/idVendor" 2>/dev/null || continue
    [[ "$v" = 05ac ]] || continue
    read -r p <"$d/idProduct" 2>/dev/null || continue
    case "$p" in 1281|8600) printf '%s %s\n' "$p" "$d";; *) ;; esac
  done
  return 0
}

t1_state() {
  local r=none line
  while read -r line; do
    case "$line" in 8600\ *) r=booted;; 1281\ *) [[ "$r" = booted ]] || r=recovery;; *) ;; esac
  done < <(_t1r_usb_scan)
  printf '%s\n' "$r"
}

t1_sysfs() {
  local line p d
  while read -r line; do
    p=${line%% *}; d=${line#* }
    if [[ "$p" = 8600 ]]; then printf '%s\n' "$d"; return 0; fi
  done < <(_t1r_usb_scan)
  while read -r line; do
    p=${line%% *}; d=${line#* }
    if [[ "$p" = 1281 ]]; then printf '%s\n' "$d"; return 0; fi
  done < <(_t1r_usb_scan)
  printf '\n'
}

t1_config() {
  local line p d
  while read -r line; do
    p=${line%% *}; d=${line#* }
    if [[ "$p" = 8600 ]] && [[ -r "$d/bConfigurationValue" ]]; then
      tr -d '\n' <"$d/bConfigurationValue"; printf '\n'; return 0
    fi
  done < <(_t1r_usb_scan)
  printf '\n'
}

wait_t1() {  # wait_t1 STATE SECONDS
  local want=$1 secs=${2:-30} i n
  n=$((secs * 2))
  for ((i = 0; i < n; i++)); do
    [[ "$(t1_state)" = "$want" ]] && return 0
    sleep 0.5
  done
  [[ "$(t1_state)" = "$want" ]]
}

# ----- misc ----------------------------------------------------------------------------
# pacman "7.2.3.arch1-3" -> uname "7.2.3-arch1-3"
kver_normalize() { sed -E 's/\.(arch[0-9]*)/-\1/'; }

version() {
  if [[ -r "$T1R_ROOT/VERSION" ]]; then tr -d '\n' <"$T1R_ROOT/VERSION"; printf '\n'; else printf 'unknown\n'; fi
}

# dir_names DIR: the entry names of DIR on one line (names only, never contents).
dir_names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | paste -sd' '; }

# dir_nonempty DIR: 0 when DIR exists and has at least one entry.
dir_nonempty() { [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; }

# backup_latest: newest $T1R_STATE/efi-backup-<stamp>.tar (what cmd_backup writes), or empty.
backup_latest() {
  find "$T1R_STATE" -maxdepth 1 -name 'efi-backup-*.tar' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# run_cmd CMD...: honour T1R_DRY_RUN for anything that changes the machine.
run_cmd() {
  if [[ "$T1R_DRY_RUN" = 1 ]]; then note "(dry-run) $*"; return 0; fi
  "$@"
}

# load_conf: read key=value lines from $T1R_CONF/t1-revive.conf into T1R_* variables (only
# T1R_ keys are accepted). The environment and the command line win: a key listed in
# T1R_PRESET, or already set by a library that has no default here, is left alone.
load_conf() {
  local f=$T1R_CONF/t1-revive.conf k v set_keys=' '
  [[ -r "$f" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in T1R_[A-Z_0-9]*) ;; *) continue;; esac
    case "$T1R_PRESET" in *" $k "*) continue;; *) ;; esac
    v=${v%\"}; v=${v#\"}
    printf -v "$k" '%s' "$v"; export "${k?}"
    set_keys="$set_keys$k "
  done < <(grep -E '^[[:space:]]*T1R_[A-Z_0-9]+=' "$f" | sed 's/^[[:space:]]*//')
  # T1R_DMI and T1R_ACPI_TABLES default to a path under T1R_SYSFS: follow a new sysfs root.
  if [[ "$set_keys" = *" T1R_SYSFS "* ]]; then
    case "$T1R_PRESET$set_keys" in *" T1R_DMI "*) ;; *) T1R_DMI=$T1R_SYSFS/class/dmi/id; export T1R_DMI;; esac
    case "$T1R_PRESET$set_keys" in *" T1R_ACPI_TABLES "*) ;; *) T1R_ACPI_TABLES=$T1R_SYSFS/firmware/acpi/tables; export T1R_ACPI_TABLES;; esac
  fi
  return 0
}
