#!/bin/zsh
# rename-mac: set every name a Mac has (Finder, Bonjour, Terminal, Windows) in one step.
# Run with --help for usage. Double-click this file, or install it with --install.
#
# Copyright (C) 2026 Enzo Caggiano
# This program is free software: you can redistribute it and/or modify it under the terms of the
# GNU General Public License as published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version. See LICENSE or <https://www.gnu.org/licenses/>.
# https://github.com/enzocaggiano/rename-this-mac

emulate zsh
setopt no_monitor no_nomatch

RM_VERSION="1.0.0"
RM_SELF=${0:A}
RM_HOME=${RENAME_MAC_HOME:-$HOME/.rename-mac}
RM_CONFIG=$RM_HOME/config
RM_HISTORY=$RM_HOME/history.tsv
RM_INVENTORY_DEFAULT=$RM_HOME/inventory.csv
RM_SMB_PLIST=/Library/Preferences/SystemConfiguration/com.apple.smb.server
RM_UNSET=__UNSET__
RM_MAX_SMB=15

# Options (set by rm_parse_args)
typeset -g RM_CLI_ONLY=0 RM_DRY=0 RM_YES=0 RM_GUI=0 RM_QUIET=0 RM_CLASH=1 RM_REPORT=0 RM_LOG=0
typeset -g RM_LOG_FILE="" RM_PRESET="" RM_PRESET_N="" RM_TEMPLATE=""
typeset -g RM_ACTION=rename RM_NAME="" RM_HOST="" RM_BATCH=""
typeset -ga RM_FORWARD

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_DIM=$'\e[2m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_X=$'\e[0m'
else
  C_B="" C_DIM="" C_OK="" C_WARN="" C_ERR="" C_X=""
fi
rm_say()  { print -r -- "$*" }
rm_ok()   { print -r -- "${C_OK}✓${C_X} $*" }
rm_warn() { print -r -- "${C_WARN}!${C_X} $*" >&2 }
rm_err()  { print -r -- "${C_ERR}✕${C_X} $*" >&2 }
rm_die()  { rm_err "$1"; (( RM_GUI )) && rm_gui_alert "rename-mac couldn't finish" "$1"; exit ${2:-1} }

# ---------------------------------------------------------------- shared JavaScript (name cleaning, templates)
# The Terminal command and the window both use this, so they always produce identical names.

read -r -d '' RM_JS_LIB <<'JS'
var RM_ADJ = ['Quiet','Brave','Sunny','Lucky','Swift','Clever','Mellow','Bright','Cosmic','Gentle','Nimble','Steady'];
var RM_ANI = ['Otter','Falcon','Panda','Heron','Lynx','Koala','Badger','Finch','Walrus','Gecko','Puffin','Marten'];
function rmFriendly(raw) {
  return String(raw).normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .replace(/['\u2018\u2019\u02bc`"\u201c\u201d]/g, '')
    .replace(/[^A-Za-z0-9 \-]/g, ' ').replace(/\s+/g, ' ').trim();
}
function rmNet(friendly) {
  var n = friendly.replace(/ /g, '-').replace(/-+/g, '-').replace(/^-+|-+$/g, '');
  return n.slice(0, 63).replace(/-+$/g, '');
}
function rmDerive(raw) {
  var f = rmFriendly(raw), n = rmNet(f), problem = '';
  if (!n) problem = 'Enter a name with at least one letter or number.';
  else if (n.length > 15) problem = 'Windows file sharing allows 15 characters, and ' + n + ' has ' + n.length + '. Shorten it so all four names match.';
  return { friendly: f, net: n, problem: problem, cleaned: f !== String(raw).trim() };
}
function rmExpand(tpl, facts, n) {
  return tpl.replace(/\{(\w+)\}/g, function (m, k) {
    var v = { serial: facts.serial, serial4: String(facts.serial || '').slice(-4), model: facts.model,
              user: facts.user, first: facts.first, n: n }[k];
    return (v === undefined || v === null || v === '') ? m : String(v);
  });
}
function rmRandom() {
  return RM_ADJ[Math.floor(Math.random() * RM_ADJ.length)] + ' ' + RM_ANI[Math.floor(Math.random() * RM_ANI.length)];
}
JS

# Prints "friendly<TAB>net<TAB>problem" for a raw name.
rm_derive() {
  osascript -l JavaScript -e "$RM_JS_LIB" -e '
    function run(argv) { var d = rmDerive(argv[0]); return [d.friendly, d.net, d.problem].join("\t"); }' -- "$1"
}

# Prints a template with its {tokens} filled in.
rm_expand() {
  osascript -l JavaScript -e "$RM_JS_LIB" -e '
    function run(argv) { return rmExpand(argv[0], JSON.parse(argv[1]), argv[2]); }' -- "$1" "$(rm_facts_json)" "${2:-}"
}

rm_random() { osascript -l JavaScript -e "$RM_JS_LIB" -e 'function run() { return rmRandom(); }' }

# ---------------------------------------------------------------- facts about this Mac

typeset -g RM_F_SERIAL="" RM_F_MODEL="" RM_F_FIRST=""
rm_load_facts() {
  [[ -n $RM_F_MODEL ]] && return
  RM_F_SERIAL=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}')
  RM_F_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}')
  [[ -z $RM_F_MODEL ]] && RM_F_MODEL=$(sysctl -n hw.model)
  RM_F_FIRST=$(id -F 2>/dev/null); RM_F_FIRST=${RM_F_FIRST%% *}
  [[ -z $RM_F_FIRST ]] && RM_F_FIRST=$USER
}

rm_json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  print -rn -- "\"$s\""
}

rm_facts_json() {
  rm_load_facts
  print -rn -- "{\"serial\":$(rm_json_str "$RM_F_SERIAL"),\"model\":$(rm_json_str "$RM_F_MODEL"),\"user\":$(rm_json_str "$USER"),\"first\":$(rm_json_str "$RM_F_FIRST")}"
}

# ---------------------------------------------------------------- config and presets

rm_config_get() {
  [[ -r $RM_CONFIG ]] || return 1
  local line
  while IFS= read -r line; do
    [[ $line == "$1="* ]] && { print -r -- "${line#*=}"; return 0 }
  done < "$RM_CONFIG"
  return 1
}

