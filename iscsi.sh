#!/bin/bash
# tnas-iscsi.sh - menu-driven manager for tgt iSCSI exports on TerraMaster TOS
#
# Every change is applied live (tgtadm) AND written to /etc/tgt/conf.d/<name>.conf,
# so it survives a reboot as long as the tgt service loads its config at boot.

# Fixed naming authority (RFC 3720: date the naming authority was taken, NOT the
# creation date of the target). Set once and never change it; existing targets
# keep whatever IQN they were created with.
IQN_PREFIX="iqn.2026-01.lan.tnas"
CONF_DIR="/etc/tgt/conf.d"
MAIN_CONF="/etc/tgt/targets.conf"
DEFAULT_DIR="/Volume5/iscsi"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
die()  { echo "${RED}$*${RST}" >&2; exit 1; }
err()  { echo "${RED}$*${RST}" >&2; }
ok()   { echo "${GRN}$*${RST}"; }
warn() { echo "${YEL}$*${RST}"; }
confirm()   { local r; read -rp "$1? [y/N]: " r; [[ $r =~ ^[yY]$ ]]; }          # default No
confirm_y() { local r; read -rp "$1? [Y/n]: " r; [[ -z $r || $r =~ ^[yY]$ ]]; } # default Yes

# Files created by an operation that is still in progress. If the script is
# interrupted (Ctrl-C, kill), they are removed so no half-written image or
# config is left behind.
PARTIAL=()
on_interrupt() {
    echo
    local f
    for f in "${PARTIAL[@]}"; do
        [[ -e $f ]] && rm -f -- "$f" && err "Interrupted - removed partial file $f"
    done
    exit 130
}
trap on_interrupt INT TERM HUP

[[ $EUID -eq 0 ]] || die "Run as root."
command -v tgtadm >/dev/null || die "tgtadm not found - is tgt installed?"
pgrep -x tgtd >/dev/null || die "tgtd is not running. Start it first (systemctl start tgt, or: tgtd && tgt-admin -e)."
mkdir -p "$CONF_DIR"

# Persistence check: tgt-admin only reads conf.d if the main config includes it.
if ! grep -qE "^[[:space:]]*include[[:space:]]+${CONF_DIR//./\\.}/" "$MAIN_CONF" 2>/dev/null; then
    warn "WARNING: $MAIN_CONF does not include $CONF_DIR/*.conf"
    warn "Exports created here will work now but will NOT come back after a reboot."
    warn "Add this line to $MAIN_CONF:  include $CONF_DIR/*.conf"
    warn "(and re-check after every TOS update - the firmware may rewrite /etc/tgt)."
    confirm "Continue anyway" || exit 1
fi

# ---------------------------------------------------------------- helpers ---

tgt_show() { tgtadm --lld iscsi --mode target --op show; }

load_targets() {
    TIDS=(); IQNS=()
    local tid iqn
    while read -r tid iqn; do TIDS+=("$tid"); IQNS+=("$iqn"); done < <(
        tgt_show | awk '/^Target [0-9]+:/ { t=$2; sub(/:$/,"",t); print t, $3 }')
}

