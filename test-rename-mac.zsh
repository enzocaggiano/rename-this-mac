#!/bin/zsh
# Tests for rename-mac's logic. None of these change this Mac's names.
# Run: zsh test-rename-mac.zsh

export RENAME_MAC_LIB=1
export RENAME_MAC_HOME=$(mktemp -d -t rename-mac-test)
source "${0:A:h}/rename-mac.command"

pass=0 fail=0
check() {  # check LABEL EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then pass=$((pass+1)); print -r -- "  ok    $1"
  else fail=$((fail+1)); print -r -- "  FAIL  $1"; print -r -- "        expected: $2"; print -r -- "        actual:   $3"; fi
}

print "Name cleaning"
check "apostrophe removed, spaces kept"   $'Sams Mac mini\tSams-Mac-mini\t'          "$(rm_derive "Sam's Mac mini")"
check "curly apostrophe and emoji"        $'Zoes Lab\tZoes-Lab\t'                    "$(rm_derive "Zoë’s 💻 Lab")"
check "accents stripped"                  $'Nino Alborg\tNino-Alborg\t'              "$(rm_derive "Niño Ålborg")"
check "short name unchanged"              $'Studio\tStudio\t'                        "$(rm_derive "Studio")"
check "hyphenated name unchanged"         $'Lab-0FXY\tLab-0FXY\t'                    "$(rm_derive "Lab-0FXY")"
check "extra spaces and hyphens"          $'Lab - 2\tLab-2\t'                         "$(rm_derive "  Lab  -  2 ")"
check "case kept (no all-caps)"           $'Quiet Otter\tQuiet-Otter\t'              "$(rm_derive "Quiet Otter")"
check "15 characters is allowed"          $'Studio Room 042\tStudio-Room-042\t'      "$(rm_derive "Studio Room 042")"
check "16 characters is refused"          "Windows file sharing allows 15 characters, and Studio-Room-0042 has 16. Shorten it so all four names match." "$(rm_derive "Studio Room 0042" | cut -f3)"
check "symbols only is refused"           "Enter a name with at least one letter or number." "$(rm_derive "💻💻" | cut -f3)"

print "Templates and presets"
RM_F_SERIAL=H7QX2C0FXY RM_F_MODEL="MacBook Air" RM_F_FIRST=Sam
check "model preset"           "Sam's MacBook Air" "$(rm_expand "$(rm_preset_template model)")"
check "reset preset"           "MacBook Air"       "$(rm_expand "$(rm_preset_template reset)")"
check "serial template"        "Lab-0FXY"          "$(rm_expand 'Lab-{serial4}')"
check "unknown token kept"     "Lab-{nope}"        "$(rm_expand "Lab-{nope}")"
rm_config_set preset.lab 'Lab-{n}'
check "custom preset listed"   "model reset lab"   "$(rm_preset_names | paste -sd ' ' -)"
check "custom preset with n"   "Lab-4"             "$(rm_expand "$(rm_preset_template lab)" 4)"
rm_config_set preset.lab 'Studio-{n}'
check "config value replaced"  "Studio-{n}"        "$(rm_config_get preset.lab)"
check "config keeps one line"  "1"                 "$(grep -c '^preset.lab=' "$RENAME_MAC_HOME/config")"

print "Default name"
RM_F_FIRST=Sam RM_F_MODEL="Mac mini"
check "default fits with model"  "Sam's Mac mini"   "$(rm_default_name)"
RM_F_MODEL="MacBook Air"
check "default falls back to Mac" "Sam's Mac"       "$(rm_default_name)"
RM_F_FIRST=Maximiliano
check "default falls back to model" "MacBook Air"   "$(rm_default_name)"

print "Random names"
r=$(rm_random)
check "random is two words"    "2"                "${#${=r}}"
check "random is valid"        ""                 "$(rm_derive "$r" | cut -f3)"

print "Argument parsing"
( rm_parse_args --preset lab 7 --dry-run; print -r -- "$RM_PRESET|$RM_PRESET_N|$RM_DRY" ) | read out
check "--preset lab 7 --dry-run" "lab|7|1" "$out"
( rm_parse_args Sam\'s MacBook Air; print -r -- "$RM_NAME" ) | read out
check "unquoted name words joined" "Sam's MacBook Air" "$out"
( rm_parse_args --host studio.local Studio --dry-run; print -r -- "${(j:|:)RM_FORWARD}" ) | read out
check "--host forwards the rest"   "Studio|--dry-run" "$out"
( rm_parse_args --batch f.csv --log; print -r -- "$RM_BATCH|$RM_LOG" ) | read out
check "--batch with --log"         "f.csv|1" "$out"

print "CSV and JSON"
check "csv quoting"            '"say ""hi"""'     "$(rm_csv 'say "hi"')"
check "json string escaping"   '"a\"b\\c"'        "$(rm_json_str 'a"b\c')"
RM_LOG_FILE="$RENAME_MAC_HOME/inv.csv"
rm_inventory_add "MacBook Air" "Studio-4" rename
check "inventory header"       "date,serial,model,old_name,new_name,action" "$(head -1 "$RM_LOG_FILE")"
check "inventory row"          '"H7QX2C0FXY","MacBook Air","MacBook Air","Studio-4","rename"' "$(tail -1 "$RM_LOG_FILE" | cut -d, -f2-)"

print "History"
rm_history_add "Mac mini" Mac-mini-2 "$RM_UNSET" Mac-mini-2 "Studio 4" Studio-4 Studio-4 Studio-4
last=$(tail -n 1 "$RM_HISTORY"); f=("${(@ps:\t:)last}")
check "history keeps 9 fields" "9" "${#f}"
check "history old Bonjour"    "Mac-mini-2" "$f[3]"
check "history unset HostName" "$RM_UNSET" "$f[4]"

rm -rf "$RENAME_MAC_HOME"
print ""
print "$pass passed, $fail failed"
(( fail == 0 ))