rm_config_set() {
  mkdir -p "$RM_HOME"
  local tmp=$(mktemp "$RM_HOME/config.XXXXXX")
  [[ -r $RM_CONFIG ]] && grep -v "^$1=" "$RM_CONFIG" > "$tmp"
  print -r -- "$1=$2" >> "$tmp"
  mv "$tmp" "$RM_CONFIG"
}

# Built-in presets, then any "preset.<name>=<template>" lines from the config file.
rm_preset_names() {
  print -l model reset
  [[ -r $RM_CONFIG ]] && sed -n 's/^preset\.\([^=]*\)=.*/\1/p' "$RM_CONFIG"
}

rm_preset_template() {
  case $1 in
    model)       print -r -- "{first}'s {model}" ;;
    reset)       print -r -- '{model}' ;;
    *)           rm_config_get "preset.$1" ;;
  esac
}

# ---------------------------------------------------------------- reading and writing the four names

rm_get() { scutil --get "$1" 2>/dev/null || print -r -- "$RM_UNSET" }
rm_get_netbios() { defaults read "$RM_SMB_PLIST" NetBIOSName 2>/dev/null || print -r -- "$RM_UNSET" }

typeset -ga RM_CUR
rm_read_current() { RM_CUR=("$(rm_get ComputerName)" "$(rm_get LocalHostName)" "$(rm_get HostName)" "$(rm_get_netbios)") }

# Runs as root. Arguments: ComputerName LocalHostName HostName NetBIOSName (__UNSET__ removes HostName or NetBIOSName).
read -r -d '' RM_ROOT_SH <<'SH'
c=$1; l=$2; h=$3; b=$4
smb=/Library/Preferences/SystemConfiguration/com.apple.smb.server
/usr/sbin/scutil --set ComputerName "$c" || exit 11
/usr/sbin/scutil --set LocalHostName "$l" || exit 12
if [ "$h" = "__UNSET__" ]; then
  printf 'get /System/System\nd.remove HostName\nset /System/System\ncommit\napply\nquit\n' | /usr/sbin/scutil --prefs >/dev/null 2>&1
  /usr/sbin/scutil --get HostName >/dev/null 2>&1 && /usr/sbin/scutil --set HostName "$l"
else
  /usr/sbin/scutil --set HostName "$h" || exit 13
fi
nb=0
if [ "$b" = "__UNSET__" ]; then
  /usr/bin/defaults delete "$smb" NetBIOSName 2>/dev/null || /usr/libexec/PlistBuddy -c "Delete :NetBIOSName" "$smb.plist" 2>/dev/null
  nb=1
elif /usr/bin/defaults write "$smb" NetBIOSName -string "$b" 2>/dev/null; then
  nb=1
elif /usr/libexec/PlistBuddy -c "Set :NetBIOSName $b" "$smb.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :NetBIOSName string $b" "$smb.plist" 2>/dev/null; then
  /usr/bin/killall cfprefsd 2>/dev/null
  nb=1
fi
/usr/bin/dscacheutil -flushcache 2>/dev/null
/usr/bin/killall -HUP mDNSResponder 2>/dev/null
[ "$nb" = 1 ] || exit 14
exit 0
SH

# Returns 0 on success, 130 if the password prompt was cancelled, 14 if only the Windows name failed.
rm_apply_root() {
  local rc
  if (( RM_GUI )); then
    local out
    out=$(osascript - "$RM_ROOT_SH" "$@" 2>"$RM_HOME/last-error.txt" <<'AS'
on run argv
  set cmd to "/bin/sh -c " & quoted form of (item 1 of argv) & " rename-mac"
  repeat with i from 2 to count of argv
    set cmd to cmd & " " & quoted form of (item i of argv)
  end repeat
  try
    do shell script cmd with prompt "rename-mac wants to rename this Mac." with administrator privileges
  on error msg number n
    if n is -128 then return "cancelled"
    error msg number n
  end try
  return "ok"
end run
AS
)
    rc=$?
    [[ $out == cancelled ]] && return 130
    if (( rc != 0 )); then
      local code=$(grep -oE '\(-?[0-9]+\)' "$RM_HOME/last-error.txt" | tail -1 | tr -d '()')
      [[ $code == <-> ]] && return $code
      return 1
    fi
    return 0
  else
    sudo -p "Your Mac password (to rename this Mac): " /bin/sh -c "$RM_ROOT_SH" rename-mac "$@"
    rc=$?
    (( rc == 1 )) && ! sudo -n true 2>/dev/null && return 130
    return $rc
  fi
}

# Prints each name that doesn't match; returns 1 if any.
rm_verify() {
  rm_read_current
  local -a want=("$@") labels=("Finder name" "Bonjour name" "Terminal name" "Windows name")
  local i bad=0 got exp
  for i in 1 2 3 4; do
    exp=${want[i]}; got=${RM_CUR[i]}
    [[ $exp == "$RM_UNSET" && $i == 3 && $got == "${want[2]}" ]] && continue
    if [[ $got != "$exp" ]]; then
      rm_err "${labels[i]} is \"$got\" but should be \"$exp\"."
      bad=1
    fi
  done
  return $bad
}

# ---------------------------------------------------------------- safety checks

# Returns 0 if another device on the network already answers to NAME.local.
rm_clash() {
  local name=$1
  rm_read_current
  [[ ${(L)name} == ${(L)RM_CUR[2]} ]] && return 1
  local tmp=$(mktemp -t rename-mac)
  dns-sd -G v4v6 "$name.local" > "$tmp" 2>&1 &
  local pid=$!
  sleep 2
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  local hits=$(awk '$2 == "Add" && !/No Such Record/ {n++} END {print n+0}' "$tmp")
  rm -f "$tmp"
  (( hits > 0 ))
}

# ---------------------------------------------------------------- history, undo, inventory, notifications

rm_history_add() {
  mkdir -p "$RM_HOME"
  print -r -- "$(date '+%Y-%m-%dT%H:%M:%S')"$'\t'"${(pj:\t:)@}" >> "$RM_HISTORY"
}