conf_for_iqn() { grep -lsF "<target $1>" "$CONF_DIR"/*.conf 2>/dev/null | head -n1; }

acls_of() {
    tgt_show | awk -v want="$1" '
        /^Target [0-9]+:/ { t=$2; sub(/:$/,"",t); sec=""; next }
        t != want { next }
        /^    ACL information:/ { sec="acl"; next }
        /^    [A-Z]/ { sec="" }
        sec=="acl" && NF==1 { print $1 }'
}

sessions_of() {
    tgt_show | awk -v want="$1" '
        /^Target [0-9]+:/ { t=$2; sub(/:$/,"",t); next }
        t==want && /I_T nexus: [0-9]+/ { n++ }
        END { print n+0 }'
}

backing_of() {
    tgt_show | awk -v want="$1" '
        /^Target [0-9]+:/ { t=$2; sub(/:$/,"",t); next }
        t != want { next }
        /^ +LUN: [0-9]+/ { lun=$2 }
        /Backing store path:/ && lun > 0 { print $4 }'
}

# Prints the IQN of the live target using file $1 as a backing store (exit 0),
# or nothing (exit 1). Paths are compared after resolving symlinks.
backing_in_use() {
    local want path iqn
    want=$(realpath -m -- "$1")
    while read -r iqn path; do
        [[ $(realpath -m -- "$path") == "$want" ]] && { echo "$iqn"; return 0; }
    done < <(tgt_show | awk '
        /^Target [0-9]+:/ { iqn=$3; next }
        /^ +LUN: [0-9]+/ { lun=$2 }
        /Backing store path:/ && lun > 0 && $4 != "None" { print iqn, $4 }')
    return 1
}

# Same check against the config files, for targets that are configured but not
# currently loaded (they would come up at the next boot).
backing_in_conf() {
    local want f line
    want=$(realpath -m -- "$1")
    for f in "$CONF_DIR"/*.conf; do
        [[ -f $f ]] || continue
        while read -r line; do
            [[ $(realpath -m -- "$line") == "$want" ]] && { echo "$f"; return 0; }
        done < <(awk '{ gsub(/^[ \t]+/, "") } $1=="backing-store" { print $2 }' "$f")
    done
    return 1
}

describe() {   # $1 = tid
    tgt_show | awk -v want="$1" '
        /^Target [0-9]+:/ { t=$2; sub(/:$/,"",t); show=(t==want); sec="";
                            if (show) printf "\n\033[1m[tid %s] %s\033[0m\n", t, $3; next }
        !show { next }
        /^    I_T nexus information:/ { sec="nexus"; next }
        /^    LUN information:/       { sec="lun";   next }
        /^    Account information:/   { sec="acct";  next }
        /^    ACL information:/       { sec="acl";   next }
        sec=="nexus" && /Initiator:/  { ini=$2 }
        sec=="nexus" && /IP Address:/ { printf "    Connected : %s from %s\n", ini, $3 }
        sec=="lun" && /^ +LUN: [0-9]+/ { lun=$2 }
        sec=="lun" && /Size:/          { sz=$2" "$3; sub(/,$/,"",sz) }
        sec=="lun" && /Backing store path:/ && lun > 0 { printf "    LUN %-6s: %s (%s)\n", lun, $4, sz }
        sec=="acct" && NF > 0 { printf "    CHAP      : %s\n", $0 }
        sec=="acl"  && NF == 1 { printf "    ACL       : %s\n", $1 }'
}

valid_addr() {
    [[ $1 == ALL ]] && return 0
    local ip=${1%/*} o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
    if [[ $1 == */* ]]; then
        o=${1#*/}; [[ $o =~ ^[0-9]{1,2}$ ]] && (( 10#$o <= 32 )) || return 1
    fi
}

pick_target() {
    load_targets
    (( ${#TIDS[@]} )) || { warn "No iSCSI targets defined."; return 1; }
    echo
    local i n
    for i in "${!TIDS[@]}"; do printf "  %d) %s\n" $((i+1)) "${IQNS[$i]}"; done
    read -rp "Select target [1-${#TIDS[@]}], Enter = cancel: " n
    if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#TIDS[@]} )); then
        [[ -n $n ]] && err "Invalid choice."
        return 1
    fi
    SEL_TID=${TIDS[$((n-1))]}; SEL_IQN=${IQNS[$((n-1))]}
}

# Config file edits, limited to the <target IQN> ... </target> block
conf_add_line() {   # file iqn line
    local tmp; tmp=$(mktemp) || return 1
    awk -v tgt="<target $2>" -v add="    $3" '
        { l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l) }
        l == tgt { inb=1 }
        inb && l == "</target>" { print add; inb=0 }
        { print }' "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp"
}

conf_del_line() {   # file iqn line
    local tmp; tmp=$(mktemp) || return 1
    awk -v tgt="<target $2>" -v del="$3" '
        { l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l); gsub(/[ \t]+/, " ", l) }
        l == tgt { inb=1 }
        inb && l == del { next }
        inb && l == "</target>" { inb=0 }
        { print }' "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp"
}

conf_del_block() {  # file iqn  -> removes the block; removes the file if no target is left
    local tmp; tmp=$(mktemp) || return 1
    awk -v tgt="<target $2>" '
        { l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l) }
        l == tgt { skip=1 }
        !skip { print }
        skip && l == "</target>" { skip=0 }' "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp"
    if ! grep -q '<target ' "$1"; then rm -f "$1"; echo "Removed $1"; else echo "Updated $1"; fi
}