rm_csv() { local s=${1//\"/\"\"}; print -rn -- "\"$s\"" }

rm_inventory_add() {
  local file=${RM_LOG_FILE:-$RM_INVENTORY_DEFAULT} old=$1 new=$2 action=$3
  rm_load_facts
  mkdir -p "${file:h}"
  [[ -s $file ]] || print -r -- 'date,serial,model,old_name,new_name,action' > "$file"
  print -r -- "$(rm_csv "$(date '+%Y-%m-%d %H:%M')"),$(rm_csv "$RM_F_SERIAL"),$(rm_csv "$RM_F_MODEL"),$(rm_csv "$old"),$(rm_csv "$new"),$(rm_csv "$action")" >> "$file"
}

rm_notify() {
  (( RM_QUIET )) && return 0
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title "rename-mac" subtitle (item 1 of argv) sound name "Glass"' -e 'end run' -- "$1" "$2" >/dev/null 2>&1
  return 0
}

rm_gui_alert() {
  osascript -e 'on run argv' -e 'display alert (item 1 of argv) message (item 2 of argv) as critical' -e 'end run' -- "$1" "$2" >/dev/null 2>&1
}

rm_gui_confirm() {
  osascript -e 'on run argv' -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Cancel", (item 3 of argv)} default button 2 with icon caution' -e 'end run' -- "$1" "$2" "$3" >/dev/null 2>&1
}

# ---------------------------------------------------------------- status table

rm_show() {
  rm_read_current
  local -a labels=("Finder and AirDrop" "Bonjour address" "Terminal host" "Windows sharing")
  local -a keys=(ComputerName LocalHostName HostName NetBIOSName)
  local expected=$(rm_derive "${RM_CUR[1]}" | cut -f2)
  local i val note all=1
  print -r -- "${C_B}This Mac's names${C_X}"
  for i in 1 2 3 4; do
    val=${RM_CUR[i]}; note=""
    if [[ $val == "$RM_UNSET" ]]; then
      if (( i == 3 )); then note="${C_WARN}not set, so Terminal shows $(hostname)${C_X}"; else note="${C_WARN}not set${C_X}"; fi
      all=0; val="(not set)"
    elif (( i > 1 )) && [[ ${(L)val} != ${(L)expected} ]]; then
      note="${C_WARN}doesn't match${C_X}"; all=0
    else
      note="${C_OK}✓${C_X}"
    fi
    (( i == 2 )) && [[ $val != "(not set)" ]] && val="$val.local"
    printf '  %-20s %s%-14s%s %-28s %s\n' "${labels[i]}" "$C_DIM" "${keys[i]}" "$C_X" "$val" "$note"
  done
  if (( all )); then rm_ok "All four names match."
  else rm_warn "Some names don't match. Fix them with: rename-mac \"${RM_CUR[1]}\""; fi
}

# ---------------------------------------------------------------- the rename itself

# rm_rename_to RAWNAME [ACTION_LABEL]
rm_rename_to() {
  local raw=$1 label=${2:-rename}
  local d friendly net problem
  d=$(rm_derive "$raw") || rm_die "Couldn't read that name."
  friendly=${d%%$'\t'*}; d=${d#*$'\t'}; net=${d%%$'\t'*}; problem=${d#*$'\t'}
  [[ -n $problem ]] && rm_die "$problem" 2

  rm_read_current
  local -a old=("${RM_CUR[@]}") new=("$friendly" "$net" "$net" "$net")

  if (( ! RM_GUI )); then
    print -r -- ""
    print -r -- "${C_B}Before → after${C_X}"
    local -a labels=("Finder and AirDrop" "Bonjour address" "Terminal host" "Windows sharing")
    local i o n
    for i in 1 2 3 4; do
      o=${old[i]}; n=${new[i]}
      [[ $o == "$RM_UNSET" ]] && o="(not set)"
      (( i == 2 )) && { [[ $o != "(not set)" ]] && o="$o.local"; n="$n.local" }
      printf '  %-20s %-26s → %s\n' "${labels[i]}" "$o" "$n"
    done
    print -r -- ""
  fi

  if [[ $old[1] == "$friendly" && $old[2] == "$net" && $old[3] == "$net" && $old[4] == "$net" ]]; then
    rm_ok "This Mac already uses these names. Nothing to change."
    (( RM_REPORT )) && rm_report verified "$old[1]" "$friendly"
    return 0
  fi

  if (( RM_CLASH )); then
    (( RM_GUI )) || rm_say "${C_DIM}Checking the network for another device named $net…${C_X}"
    if rm_clash "$net"; then
      local msg="Another device on this network already answers to $net.local. If you keep this name, macOS will quietly rename this Mac to $net-2."
      if (( RM_GUI )); then
        rm_gui_confirm "Name already in use" "$msg" "Use it anyway" || exit 130
      elif (( RM_YES )) || [[ ! -t 0 ]]; then
        rm_die "$msg Pick another name, or add --no-clash-check." 4
      else
        rm_warn "$msg"
        read -q "?Use it anyway? [y/N] " || { print; exit 130 }
        print
      fi
    fi
  fi

  if (( RM_DRY )); then
    rm_ok "Dry run: nothing changed."
    (( RM_GUI )) && rm_notify "Dry run: nothing changed" "Would rename this Mac to $net."
    return 0
  fi

  if (( ! RM_YES && ! RM_GUI )); then
    [[ -t 0 ]] || rm_die "Add --yes to rename without a prompt."
    read -q "?Rename this Mac? [y/N] " || { print; exit 130 }
    print
  fi

  mkdir -p "$RM_HOME"
  rm_apply_root "${new[@]}"
  local arc=$?
  case $arc in
    0)   ;;
    130) rm_die "Rename cancelled at the password prompt. Nothing changed." 130 ;;
    14)  new[4]=$old[4]
         rm_history_add "${old[@]}" "${new[@]}"
         local wmsg="Finder, Bonjour, and Terminal now use $net, but macOS blocked the Windows sharing name (still ${old[4]}). Set it in System Settings > Network > your connection > Details > WINS > NetBIOS Name: $net"
         (( RM_GUI )) && rm_gui_alert "3 of 4 names changed" "$wmsg"
         rm_warn "$wmsg"
         (( RM_REPORT )) && rm_report partial "$old[1]" "$friendly"
         exit 14 ;;
    *)   rm_die "The rename stopped with error $arc before finishing. Run rename-mac --show to see which names changed." $arc ;;
  esac

  if ! rm_verify "${new[@]}"; then
    rm_history_add "${old[@]}" "${new[@]}"
    (( RM_REPORT )) && rm_report failed "$old[1]" "$friendly"
    rm_die "Some names didn't change. Run rename-mac --show to see them, or rename-mac --undo to go back." 3
  fi

  rm_history_add "${old[@]}" "${new[@]}"
  local oldshow=$old[1]; [[ $oldshow == "$RM_UNSET" ]] && oldshow="(not set)"
  (( RM_LOG )) && rm_inventory_add "$oldshow" "$friendly" "$label"
  rm_ok "Renamed to $friendly. All 4 names verified."
  (( RM_LOG )) && rm_ok "Added to inventory log: ${RM_LOG_FILE:-$RM_INVENTORY_DEFAULT}"
  rm_say "${C_DIM}Undo with: rename-mac --undo${C_X}"
  rm_notify "Renamed to $net" "All 4 names verified · Undo: rename-mac --undo"
  (( RM_REPORT )) && rm_report verified "$oldshow" "$friendly"
  return 0
}

# One machine-readable line for --batch to collect.
rm_report() {
  rm_load_facts
  print -r -- "RENAME_MAC_RESULT"$'\t'"$1"$'\t'"$2"$'\t'"$3"$'\t'"$RM_F_SERIAL"$'\t'"$RM_F_MODEL"
}

rm_undo() {
  [[ -s $RM_HISTORY ]] || rm_die "There's no rename to undo yet."
  local last=$(tail -n 1 "$RM_HISTORY")
  local -a f=("${(@ps:\t:)last}")
  local -a old=("${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}")
  [[ $old[2] == "$RM_UNSET" ]] && rm_die "The last history entry has no Bonjour name to restore."
  local shown=$old[1]; [[ $shown == "$RM_UNSET" ]] && shown=$old[2]
  rm_say "Restoring the names from ${f[1]/T/ at }: $shown"
  if (( RM_DRY )); then rm_ok "Dry run: nothing changed."; return 0; fi
  if (( ! RM_YES && ! RM_GUI )); then
    [[ -t 0 ]] || rm_die "Add --yes to undo without a prompt."
    read -q "?Undo the last rename? [y/N] " || { print; exit 130 }
    print
  fi
  [[ $old[1] == "$RM_UNSET" ]] && old[1]=$old[2]
  rm_apply_root "${old[@]}" || rm_die "The undo was cancelled or didn't get admin rights."
  rm_verify "${old[@]}" || rm_die "Some names didn't go back. Run rename-mac --show to see them." 3
  local tmp=$(mktemp "$RM_HOME/history.XXXXXX")
  sed '$d' "$RM_HISTORY" > "$tmp" && mv "$tmp" "$RM_HISTORY"
  (( RM_LOG )) && rm_inventory_add "${f[6]}" "$shown" undo
  rm_ok "Restored $shown."
  rm_notify "Restored $shown" "The last rename was undone"
}

# ---------------------------------------------------------------- choosing the name

# Suggests "First's Model", then "First's Mac", then the model, using the first that fits 15 characters.
rm_default_name() {
  rm_load_facts
  local cand
  for cand in "${RM_F_FIRST}'s ${RM_F_MODEL}" "${RM_F_FIRST}'s Mac" "$RM_F_MODEL"; do
    [[ -z $(rm_derive "$cand" | cut -f3) ]] && { print -r -- "$cand"; return 0 }
  done
  print -r -- "$RM_F_MODEL"
}

rm_resolve_name() {
  if [[ -n $RM_TEMPLATE ]]; then
    RM_NAME=$(rm_expand "$RM_TEMPLATE" "$RM_PRESET_N")
  elif [[ -n $RM_PRESET ]]; then
    local tpl=$(rm_preset_template "$RM_PRESET")
    [[ -z $tpl ]] && rm_die "There's no preset named \"$RM_PRESET\". Presets: $(rm_preset_names | paste -sd ' ' -)"
    if [[ $tpl == *'{n}'* && -z $RM_PRESET_N ]]; then
      [[ -t 0 && $RM_GUI == 0 ]] || rm_die "This preset needs a number, like: rename-mac --preset $RM_PRESET 3"
      print -n "Which number? "; read -r RM_PRESET_N
    fi
    RM_NAME=$(rm_expand "$tpl" "$RM_PRESET_N")
    [[ $RM_PRESET == reset ]] && RM_ACTION_LABEL=reset
  fi
  [[ $RM_NAME == *'{'*'}'* ]] && rm_die "The name \"$RM_NAME\" still has an unfilled {token}."
  return 0
}

rm_interactive() {
  rm_show
  print -r -- ""
  local name=${RM_NAME:-$(rm_default_name)}
  print -r -- "${C_DIM}Type a new name and press Return. Spaces are fine.${C_X}"
  vared -p "New name: " name || exit 130
  RM_NAME=$name
}

# ---------------------------------------------------------------- the window (option B)