# ------------------------------------------------------------------ actions ---

list_exports() {
    load_targets
    (( ${#TIDS[@]} )) || { warn "No iSCSI targets defined."; return; }
    local i conf
    for i in "${!TIDS[@]}"; do
        describe "${TIDS[$i]}"
        conf=$(conf_for_iqn "${IQNS[$i]}")
        if [[ -n $conf ]]; then echo "    Config    : $conf"
        else warn "    Config    : NONE - this target will disappear after a reboot"; fi
    done
}

create_export() {
    local name iqn conf dir file size n u bytes avail thick=1 addrs a fs existing=0 who

    read -rp "Export name (letters, digits, '-' and '.'): " name
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { err "Invalid name."; return; }
    name=${name,,}                      # IQNs must be lowercase
    iqn="$IQN_PREFIX:$name"
    conf="$CONF_DIR/$name.conf"
    load_targets
    # Match on the name part only, so targets created under an older IQN prefix
    # (e.g. iqn.2026-09...:name) are caught too.
    for a in "${IQNS[@]}"; do
        [[ ${a##*:} == "$name" ]] && { err "A target named '$name' already exists: $a"; return; }
    done
    [[ -e $conf ]] && { err "$conf already exists."; return; }
    if who=$(grep -lsE "^[[:space:]]*<target [^>]*:${name//./\\.}>" "$CONF_DIR"/*.conf 2>/dev/null | head -n1) \
       && [[ -n $who ]]; then
        err "A target named '$name' is already configured in $who (not loaded right now)."
        return
    fi

    # Images always live in /VolumeN/iscsi
    local vols=() v i dflt=1
    mapfile -t vols < <(df -P | awk '$6 ~ /^\/Volume[0-9]+$/ { print $6 }' | sort -V)
    (( ${#vols[@]} )) || { err "No /VolumeN data volumes found."; return; }
    echo; echo "Data volumes:"
    for i in "${!vols[@]}"; do
        v=${vols[$i]}
        printf "  %d) %-10s %s free of %s (%s)\n" $((i+1)) "$v" \
            "$(df -h "$v" | awk 'NR==2 { print $4 }')" "$(df -h "$v" | awk 'NR==2 { print $2 }')" \
            "$(stat -f -c %T "$v" 2>/dev/null)"
        [[ "$v/iscsi" == "$DEFAULT_DIR" ]] && dflt=$((i+1))
    done
    read -rp "Volume for the image [$dflt]: " v
    v=${v:-$dflt}
    if ! [[ $v =~ ^[0-9]+$ ]] || (( v < 1 || v > ${#vols[@]} )); then err "Invalid choice."; return; fi
    dir="${vols[$((v-1))]}/iscsi"
    file="$dir/$name.img"
    echo "Image will be: $file"

    if [[ -e $file || -L $file ]]; then
        [[ -f $file ]] || { err "$file exists but is not a regular file."; return; }
        if who=$(backing_in_use "$file"); then
            err "$file is already exported by target $who."
            err "Exporting one image through two targets will corrupt it."
            return
        fi
        if who=$(backing_in_conf "$file"); then
            err "$file is already the backing store of a target configured in $who."
            return
        fi
        warn "$file already exists ($(du -h --apparent-size "$file" | cut -f1))."
        confirm "Export this existing file as-is (data is kept)" || return
        existing=1
    else
        read -rp "Size (e.g. 800M, 500G, 2T): " size
        # At most 6 digits: 999999T is ~2^60 bytes, safely below the 2^63 limit.
        [[ $size =~ ^([0-9]{1,6})([MmGgTt])$ ]] || { err "Invalid size (max 6 digits + M/G/T)."; return; }
        n=$((10#${BASH_REMATCH[1]})); u=${BASH_REMATCH[2]^^}   # 10# - "08G" is not octal
        case $u in M) bytes=$(( n << 20 ));; G) bytes=$(( n << 30 ));; T) bytes=$(( n << 40 ));; esac
        (( bytes > 0 )) || { err "Size must be > 0."; return; }

        confirm_y "Thick provisioning - reserve the full size now (recommended)" || thick=0
        avail=$(df -Pk "${dir%/iscsi}" | awk 'NR==2 { print $4 }')
        [[ $avail =~ ^[0-9]+$ ]] || { err "Cannot read free space of ${dir%/iscsi}."; return; }
        avail=$(( avail * 1024 ))
        if (( bytes > avail )); then
            if (( thick )); then err "Not enough free space on $dir ($(( avail >> 30 )) GiB free)."; return; fi
            warn "Thin image is larger than free space ($(( avail >> 30 )) GiB) - the client may hit I/O errors when it fills up."
            confirm "Continue" || return
        fi
    fi

    read -rp "Allowed initiator addresses, space separated (IP, IP/prefix, or ALL): " addrs
    [[ -n $addrs ]] || { err "At least one ACL entry is required (use ALL to allow anyone)."; return; }
    for a in $addrs; do valid_addr "$a" || { err "Invalid address: $a"; return; }; done

    echo; echo "${BLD}About to create:${RST}"
    echo "  Target : $iqn"
    echo "  Image  : $file $( ((existing)) && echo '(existing)' || echo "($size, $( ((thick)) && echo thick || echo thin))")"
    echo "  ACL    : $addrs"
    confirm "Proceed" || return

    if (( ! existing )); then
        if [[ ! -d $dir ]]; then
            mkdir -p "$dir" || { err "Cannot create $dir."; return; }
            [[ $(stat -f -c %T "$dir" 2>/dev/null) == btrfs ]] && chattr +C "$dir" 2>/dev/null
            echo "Created $dir"
        fi
        PARTIAL=("$file")               # removed by the trap if we are interrupted
        touch "$file" || { PARTIAL=(); return; }
        fs=$(stat -f -c %T "$dir" 2>/dev/null)
        if [[ $fs == btrfs ]]; then chattr +C "$file" 2>/dev/null && echo "btrfs: copy-on-write disabled for the image."; fi
        if (( thick )); then
            echo "Allocating $size ... (Ctrl-C aborts and removes the file)"
            fallocate -l "$bytes" "$file" || { err "fallocate failed."; rm -f "$file"; PARTIAL=(); return; }
        else
            truncate -s "$bytes" "$file" || { err "truncate failed."; rm -f "$file"; PARTIAL=(); return; }
        fi
    fi

    PARTIAL+=("$conf")
    {
        echo "# created by tnas-iscsi.sh on $(date '+%F %T')"
        echo "<target $iqn>"
        echo "    backing-store $file"
        for a in $addrs; do echo "    initiator-address $a"; done
        echo "    write-cache off"
        echo "</target>"
    } > "$conf"

    tgt-admin -e >/dev/null 2>&1
    PARTIAL=()
    load_targets
    for a in "${IQNS[@]}"; do
        if [[ $a == "$iqn" ]]; then ok "Export created and active."; list_one "$iqn"; return; fi
    done

    # Failed: roll back. A broken file left in conf.d could stop tgt-admin from
    # loading ANY target at the next boot.
    err "The target did not come up. Output of tgt-admin -e -v:"
    tgt-admin -e -v
    rm -f -- "$conf" && warn "Rolled back: removed $conf"
    if (( ! existing )); then
        rm -f -- "$file" && warn "Rolled back: removed new image $file"
    else
        echo "Existing image $file was left untouched."
    fi
}

list_one() { local i; load_targets; for i in "${!IQNS[@]}"; do [[ ${IQNS[$i]} == "$1" ]] && describe "${TIDS[$i]}"; done; }

add_acl() {
    pick_target || return
    local a conf
    echo "Current ACL:"; acls_of "$SEL_TID" | sed 's/^/    /'
    read -rp "Address to allow (IP, IP/prefix, or ALL): " a
    valid_addr "$a" || { err "Invalid address."; return; }
    if acls_of "$SEL_TID" | grep -qxF "$a"; then warn "$a is already allowed."; return; fi
    tgtadm --lld iscsi --mode target --op bind --tid "$SEL_TID" -I "$a" || { err "tgtadm bind failed."; return; }
    conf=$(conf_for_iqn "$SEL_IQN")
    if [[ -n $conf ]]; then conf_add_line "$conf" "$SEL_IQN" "initiator-address $a"; ok "Allowed $a (live + saved to $conf)."
    else warn "Allowed $a live, but no config file exists for this target - lost on reboot."; fi
}

remove_acl() {
    pick_target || return
    local acl=() i n a conf
    mapfile -t acl < <(acls_of "$SEL_TID")
    (( ${#acl[@]} )) || { warn "This target has no ACL entries."; return; }
    if (( ${#acl[@]} == 1 )); then
        err "${acl[0]} is the only ACL entry. Removing it would make tgt-admin allow ALL on the next reboot."
        echo "Add the replacement address first, then remove this one."
        return
    fi
    for i in "${!acl[@]}"; do printf "  %d) %s\n" $((i+1)) "${acl[$i]}"; done
    read -rp "Remove which entry? Enter = cancel: " n
    if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#acl[@]} )); then return; fi
    a=${acl[$((n-1))]}
    confirm "Remove $a from $SEL_IQN (already connected sessions stay connected)" || return
    tgtadm --lld iscsi --mode target --op unbind --tid "$SEL_TID" -I "$a" || { err "tgtadm unbind failed."; return; }
    conf=$(conf_for_iqn "$SEL_IQN")
    if [[ -n $conf ]]; then conf_del_line "$conf" "$SEL_IQN" "initiator-address $a"; ok "Removed $a (live + $conf)."
    else warn "Removed $a live only - no config file for this target."; fi
}

delete_export() {
    pick_target || return
    describe "$SEL_TID"
    local s files=() conf force="" name=${SEL_IQN##*:} c f
    s=$(sessions_of "$SEL_TID")
    mapfile -t files < <(backing_of "$SEL_TID")
    conf=$(conf_for_iqn "$SEL_IQN")
    echo
    if (( s > 0 )); then
        warn "$s initiator session(s) are connected! Log out / disconnect on the client first -"
        warn "pulling the disk from under a mounted filesystem can corrupt it."
        confirm "Force delete anyway" || return
        force="--force"
    fi
    read -rp "Type the export name '${name}' to confirm deletion: " c
    [[ $c == "$name" ]] || { warn "Cancelled."; return; }

    tgtadm --lld iscsi --mode target --op delete $force --tid "$SEL_TID" || { err "tgtadm delete failed."; return; }
    ok "Target $SEL_IQN removed."
    [[ -n $conf ]] && conf_del_block "$conf" "$SEL_IQN"

    for f in "${files[@]}"; do
        [[ -e $f ]] || continue
        echo
        warn "Image file: $f ($(du -h "$f" | cut -f1) used)"
        read -rp "Permanently delete it and ALL data in it? Type DELETE to confirm, Enter to keep: " c
        if [[ $c == DELETE ]]; then rm -f -- "$f" && ok "Deleted $f"; else echo "Kept $f"; fi
    done
}

reapply() { echo "Loading targets from $CONF_DIR (existing ones are skipped)..."; tgt-admin -e -v; }

# --------------------------------------------------------------------- menu ---

while true; do
    echo
    echo "${BLD}===== iSCSI manager (tgt) =====${RST}"
    echo "  1) List exports"
    echo "  2) Create export"
    echo "  3) Add ACL rule"
    echo "  4) Remove ACL rule"
    echo "  5) Delete export"
    echo "  6) Load missing targets from config files"
    echo "  0) Exit"
    read -rp "Choice: " choice
    case $choice in
        1) list_exports ;;
        2) create_export ;;
        3) add_acl ;;
        4) remove_acl ;;
        5) delete_export ;;
        6) reapply ;;
        0|q|Q) exit 0 ;;
        *) err "Unknown option." ;;
    esac
done