read -r -d '' RM_JXA_PANEL <<'JS'
ObjC.import('Cocoa');
function run(argv) {
  var ctx = JSON.parse(argv[0]);
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var menu = $.NSMenu.alloc.init, item = $.NSMenuItem.alloc.init, edit = $.NSMenu.alloc.initWithTitle('Edit');
  menu.addItem(item);
  [['Undo', 'undo:', 'z'], ['Cut', 'cut:', 'x'], ['Copy', 'copy:', 'c'], ['Paste', 'paste:', 'v'], ['Select All', 'selectAll:', 'a']]
    .forEach(function (m) { edit.addItemWithTitleActionKeyEquivalent(m[0], m[1], m[2]); });
  item.setSubmenu(edit);
  app.setMainMenu(menu);

  var W = 440, H = ctx.error ? 316 : 274, ui = {};
  var view = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, W, H));
  function top(y, h) { return H - y - h; }
  function label(text, x, y, w, h, opts) {
    var t = $.NSTextField.labelWithString(text);
    t.setFrame($.NSMakeRect(x, top(y, h), w, h));
    opts = opts || {};
    if (opts.mono) t.setFont($.NSFont.monospacedSystemFontOfSizeWeight(12, 0));
    if (opts.small) t.setFont($.NSFont.systemFontOfSize(11));
    if (opts.muted) t.setTextColor($.NSColor.secondaryLabelColor);
    if (opts.wrap) { t.setLineBreakMode($.NSLineBreakByWordWrapping); t.setMaximumNumberOfLines(3); t.cell.setWraps(true); }
    else t.setLineBreakMode($.NSLineBreakByTruncatingMiddle);
    view.addSubview(t);
    return t;
  }

  ObjC.registerSubclass({
    name: 'RMController', superclass: 'NSObject', protocols: ['NSTextFieldDelegate'],
    methods: {
      'controlTextDidChange:': { types: ['void', ['id']], implementation: function () { refresh(); } },
      'presetChanged:': { types: ['void', ['id']], implementation: function () { applyPreset(); } },
      'randomName:': { types: ['void', ['id']], implementation: function () { ui.name.setStringValue(rmRandom()); refresh(); } },
      'dryChanged:': { types: ['void', ['id']], implementation: function () { refresh(); } }
    }
  });
  var ctl = $.RMController.alloc.init;

  label('Preset', 0, 4, 52, 20, { muted: true });
  ui.preset = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(52, top(0, 26), 290, 26), false);
  ctx.presets.forEach(function (p) { ui.preset.addItemWithTitle(p.label); });
  ctx.presets.forEach(function (p, i) { if (ctx.preset && p.id === ctx.preset) ui.preset.selectItemAtIndex(i); });
  ui.preset.setTarget(ctl); ui.preset.setAction('presetChanged:');
  view.addSubview(ui.preset);
  var rnd = $.NSButton.buttonWithTitleTargetAction('Random', ctl, 'randomName:');
  rnd.setFrame($.NSMakeRect(350, top(0, 26), 90, 26));
  view.addSubview(rnd);

  ui.name = $.NSTextField.alloc.initWithFrame($.NSMakeRect(0, top(36, 26), W, 26));
  ui.name.setStringValue(ctx.name);
  ui.name.setFont($.NSFont.systemFontOfSize(14));
  ui.name.setDelegate(ctl);
  view.addSubview(ui.name);

  var rows = [['Finder / AirDrop', 'friendly'], ['Bonjour (.local)', 'bonjour'], ['Terminal host', 'host'], ['Windows (SMB)', 'smb']];
  ui.rows = rows.map(function (r, i) {
    var y = 74 + i * 24;
    label(r[0], 0, y, 120, 18, { muted: true });
    return { key: r[1], val: label('', 124, y, 290, 18, { mono: true }), st: label('', 420, y, 20, 18) };
  });

  ui.msg = label('', 0, 172, W, 44, { wrap: true, small: true });

  function check(title, x, y, w, on, action) {
    var b = $.NSButton.checkboxWithTitleTargetAction(title, action ? ctl : null, action || null);
    b.setFrame($.NSMakeRect(x, top(y, 20), w, 20));
    b.setState(on ? 1 : 0);
    view.addSubview(b);
    return b;
  }
  ui.clash = check('Check network for clashes', 0, 222, 200, ctx.clash, null);
  ui.dry = check('Dry run', 204, 222, 80, ctx.dry, 'dryChanged:');
  ui.log = check('Add to inventory log', 288, 222, 152, ctx.log, null);

  label('Now: ' + ctx.current + '   ·   ' + ctx.model + (ctx.serial4 ? ', serial ending ' + ctx.serial4 : ''), 0, 254, W, 16, { small: true, muted: true });
  ui.err = label(ctx.error || '', 0, 276, W, 34, { wrap: true, small: true });
  ui.err.setTextColor($.NSColor.systemRedColor);

  var alert = $.NSAlert.alloc.init;
  alert.setMessageText('Rename this Mac');
  alert.setInformativeText('All four names update together. Spaces are fine in the Finder name.');
  alert.addButtonWithTitle('Rename');
  alert.addButtonWithTitle('Cancel');
  alert.addButtonWithTitle('Undo last rename');
  alert.setAccessoryView(view);
  var icon = $.NSImage.imageNamed('NSComputer');
  if (!icon.isNil()) alert.setIcon(icon);
  ui.go = alert.buttons.objectAtIndex(0);

  function applyPreset() {
    var p = ctx.presets[ui.preset.indexOfSelectedItem];
    if (!p || !p.template) { refresh(); return; }
    var n = '';
    if (p.template.indexOf('{n}') > -1) {
      var m = /(\d+)$/.exec(ctx.currentNet || '');
      n = m ? m[1] : '1';
    }
    ui.name.setStringValue(rmExpand(p.template, ctx.facts, n));
    refresh();
  }

  function refresh() {
    var d = rmDerive(ObjC.unwrap(ui.name.stringValue));
    var vals = { friendly: d.friendly || '—', bonjour: d.net ? d.net + '.local' : '—', host: d.net || '—', smb: d.net || '—' };
    ui.rows.forEach(function (r) {
      r.val.setStringValue(vals[r.key]);
      var bad = !d.net || (r.key === 'smb' && d.net.length > 15);
      r.st.setStringValue(bad ? '⚠' : '✓');
      r.st.setTextColor(bad ? $.NSColor.systemOrangeColor : $.NSColor.systemGreenColor);
    });
    if (d.problem) { ui.msg.setStringValue(d.problem); ui.msg.setTextColor($.NSColor.systemOrangeColor); }
    else if (d.cleaned) { ui.msg.setStringValue('Network names can\u2019t use apostrophes, emoji, accents, or symbols, so they were removed.'); ui.msg.setTextColor($.NSColor.secondaryLabelColor); }
    else { ui.msg.setStringValue(''); }
    ui.go.setEnabled(!d.problem);
    ui.go.setTitle(ui.dry.state == 1 ? 'Preview' : 'Rename');
  }

  refresh();
  alert.window.setInitialFirstResponder(ui.name);

  if (ctx.snapshot) {
    alert.window.setAppearance($.NSAppearance.appearanceNamed('NSAppearanceNameAqua'));
    alert.layout;
    var cv = alert.window.contentView.superview, b = cv.bounds;
    var rep = cv.bitmapImageRepForCachingDisplayInRect(b);
    cv.cacheDisplayInRectToBitmapImageRep(b, rep);
    rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({})).writeToFileAtomically(ctx.snapshot, true);
    return 'snapshot';
  }

  app.activateIgnoringOtherApps(true);
  var r = alert.runModal;
  var action = r == 1000 ? 'rename' : (r == 1002 ? 'undo' : 'cancel');
  return [action, ObjC.unwrap(ui.name.stringValue).replace(/[\t\n]/g, ' '),
          ui.dry.state == 1 ? 1 : 0, ui.clash.state == 1 ? 1 : 0, ui.log.state == 1 ? 1 : 0].join('\t');
}
JS

rm_gui_context() {
  local name=$1 error=$2 snapshot=$3
  rm_load_facts; rm_read_current
  local cur=$RM_CUR[1]; [[ $cur == "$RM_UNSET" ]] && cur="(not set)"
  local presets="[{\"id\":\"\",\"label\":\"Custom\",\"template\":\"\"}" p tpl lbl
  for p in ${(f)"$(rm_preset_names)"}; do
    tpl=$(rm_preset_template "$p")
    case $p in
      model)       lbl='My name + model' ;;
      reset)       lbl="Apple default (before donating)" ;;
      *)           lbl="$p ($tpl)" ;;
    esac
    presets+=",{\"id\":$(rm_json_str "$p"),\"label\":$(rm_json_str "$lbl"),\"template\":$(rm_json_str "$tpl")}"
  done
  presets+="]"
  print -rn -- "{\"name\":$(rm_json_str "$name"),\"current\":$(rm_json_str "$cur"),\"currentNet\":$(rm_json_str "$RM_CUR[2]"),\"model\":$(rm_json_str "$RM_F_MODEL"),\"serial4\":$(rm_json_str "${RM_F_SERIAL[-4,-1]}"),\"facts\":$(rm_facts_json),\"presets\":$presets,\"preset\":$(rm_json_str "$RM_PRESET"),\"dry\":$RM_DRY,\"clash\":$RM_CLASH,\"log\":$(( RM_LOG || 1 )),\"error\":$(rm_json_str "$error"),\"snapshot\":$(rm_json_str "$snapshot")}"
}

# Option A fallback: plain dialogs, used only if the panel can't open.
rm_gui_dialogs() {
  local name=$1 problem d
  while true; do
    name=$(osascript -e 'on run argv' -e 'text returned of (display dialog "Enter a new name. Spaces are fine." default answer (item 1 of argv) with title "Rename this Mac" buttons {"Cancel", "Continue"} default button 2)' -e 'end run' -- "$name" 2>/dev/null) || exit 130
    d=$(rm_derive "$name"); problem=${d##*$'\t'}
    if [[ -n $problem ]]; then rm_gui_alert "Choose a shorter name" "$problem"; continue; fi
    local f=${d%%$'\t'*} n=${${d#*$'\t'}%%$'\t'*}
    osascript -e 'on run argv' -e 'display dialog ("Finder: " & item 1 of argv & return & "Bonjour: " & item 2 of argv & ".local" & return & "Terminal: " & item 2 of argv & return & "Windows: " & item 2 of argv) with title "Apply these names?" buttons {"Back", "Rename"} default button 2' -e 'end run' -- "$f" "$n" >/dev/null 2>&1 && break
  done
  RM_NAME=$name
}

rm_gui() {
  RM_GUI=1
  local name=${RM_NAME:-$(rm_default_name)} error="" out rc
  local -a r
  while true; do
    out=$(osascript -l JavaScript -e "$RM_JS_LIB" -e "$RM_JXA_PANEL" -- "$(rm_gui_context "$name" "$error" "${RENAME_MAC_SNAPSHOT:-}")" 2>/dev/null); rc=$?
    [[ -n ${RENAME_MAC_SNAPSHOT:-} ]] && { print -r -- "$out"; return 0 }
    if (( rc != 0 )); then
      rm_gui_dialogs "$name"
      rm_rename_to "$RM_NAME" "${RM_ACTION_LABEL:-rename}"
      return
    fi
    r=("${(@ps:\t:)out}")
    case $r[1] in
      cancel) exit 0 ;;
      undo)   rm_undo; return ;;
      rename)
        RM_NAME=$r[2]; RM_DRY=$r[3]; RM_CLASH=$r[4]; RM_LOG=$r[5]
        local d=$(rm_derive "$RM_NAME")
        if [[ -n ${d##*$'\t'} ]]; then name=$RM_NAME; error=${d##*$'\t'}; continue; fi
        rm_rename_to "$RM_NAME" "${RM_ACTION_LABEL:-rename}"
        return ;;
    esac
  done
}

# ---------------------------------------------------------------- other Macs over SSH

# rm_remote HOST ARGS... runs this script on HOST and prints its output.
rm_remote() {
  local host=$1; shift
  local rpath
  rpath=$(ssh -o ConnectTimeout=8 "$host" 'f=$(mktemp -t rename-mac) && cat > "$f" && chmod 700 "$f" && printf %s "$f"' < "$RM_SELF") \
    || { rm_err "Couldn't connect to $host over SSH."; return 20 }
  ssh -t -o ConnectTimeout=8 "$host" "/bin/zsh ${(q)rpath} ${(j: :)${(q)@}}; s=\$?; rm -f ${(q)rpath}; exit \$s"
}

rm_batch() {
  setopt localoptions extendedglob
  local file=$1
  [[ -r $file ]] || rm_die "Can't read $file."
  local -a rows hosts names
  local line host name
  rows=("${(@f)$(<"$file")}")
  for line in "${rows[@]}"; do
    line=${line//$'\r'/}
    [[ -z ${line// /} || $line == \#* || ${(L)line} == host,* ]] && continue
    host=${${line%%,*}// /}; name=${line#*,}; name=${name%%,*}
    name=${name##[[:space:]]#}; name=${name%%[[:space:]]#}
    [[ -z $host || -z $name ]] && { rm_warn "Skipping a line without a host and a name: $line"; continue }
    hosts+=("$host"); names+=("$name")
  done
  (( ${#hosts} )) || rm_die "No host,new_name lines found in $file."

  local -a fwd=(--yes --report --quiet)
  (( RM_DRY )) && fwd+=(--dry-run)
  (( RM_CLASH )) || fwd+=(--no-clash-check)
  local -a res_status res_old res_new
  local i out st tmp
  rm_say "${C_B}Renaming ${#hosts} Macs${C_X} ${C_DIM}(you may be asked for each Mac's password)${C_X}"
  for i in {1..${#hosts}}; do
    print -r -- ""
    print -r -- "${C_B}[$i/${#hosts}] ${hosts[i]} → ${names[i]}${C_X}"
    tmp=$(mktemp -t rename-mac)
    rm_remote "${hosts[i]}" "${fwd[@]}" "${names[i]}" | tee "$tmp"
    out=$(grep 'RENAME_MAC_RESULT' "$tmp" | tail -n 1 | tr -d '\r'); rm -f "$tmp"
    if [[ -n $out ]]; then
      local -a p=("${(@ps:\t:)out}")
      res_status+=("$p[2]"); res_old+=("$p[3]"); res_new+=("$p[4]")
      (( RM_LOG )) && [[ $p[2] == verified ]] && RM_F_SERIAL=$p[5] RM_F_MODEL=$p[6] rm_inventory_add "$p[3]" "$p[4]" batch
    elif (( RM_DRY )); then
      res_status+=(preview); res_old+=(""); res_new+=("${names[i]}")
    else
      res_status+=(failed); res_old+=(""); res_new+=("${names[i]}")
    fi
  done

  print -r -- ""
  print -r -- "${C_B}Summary${C_X}"
  local ok=0
  for i in {1..${#hosts}}; do
    case $res_status[i] in
      verified) ok=$((ok+1)); printf '  %s✓%s %-24s %s\n' "$C_OK" "$C_X" "${hosts[i]}" "${res_new[i]}" ;;
      preview)  printf '  %s·%s %-24s %s (dry run)\n' "$C_DIM" "$C_X" "${hosts[i]}" "${res_new[i]}" ;;
      *)        printf '  %s✕%s %-24s %s (not renamed)\n' "$C_ERR" "$C_X" "${hosts[i]}" "${res_new[i]}" ;;
    esac
  done
  rm_say "$ok of ${#hosts} renamed and verified."
  rm_notify "Batch rename finished" "$ok of ${#hosts} Macs renamed and verified"

  (( ok == ${#hosts} ))
}

# ---------------------------------------------------------------- install and uninstall

read -r -d '' RM_COMPLETION <<'ZSH'
#compdef rename-mac
_rename_mac_presets() {
  local -a p=(model reset)
  [[ -r ~/.rename-mac/config ]] && p+=(${(f)"$(sed -n 's/^preset\.\([^=]*\)=.*/\1/p' ~/.rename-mac/config)"})
  _describe preset p
}
_arguments -s \
  '(-n --dry-run)'{-n,--dry-run}'[show the change without making it]' \
  '(-y --yes)'{-y,--yes}'[skip the confirmation prompt]' \
  '--gui[open the rename window]' \
  '--show[show the current names]' \
  '--undo[put the previous names back]' \
  '--reset[use the Apple default name]' \
  '--random[pick a random two-word name]' \
  '--preset[use a saved naming pattern]:preset:_rename_mac_presets:number or core:' \
  '--template[build the name from a pattern]:template:' \
  '--host[rename another Mac over SSH]:host:_hosts' \
  '--batch[rename Macs listed in a CSV file]:file:_files -g "*.csv"' \
  '--log[add a row to the inventory CSV]::file:_files -g "*.csv"' \
  '--no-clash-check[skip the network name check]' \
  '(-q --quiet)'{-q,--quiet}'[no notification or sound]' \
  '--install[install the command, app, and Tab completion]' \
  '--install-cli[install only the command and Tab completion]' \
  '--uninstall[remove what --install added]' \
  '(-h --help)'{-h,--help}'[show help]' \
  '--version[show the version]' \
  '*:new name:'
ZSH

RM_ZSHRC_BEGIN="# >>> rename-mac >>>"
RM_ZSHRC_END="# <<< rename-mac <<<"
RM_APP="$HOME/Applications/Rename this Mac.app"

rm_install() {
  local dir=${RENAME_MAC_BIN:-/usr/local/bin}
  [[ -d $dir && -w $dir ]] || dir=$HOME/.local/bin
  mkdir -p "$dir" "$RM_HOME/completions" "$HOME/Applications"
  cp "$RM_SELF" "$dir/rename-mac" && chmod 755 "$dir/rename-mac" || rm_die "Couldn't copy rename-mac to $dir."
  rm_ok "Command: $dir/rename-mac"

  print -r -- "$RM_COMPLETION" > "$RM_HOME/completions/_rename-mac"
  rm_ok "Tab completion: $RM_HOME/completions/_rename-mac"

  if (( ! RM_CLI_ONLY )); then
    rm -rf "${RM_APP:?}"
    osacompile -o "$RM_APP" -e "try
    do shell script quoted form of \"$dir/rename-mac\" & \" --gui\"
  end try" >/dev/null 2>&1 && rm_ok "App: $RM_APP (find it in Spotlight as \"Rename this Mac\")" \
      || rm_warn "Couldn't build the Rename this Mac app."

  fi

  local -a block=("$RM_ZSHRC_BEGIN")
  [[ ":$PATH:" == *":$dir:"* ]] || block+=("export PATH=\"$dir:\$PATH\"")
  block+=("fpath=(\"$RM_HOME/completions\" \$fpath)" "autoload -Uz compinit && compinit" "$RM_ZSHRC_END")
  if ! grep -qF "$RM_ZSHRC_BEGIN" "$HOME/.zshrc" 2>/dev/null; then
    local add=1
    if (( ! RM_YES )) && [[ -t 0 ]]; then
      print -r -- ""
      print -r -- "To turn on Tab completion$([[ ":$PATH:" == *":$dir:"* ]] || print -n " and the rename-mac command"), these lines go at the end of ~/.zshrc:"
      print -rl -- "  ${^block[@]}"
      read -q "?Add them now? [y/N] " || add=0
      print
    fi
    if (( add )); then
      print -rl -- "" "${block[@]}" >> "$HOME/.zshrc"
      rm_ok "Updated ~/.zshrc (open a new Terminal window to use it)."
    else
      rm_say "Skipped ~/.zshrc. You can run $dir/rename-mac directly."
    fi
  fi

  (( RM_CLI_ONLY )) && { rm_say "Try it in a new Terminal window: rename-mac --show"; return 0 }
  print -r -- ""
  rm_say "${C_B}Optional:${C_X} to add it to the menu bar or Siri, open Shortcuts, make a shortcut with \"Open App → Rename this Mac\", and turn on \"Pin in Menu Bar\"."
  rm_say "Try it: rename-mac --show"
}

rm_uninstall() {
  local f
  for f in /usr/local/bin/rename-mac "$HOME/.local/bin/rename-mac"; do
    [[ -e $f ]] && rm -f "$f" && rm_ok "Removed $f"
  done
  [[ -d $RM_APP ]] && rm -rf "${RM_APP:?}" && rm_ok "Removed $RM_APP"
  rm -rf "${RM_HOME:?}/completions"
  if grep -qF "$RM_ZSHRC_BEGIN" "$HOME/.zshrc" 2>/dev/null; then
    local tmp=$(mktemp -t rename-mac)
    awk -v b="$RM_ZSHRC_BEGIN" -v e="$RM_ZSHRC_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$HOME/.zshrc" > "$tmp" && cat "$tmp" > "$HOME/.zshrc"
    rm -f "$tmp"
    rm_ok "Removed the rename-mac lines from ~/.zshrc"
  fi
  rm_say "Kept your history, inventory log, and settings in $RM_HOME."
}

# ---------------------------------------------------------------- help and arguments

rm_help() {
  cat <<EOF
${C_B}rename-mac $RM_VERSION${C_X}: set all four of a Mac's names in one step.

${C_B}Rename${C_X}
  rename-mac                         ask for a name (shows the current names first)
  rename-mac "Sam's Mac mini"        rename this Mac
  rename-mac --gui                   open the rename window
  rename-mac --random                use a random two-word name
  rename-mac --reset                 use Apple's default name, like "Mac mini"

${C_B}Check and undo${C_X}
  rename-mac --show                  show the current names and whether they match
  rename-mac --dry-run "Name"        show the change without making it
  rename-mac --undo                  put the previous names back

${C_B}Presets and templates${C_X}
  rename-mac --preset model          "{first}'s {model}", like "Sam's Mac mini"
  rename-mac --template "Lab-{serial4}"
  rename-mac --preset lab 4          use your own preset, with 4 filling {n}
  Tokens: {first} {user} {model} {serial} {serial4} {n}
  Add your own preset to ~/.rename-mac/config:  preset.lab=Lab-{n}

${C_B}Other Macs${C_X}
  rename-mac --host studio.local Studio   rename another Mac over SSH
  rename-mac --batch macs.csv        rename every host,new_name line in a CSV

${C_B}Options${C_X}
  -y, --yes            don't ask before renaming
  -q, --quiet          no notification or sound
  --log [file.csv]     add date, serial, model, old and new name to a CSV
                       (default ~/.rename-mac/inventory.csv)
  --no-clash-check     skip the check for another device using the name
  --install            add the command, the "Rename this Mac" app, and Tab completion
  --install-cli        add only the command and Tab completion
  --uninstall          remove them (keeps your history)

Names: the Finder name keeps spaces, and the other three use hyphens.
Windows sharing allows 15 characters, so longer names are refused.
EOF
}

rm_parse_args() {
  local -a orig=("$@")
  while (( $# )); do
    case $1 in
      -h|--help)       RM_ACTION=help ;;
      --version)       RM_ACTION=version ;;
      -n|--dry-run)    RM_DRY=1 ;;
      -y|--yes)        RM_YES=1 ;;
      -q|--quiet)      RM_QUIET=1 ;;
      --gui)           RM_ACTION=gui ;;
      --show)          RM_ACTION=show ;;
      --undo)          RM_ACTION=undo ;;
      --reset)         RM_PRESET=reset ;;
      --random)        RM_ACTION=random ;;
      --report)        RM_REPORT=1 ;;
      --no-clash-check) RM_CLASH=0 ;;
      --install)       RM_ACTION=install ;;
      --install-cli)   RM_ACTION=install; RM_CLI_ONLY=1 ;;
      --uninstall)     RM_ACTION=uninstall ;;
      --preset)        shift; RM_PRESET=${1:?--preset needs a name}
                       if [[ ${2:-} == <-> ]]; then RM_PRESET_N=$2; shift; fi ;;
      --template)      shift; RM_TEMPLATE=${1:?--template needs a pattern} ;;
      --host)          shift; RM_HOST=${1:?--host needs a host name} ;;
      --batch)         shift; RM_ACTION=batch; RM_BATCH=${1:?--batch needs a CSV file} ;;
      --log)           RM_LOG=1; if [[ -n ${2:-} && $2 == *.csv ]]; then RM_LOG_FILE=$2; shift; fi ;;
      --)              shift; RM_NAME="$*"; break ;;
      -*)              rm_die "Unknown option $1. Run rename-mac --help." ;;
      *)               RM_NAME=${RM_NAME:+$RM_NAME }$1 ;;
    esac
    shift
  done
  # With --host, everything except "--host HOST" runs on the other Mac.
  if [[ -n $RM_HOST ]]; then
    local i=1
    RM_FORWARD=()
    while (( i <= ${#orig} )); do
      if [[ ${orig[i]} == --host ]]; then (( i += 2 )); continue; fi
      RM_FORWARD+=("${orig[i]}"); (( i++ ))
    done
  fi
}

rm_main() {
  rm_parse_args "$@"
  if [[ -n $RM_HOST ]]; then
    rm_remote "$RM_HOST" "${RM_FORWARD[@]}"
    exit $?
  fi
  case $RM_ACTION in
    help)        rm_help ;;
    version)     print -r -- "rename-mac $RM_VERSION" ;;
    show)        rm_show ;;
    undo)        rm_undo ;;
    install)     rm_install ;;
    uninstall)   rm_uninstall ;;
    batch)       rm_batch "$RM_BATCH"; exit $? ;;
    gui)         rm_resolve_name; rm_gui ;;
    random)      RM_NAME=$(rm_random); rm_rename_to "$RM_NAME" random ;;
    rename)
      rm_resolve_name
      if [[ -z $RM_NAME ]]; then
        if [[ -t 0 ]]; then rm_interactive
        else RM_GUI=1; rm_gui; exit $?; fi
      fi
      rm_rename_to "$RM_NAME" "${RM_ACTION_LABEL:-rename}" ;;
  esac
}

[[ -n ${RENAME_MAC_LIB:-} ]] || rm_main "$@"
