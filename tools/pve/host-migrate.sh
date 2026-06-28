#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/core.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
load_functions
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "host-migrate" "pve"

BACKTITLE="Proxmox VE Helper Scripts - Host Migrate"
BUNDLE_PREFIX="pve-migrate"
NFS_MOUNTPOINT=""
NFS_MOUNTED=0
# Mountpoints this script created on demand and should clean up on exit
# (only those the user did NOT choose to make persistent via fstab).
TEMP_MOUNTS=()
# Result holders for the storage picker / disk preparation helpers.
BROWSE_RESULT=""
PREPARED_MP=""

function header_info {
  clear
  cat <<"EOF"
    __  __           __     __  ___ _                  __
   / / / /___  _____/ /_   /  |/  /(_)____ _____ ____ / /_ ___
  / /_/ / __ \/ ___/ __/  / /|_/ // // __ `/ ___/ __ `/ __// _ \
 / __  / /_/ (__  ) /_   / /  / // // /_/ / /  / /_/ / /_ /  __/
/_/ /_/\____/____/\__/  /_/  /_//_/ \__, /_/   \__,_/\__/ \___/
                                   /____/  EXPORT / IMPORT
EOF
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
header_info

if [ "$(id -u)" -ne 0 ]; then
  msg_error "This script must be run as root."
  exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
  msg_error "No Proxmox VE detected!"
  exit 1
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Cleanup handler: unmount things we mounted on demand (NFS + non-persistent
# disk mounts). Disk DATA is never touched here, we only unmount.
function cleanup {
  if [ "$NFS_MOUNTED" -eq 1 ] && mountpoint -q "$NFS_MOUNTPOINT"; then
    umount "$NFS_MOUNTPOINT" 2>/dev/null && rmdir "$NFS_MOUNTPOINT" 2>/dev/null
  fi
  local mp
  for mp in "${TEMP_MOUNTS[@]}"; do
    if mountpoint -q "$mp"; then
      umount "$mp" 2>/dev/null && rmdir "$mp" 2>/dev/null
    fi
  done
}
trap cleanup EXIT

# Convert a size string like "37.9G" / "931.51g" to a human label as-is.
# Echo a fresh, unique mountpoint path under /mnt for a given label.
function _new_mountpoint {
  local base="/mnt/${1}"
  local mp="$base"
  local n=1
  while [ -e "$mp" ] && ! { [ -d "$mp" ] && [ -z "$(ls -A "$mp" 2>/dev/null)" ]; }; do
    mp="${base}-${n}"
    n=$((n + 1))
  done
  echo "$mp"
}

# Offer to persist a mount in /etc/fstab. $1=device(or UUID source) $2=mountpoint $3=fstype
function _offer_fstab {
  local dev="$1" mp="$2" fstype="$3"
  local uuid
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
  if whiptail --backtitle "$BACKTITLE" --yesno \
    "Make this mount permanent (survives reboot) by adding it to /etc/fstab?\n\n${dev} -> ${mp}" 11 72; then
    if [ -n "$uuid" ]; then
      echo "UUID=${uuid} ${mp} ${fstype} defaults 0 2" >>/etc/fstab
    else
      echo "${dev} ${mp} ${fstype} defaults 0 2" >>/etc/fstab
    fi
    msg_ok "Added to /etc/fstab"
    return 0
  fi
  return 1
}

# Mount an existing filesystem on a device. Sets PREPARED_MP on success.
function mount_existing_fs {
  local dev="$1" fstype="$2"
  local mp
  PREPARED_MP=""
  mp=$(_new_mountpoint "$(basename "$dev")")
  mkdir -p "$mp"
  msg_info "Mounting ${dev}"
  if mount "$dev" "$mp" 2>/tmp/host-migrate-mount.log; then
    msg_ok "Mounted ${dev} at ${mp}"
    if _offer_fstab "$dev" "$mp" "${fstype:-auto}"; then :; else TEMP_MOUNTS+=("$mp"); fi
    PREPARED_MP="$mp"
    return 0
  fi
  msg_error "Could not mount ${dev} (see /tmp/host-migrate-mount.log)"
  rmdir "$mp" 2>/dev/null
  return 1
}

# Format a raw/empty device with ext4 and mount it. DESTRUCTIVE.
function format_and_mount {
  local dev="$1"
  local confirm
  confirm=$(whiptail --backtitle "$BACKTITLE" --title "!! DESTRUCTIVE - FORMAT !!" --inputbox \
    "\nThis will ERASE ALL DATA on:\n  ${dev}\n\nand create a fresh ext4 filesystem.\n\nType exactly  FORMAT  to proceed:" 14 72 \
    3>&1 1>&2 2>&3) || return 1
  [ "$confirm" != "FORMAT" ] && {
    msg_warn "Confirmation mismatch - nothing changed"
    sleep 2
    return 1
  }
  msg_info "Creating ext4 on ${dev}"
  if ! mkfs.ext4 -F "$dev" &>/tmp/host-migrate-mkfs.log; then
    msg_error "mkfs.ext4 failed (see /tmp/host-migrate-mkfs.log)"
    return 1
  fi
  msg_ok "Formatted ${dev}"
  mount_existing_fs "$dev" "ext4"
}

# Create a logical volume in a VG with free space, format ext4 and mount it.
function create_lv_and_mount {
  local vg="$1" vgfree="$2"
  local lvname size
  lvname=$(whiptail --backtitle "$BACKTITLE" --inputbox \
    "\nName for the new logical volume in VG '${vg}':" 10 64 \
    "backup" --title "New LV name" 3>&1 1>&2 2>&3) || return 1
  lvname="${lvname:-backup}"
  size=$(whiptail --backtitle "$BACKTITLE" --inputbox \
    "\nSize for /dev/${vg}/${lvname}\n(${vgfree} free).\nUse e.g. 500G, or leave empty for ALL free space:" 12 68 \
    --title "LV size" 3>&1 1>&2 2>&3) || return 1

  msg_info "Creating LV ${lvname} in ${vg}"
  if [ -z "$size" ]; then
    lvcreate -l 100%FREE -n "$lvname" "$vg" &>/tmp/host-migrate-lv.log || {
      msg_error "lvcreate failed (see /tmp/host-migrate-lv.log)"
      return 1
    }
  else
    lvcreate -L "$size" -n "$lvname" "$vg" &>/tmp/host-migrate-lv.log || {
      msg_error "lvcreate failed (see /tmp/host-migrate-lv.log)"
      return 1
    }
  fi
  msg_ok "Created /dev/${vg}/${lvname}"
  local dev="/dev/${vg}/${lvname}"
  msg_info "Creating ext4 on ${dev}"
  mkfs.ext4 -F "$dev" &>/tmp/host-migrate-mkfs.log || {
    msg_error "mkfs.ext4 failed (see /tmp/host-migrate-mkfs.log)"
    return 1
  }
  msg_ok "Formatted ${dev}"
  mount_existing_fs "$dev" "ext4"
}

# Show currently mounted filesystems (real storage only) and let the user pick
# one. Echoes the chosen mountpoint on stdout. Returns non-zero on cancel.
function browse_mounts {
  local menu=() target fstype size avail source
  local -A seen=()
  # Pseudo / non-storage filesystems we never want as a backup target.
  local exclude='tmpfs|devtmpfs|squashfs|overlay|fuse|fuse.lxcfs|cgroup|cgroup2|mqueue|pstore|bpf|debugfs|tracefs|configfs|sysfs|proc|autofs|ramfs|efivarfs|fusectl|securityfs|binfmt_misc|hugetlbfs|rpc_pipefs|devpts'

  if command -v findmnt >/dev/null 2>&1; then
    while IFS=$'\t' read -r target source fstype size avail; do
      [ -z "$target" ] && continue
      seen["$target"]=1
      local note=""
      [ "$target" = "/" ] && note="  <-- SYSTEM ROOT, use a subfolder!"
      menu+=("$target" "${fstype} | ${avail:-?} free of ${size:-?} | ${source}${note}")
    done < <(findmnt -rnD -o TARGET,SOURCE,FSTYPE,SIZE,AVAIL 2>/dev/null |
      awk -v ex="$exclude" 'BEGIN{OFS="\t"} $3 !~ ("^(" ex ")$") && $1 !~ "^/(proc|sys|dev|run|boot)(/|$)" && $1 != "/etc/pve" && !s[$1]++ {print $1,$2,$3,$4,$5}')
  else
    while read -r source target fstype _; do
      [[ "$fstype" =~ ^($exclude)$ ]] && continue
      [[ "$target" =~ ^/(proc|sys|dev|run|boot)(/|$) ]] && continue
      [ "$target" = "/etc/pve" ] && continue
      seen["$target"]=1
      menu+=("$target" "${fstype} | ${source}")
    done < <(awk '{print $1, $2, $3}' /proc/mounts)
  fi

  # Append Proxmox directory-type storages (path + free space). These often live
  # on an existing filesystem (e.g. /mnt/backup on root) and would otherwise be
  # invisible to a pure mount listing.
  if command -v pvesm >/dev/null 2>&1; then
    local sid savail spath
    while IFS=$'\t' read -r sid savail; do
      [ -z "$sid" ] && continue
      spath=$(awk -v id="$sid" '
        $1=="dir:" && $2==id {f=1; next}
        f && $1=="path" {print $2; exit}
        f && /^[^[:space:]]/ {exit}' /etc/pve/storage.cfg 2>/dev/null)
      [ -n "$spath" ] && [ -d "$spath" ] && [ -z "${seen[$spath]:-}" ] || continue
      seen["$spath"]=1
      menu+=("$spath" "pve-storage: ${sid} | ${savail} free")
    done < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" && $2=="dir" {printf "%s\t%.1fG\n", $1, $6/1048576}')
  fi

  # --- Unmounted block devices: offer mount / format -----------------------
  # Columns: NAME TYPE FSTYPE MOUNTPOINT SIZE TRAN
  local name dtype dfs dmnt dsize dtran dev
  while read -r name dtype dfs dmnt dsize dtran; do
    [ -z "$name" ] && continue
    [[ "$name" =~ ^(loop|zram|sr|fd) ]] && continue
    [ -n "$dmnt" ] && continue                       # already mounted
    [ "$dtype" = "disk" ] || [ "$dtype" = "part" ] || continue
    dev="/dev/${name}"
    # skip if device or any child is mounted (system disks)
    if lsblk -rno MOUNTPOINT "$dev" 2>/dev/null | grep -q .; then continue; fi
    case "$dfs" in
    LVM2_member | swap | crypto_LUKS) continue ;;     # handled via VG / not a target
    "")
      # Only offer to format reasonably sized devices (GiB/TiB), skip tiny ones.
      [[ "$dsize" =~ [GT]$ ]] || continue
      menu+=("FORMAT:${dev}" "[format] empty ${dtype} ${name} (${dsize}, ${dtran:-?}) - ERASES DATA")
      ;;
    ext2 | ext3 | ext4 | xfs | btrfs | vfat | exfat | ntfs)
      menu+=("MOUNT:${dev}" "[mount] ${dfs} on ${name} (${dsize}, ${dtran:-?})")
      ;;
    esac
  done < <(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT,SIZE,TRAN 2>/dev/null)

  # --- Volume groups with free space: offer to create an LV ----------------
  if command -v vgs >/dev/null 2>&1; then
    local vg vgfree
    while read -r vg vgfree; do
      [ -z "$vg" ] && continue
      # only offer if there is meaningful free space (> 1 GiB)
      awk -v f="$vgfree" 'BEGIN{exit !(f+0 > 1)}' || continue
      menu+=("LV:${vg}" "[lvm] create volume in VG '${vg}' (${vgfree}G free)")
    done < <(vgs --noheadings --nosuffix --units g -o vg_name,vg_free 2>/dev/null | awk '{print $1, $2}')
  fi

  if [ "${#menu[@]}" -eq 0 ]; then
    msg_error "No usable target found. Attach an SSD/USB/NFS first or use the NFS option."
    sleep 3
    return 1
  fi

  local picked
  picked=$(whiptail --backtitle "$BACKTITLE" --title "Select / Prepare Target Storage" --menu \
    "\nPick a ready location, or prepare a disk/LVM ([mount]/[format]/[lvm]):" 24 112 14 "${menu[@]}" 3>&1 1>&2 2>&3) || return 1

  BROWSE_RESULT=""
  case "$picked" in
  MOUNT:*)
    dev="${picked#MOUNT:}"
    mount_existing_fs "$dev" "$(lsblk -rno FSTYPE "$dev" 2>/dev/null | head -n1)" || return 1
    BROWSE_RESULT="$PREPARED_MP"
    ;;
  FORMAT:*)
    format_and_mount "${picked#FORMAT:}" || return 1
    BROWSE_RESULT="$PREPARED_MP"
    ;;
  LV:*)
    vg="${picked#LV:}"
    vgfree=$(vgs --noheadings --nosuffix --units g -o vg_free "$vg" 2>/dev/null | awk '{print $1}')
    create_lv_and_mount "$vg" "$vgfree" || return 1
    BROWSE_RESULT="$PREPARED_MP"
    ;;
  *)
    BROWSE_RESULT="$picked"
    ;;
  esac
  [ -n "$BROWSE_RESULT" ] || return 1
  return 0
}

# Ask the user whether the destination/source is a local path or an NFS share.
# Sets global variable BASE_DIR to a usable directory.
function choose_location {
  local prompt_title="$1"
  local default_path="$2"
  local choice

  choice=$(whiptail --backtitle "$BACKTITLE" --title "$prompt_title" --menu \
    "\nWhere is the migration bundle located?" 16 74 4 \
    "browse" "Pick / prepare storage (mounts, disks, LVM)" \
    "local" "Type a local path manually (SSD, USB, mount)" \
    "nfs" "NFS share (mount on demand)" \
    3>&1 1>&2 2>&3) || return 1

  if [ "$choice" = "browse" ]; then
    local picked sub
    browse_mounts || return 1
    picked="$BROWSE_RESULT"
    [ -z "$picked" ] && return 1
    sub=$(whiptail --backtitle "$BACKTITLE" --inputbox \
      "\nOptional subfolder under:\n${picked}\n\nLeave empty to use it directly." 12 70 \
      --title "Subfolder" 3>&1 1>&2 2>&3) || return 1
    BASE_DIR="${picked%/}${sub:+/${sub#/}}"
    if [ ! -d "$BASE_DIR" ]; then
      mkdir -p "$BASE_DIR" || {
        msg_error "Could not create '$BASE_DIR'"
        return 1
      }
    fi
    return 0
  elif [ "$choice" = "nfs" ]; then
    local nfs_server nfs_export
    nfs_server=$(whiptail --backtitle "$BACKTITLE" --inputbox \
      "\nNFS server (IP or hostname):\ne.g. 192.168.1.10" 11 68 \
      --title "NFS Server" 3>&1 1>&2 2>&3) || return 1
    nfs_export=$(whiptail --backtitle "$BACKTITLE" --inputbox \
      "\nExported path on the NFS server:\ne.g. /volume1/proxmox-backups" 11 68 \
      --title "NFS Export Path" 3>&1 1>&2 2>&3) || return 1

    if [ -z "$nfs_server" ] || [ -z "$nfs_export" ]; then
      msg_error "NFS server and export path are required."
      sleep 2
      return 1
    fi

    if ! command -v mount.nfs >/dev/null 2>&1; then
      msg_info "Installing nfs-common"
      apt-get update &>/dev/null
      apt-get install -y nfs-common &>/dev/null || {
        msg_error "Failed to install nfs-common"
        return 1
      }
      msg_ok "Installed nfs-common"
    fi

    NFS_MOUNTPOINT="/mnt/${BUNDLE_PREFIX}-nfs-$$"
    mkdir -p "$NFS_MOUNTPOINT"
    msg_info "Mounting ${nfs_server}:${nfs_export}"
    if mount -t nfs "${nfs_server}:${nfs_export}" "$NFS_MOUNTPOINT" 2>/dev/null; then
      NFS_MOUNTED=1
      msg_ok "Mounted NFS share at ${NFS_MOUNTPOINT}"
      BASE_DIR="$NFS_MOUNTPOINT"
    else
      msg_error "Could not mount ${nfs_server}:${nfs_export}"
      rmdir "$NFS_MOUNTPOINT" 2>/dev/null
      sleep 2
      return 1
    fi
  else
    local path
    path=$(whiptail --backtitle "$BACKTITLE" --inputbox \
      "\nLocal directory (must already exist / be mounted):" 11 68 \
      --title "Local Path" "$default_path" 3>&1 1>&2 2>&3) || return 1
    path="${path:-$default_path}"
    if [ ! -d "$path" ]; then
      if whiptail --backtitle "$BACKTITLE" --yesno "Directory '$path' does not exist. Create it?" 9 68; then
        mkdir -p "$path" || {
          msg_error "Could not create '$path'"
          return 1
        }
      else
        return 1
      fi
    fi
    BASE_DIR="$path"
  fi
  return 0
}

# Collect VM and CT lists into global arrays.
# GUEST_ROWS entries: "type|id|name|status"
function collect_guests {
  GUEST_ROWS=()
  if command -v qm >/dev/null 2>&1; then
    while read -r id name status _; do
      [ -z "$id" ] && continue
      GUEST_ROWS+=("vm|${id}|${name}|${status}")
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
  fi
  if command -v pct >/dev/null 2>&1; then
    while read -r id status name _; do
      [ -z "$id" ] && continue
      GUEST_ROWS+=("ct|${id}|${name}|${status}")
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
  fi
}

# ----------------------------------------------------------------------------
# EXPORT
# ----------------------------------------------------------------------------
function do_export {
  choose_location "Export Destination" "/mnt/" || return

  # Free-space awareness: show target capacity and warn when it's tight.
  local avail_h avail_g
  avail_h=$(df -h --output=avail "$BASE_DIR" 2>/dev/null | tail -n1 | tr -d ' ')
  avail_g=$(df -BG --output=avail "$BASE_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [ -n "$avail_g" ]; then
    if [ "$avail_g" -lt 10 ]; then
      if ! whiptail --backtitle "$BACKTITLE" --title "Low Disk Space" --yesno \
        "Target '${BASE_DIR}' has only ${avail_h:-?} free.\n\nA full export with vzdump can easily exceed this.\nConsider a larger disk/LVM target.\n\nContinue anyway?" 13 74; then
        return
      fi
    else
      whiptail --backtitle "$BACKTITLE" --title "Target Space" --msgbox \
        "Target: ${BASE_DIR}\nFree space: ${avail_h:-?}" 9 70
    fi
  fi

  local bundle="${BASE_DIR%/}/${BUNDLE_PREFIX}-$(hostname)-$(date +%Y_%m_%dT%H_%M)"
  mkdir -p "$bundle/host" "$bundle/guests" || {
    msg_error "Could not create bundle directory"
    return
  }

  # --- Component selection -------------------------------------------------
  local components
  components=$(whiptail --backtitle "$BACKTITLE" --title "Export Components" --checklist \
    "\nSelect what to export into the bundle:" 18 78 7 \
    "hostcfg" "Host configs (/etc/pve, network, storage, users, fw)" ON \
    "etc" "Full /etc tarball (extra safety net)" OFF \
    "ssh" "SSH host keys + /root/.ssh" ON \
    "apt" "APT sources + installed package list" ON \
    "guests" "LXC / VM guests" ON \
    3>&1 1>&2 2>&3) || return

  components="${components//\"/}"

  # --- Host config ---------------------------------------------------------
  if [[ "$components" == *hostcfg* ]]; then
    msg_info "Collecting host configuration"
    mkdir -p "$bundle/host/etc-pve" "$bundle/host/network"
    # pmxcfs content is readable as normal files
    [ -d /etc/pve ] && cp -a /etc/pve/. "$bundle/host/etc-pve/" 2>/dev/null
    [ -f /etc/network/interfaces ] && cp -a /etc/network/interfaces "$bundle/host/network/"
    [ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d "$bundle/host/network/" 2>/dev/null
    [ -f /etc/hostname ] && cp -a /etc/hostname "$bundle/host/"
    [ -f /etc/hosts ] && cp -a /etc/hosts "$bundle/host/"
    [ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf "$bundle/host/" 2>/dev/null
    msg_ok "Collected host configuration"
  fi

  if [[ "$components" == *etc* ]]; then
    msg_info "Creating /etc tarball"
    tar -czf "$bundle/host/etc-full.tar.gz" --absolute-names /etc 2>/dev/null
    msg_ok "Created /etc tarball"
  fi

  if [[ "$components" == *ssh* ]]; then
    msg_info "Collecting SSH keys"
    mkdir -p "$bundle/host/ssh"
    cp -a /etc/ssh "$bundle/host/ssh/etc-ssh" 2>/dev/null
    [ -d /root/.ssh ] && cp -a /root/.ssh "$bundle/host/ssh/root-ssh" 2>/dev/null
    msg_ok "Collected SSH keys"
  fi

  if [[ "$components" == *apt* ]]; then
    msg_info "Collecting APT state"
    mkdir -p "$bundle/host/apt"
    cp -a /etc/apt/sources.list "$bundle/host/apt/" 2>/dev/null
    cp -a /etc/apt/sources.list.d "$bundle/host/apt/" 2>/dev/null
    dpkg --get-selections >"$bundle/host/apt/packages.selections" 2>/dev/null
    msg_ok "Collected APT state"
  fi

  # --- Guests --------------------------------------------------------------
  local guest_method="" guest_mode="snapshot"
  : >"$bundle/guests.tsv"
  if [[ "$components" == *guests* ]]; then
    collect_guests
    if [ "${#GUEST_ROWS[@]}" -eq 0 ]; then
      msg_warn "No guests found on this host"
    else
      # method selection
      guest_method=$(whiptail --backtitle "$BACKTITLE" --title "Guest Export Method" --menu \
        "\nHow should guests be exported?" 14 78 2 \
        "vzdump" "Full portable backup incl. disks (vzdump)" \
        "config" "Configs only (no disk data)" \
        3>&1 1>&2 2>&3) || guest_method=""

      if [ -n "$guest_method" ]; then
        # build checklist
        local menu=() row type id name status
        for row in "${GUEST_ROWS[@]}"; do
          IFS='|' read -r type id name status <<<"$row"
          menu+=("${type}:${id}" "${name} (${status})" ON)
        done

        local selected
        selected=$(whiptail --backtitle "$BACKTITLE" --title "Select Guests" --checklist \
          "\nSelect guests to export:" 20 78 10 "${menu[@]}" 3>&1 1>&2 2>&3) || selected=""
        selected="${selected//\"/}"

        if [ "$guest_method" = "vzdump" ]; then
          guest_mode=$(whiptail --backtitle "$BACKTITLE" --title "vzdump Mode" --menu \
            "\nBackup mode for running guests:" 14 78 3 \
            "snapshot" "Live snapshot (recommended)" \
            "suspend" "Suspend guest during backup" \
            "stop" "Stop guest during backup (most consistent)" \
            3>&1 1>&2 2>&3) || guest_mode="snapshot"
        fi

        local sel type id name status confs
        for sel in $selected; do
          type="${sel%%:*}"
          id="${sel##*:}"
          # resolve name from rows
          name=""
          for row in "${GUEST_ROWS[@]}"; do
            IFS='|' read -r r_type r_id r_name r_status <<<"$row"
            if [ "$r_type" = "$type" ] && [ "$r_id" = "$id" ]; then name="$r_name"; fi
          done

          if [ "$guest_method" = "vzdump" ]; then
            msg_info "vzdump ${type} ${id} (${name})"
            if vzdump "$id" --dumpdir "$bundle/guests" --mode "$guest_mode" --compress zstd &>>"$bundle/guests/vzdump.log"; then
              local file newest=""
              for file in "$bundle/guests"/vzdump-*-"${id}"-*; do
                [ -f "$file" ] || continue
                case "$file" in *.log) continue ;; esac
                [ -z "$newest" ] || [ "$file" -nt "$newest" ] && newest="$file"
              done
              file="$(basename "$newest")"
              echo -e "${type}\t${id}\t${name}\tvzdump\t${file}" >>"$bundle/guests.tsv"
              msg_ok "vzdump ${type} ${id} -> ${file}"
            else
              msg_error "vzdump failed for ${type} ${id} (see vzdump.log)"
            fi
          else
            # config-only
            mkdir -p "$bundle/guests/config"
            if [ "$type" = "vm" ]; then
              confs="/etc/pve/qemu-server/${id}.conf"
            else
              confs="/etc/pve/lxc/${id}.conf"
            fi
            if [ -f "$confs" ]; then
              cp -a "$confs" "$bundle/guests/config/${type}-${id}.conf"
              echo -e "${type}\t${id}\t${name}\tconfig\t${type}-${id}.conf" >>"$bundle/guests.tsv"
              msg_ok "Saved config for ${type} ${id}"
            else
              msg_error "Config not found: ${confs}"
            fi
          fi
        done
      fi
    fi
  fi

  # --- Manifest ------------------------------------------------------------
  {
    echo "EXPORT_HOSTNAME=\"$(hostname)\""
    echo "EXPORT_DATE=\"$(date -Iseconds)\""
    echo "EXPORT_PVE_VERSION=\"$(pveversion | head -n1)\""
    echo "EXPORT_ARCH=\"$(uname -m)\""
    echo "EXPORT_COMPONENTS=\"${components}\""
    echo "EXPORT_GUEST_METHOD=\"${guest_method}\""
  } >"$bundle/manifest.env"

  ip -br link >"$bundle/host/network-links.info" 2>/dev/null
  ip -br addr >"$bundle/host/network-addr.info" 2>/dev/null
  pvesm status >"$bundle/host/storage.info" 2>/dev/null

  header_info
  msg_ok "Export finished"
  echo -e "\nBundle: \e[1;33m${bundle}\e[0m\n"
  if [ "$NFS_MOUNTED" -eq 1 ]; then
    echo -e "Copied to NFS share (will be unmounted on exit).\n"
  fi
  read -rp "Press ENTER to return to the menu..."
}

# ----------------------------------------------------------------------------
# IMPORT
# ----------------------------------------------------------------------------

# Let the user pick a bundle directory inside BASE_DIR.
function pick_bundle {
  local menu=() d count=0
  while IFS= read -r d; do
    [ -f "$d/manifest.env" ] || continue
    menu+=("$d" " ")
    count=$((count + 1))
  done < <(find "$BASE_DIR" -maxdepth 2 -type d -name "${BUNDLE_PREFIX}-*" 2>/dev/null | sort)

  if [ "$count" -eq 0 ]; then
    msg_error "No migration bundles found under ${BASE_DIR}"
    sleep 2
    return 1
  fi

  BUNDLE=$(whiptail --backtitle "$BACKTITLE" --title "Select Bundle" --menu \
    "\nFound migration bundles:" 20 100 10 "${menu[@]}" 3>&1 1>&2 2>&3) || return 1
  return 0
}

function next_free_id {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid 2>/dev/null && return
  fi
  echo "999"
}

function pick_storage {
  local content="$1" menu=() store type
  while read -r store type _; do
    [ -z "$store" ] && continue
    menu+=("$store" "$type")
  done < <(pvesm status ${content:+-content "$content"} 2>/dev/null | awk 'NR>1 {print $1, $2}')
  if [ "${#menu[@]}" -eq 0 ]; then
    echo ""
    return
  fi
  whiptail --backtitle "$BACKTITLE" --title "Target Storage" --menu \
    "\nSelect target storage:" 18 70 8 "${menu[@]}" 3>&1 1>&2 2>&3
}

function import_guests {
  local bundle="$1"
  [ -f "$bundle/guests.tsv" ] || {
    msg_warn "No guests in this bundle"
    sleep 2
    return
  }
  [ -s "$bundle/guests.tsv" ] || {
    msg_warn "No guests in this bundle"
    sleep 2
    return
  }

  local menu=() type id name method file
  while IFS=$'\t' read -r type id name method file; do
    [ -z "$type" ] && continue
    menu+=("${type}:${id}" "${name} [${method}]" ON)
  done <"$bundle/guests.tsv"

  local selected
  selected=$(whiptail --backtitle "$BACKTITLE" --title "Restore Guests" --checklist \
    "\nSelect guests to restore:" 20 78 10 "${menu[@]}" 3>&1 1>&2 2>&3) || return
  selected="${selected//\"/}"
  [ -z "$selected" ] && return

  local default_storage
  default_storage=$(pick_storage "") || default_storage=""

  local sel target_type target_id
  for sel in $selected; do
    target_type="${sel%%:*}"
    local src_id="${sel##*:}"
    # find matching line
    while IFS=$'\t' read -r type id name method file; do
      [ "$type" = "$target_type" ] && [ "$id" = "$src_id" ] || continue

      target_id="$src_id"
      # conflict check
      local exists=0
      if [ "$type" = "vm" ]; then
        qm config "$target_id" &>/dev/null && exists=1
      else
        pct config "$target_id" &>/dev/null && exists=1
      fi
      if [ "$exists" -eq 1 ]; then
        local suggested
        suggested=$(next_free_id)
        target_id=$(whiptail --backtitle "$BACKTITLE" --inputbox \
          "\nID ${src_id} already exists on this host.\nEnter a new ID for ${name}:" 11 68 \
          "$suggested" --title "ID Conflict" 3>&1 1>&2 2>&3) || continue
      fi

      if [ "$method" = "vzdump" ]; then
        local archive="$bundle/guests/$file"
        if [ ! -f "$archive" ]; then
          msg_error "Archive missing: $file"
          continue
        fi
        msg_info "Restoring ${type} ${src_id} -> ${target_id}"
        if [ "$type" = "vm" ]; then
          if qmrestore "$archive" "$target_id" ${default_storage:+--storage "$default_storage"} &>/tmp/host-migrate-restore.log; then
            msg_ok "Restored VM ${target_id}"
          else
            msg_error "qmrestore failed for ${src_id} (see /tmp/host-migrate-restore.log)"
          fi
        else
          if pct restore "$target_id" "$archive" ${default_storage:+--storage "$default_storage"} &>/tmp/host-migrate-restore.log; then
            msg_ok "Restored CT ${target_id}"
          else
            msg_error "pct restore failed for ${src_id} (see /tmp/host-migrate-restore.log)"
          fi
        fi
      else
        # config-only
        local conf="$bundle/guests/config/$file"
        if [ ! -f "$conf" ]; then
          msg_error "Config missing: $file"
          continue
        fi
        local dest
        if [ "$type" = "vm" ]; then
          dest="/etc/pve/qemu-server/${target_id}.conf"
        else
          dest="/etc/pve/lxc/${target_id}.conf"
        fi
        if [ -f "$dest" ]; then
          msg_error "Target config already exists: $dest"
          continue
        fi
        cp "$conf" "$dest"
        msg_ok "Restored config ${type} ${target_id} (disks must exist separately!)"
      fi
    done <"$bundle/guests.tsv"
  done
  read -rp "Press ENTER to continue..."
}

function import_hostcfg {
  local bundle="$1"
  [ -d "$bundle/host" ] || {
    msg_warn "No host configs in this bundle"
    sleep 2
    return
  }

  local sel
  sel=$(whiptail --backtitle "$BACKTITLE" --title "Restore Host Configuration" --checklist \
    "\nSelect host components to restore.\nNETWORK and HOSTNAME are DANGEROUS - read the warnings!" 20 82 8 \
    "storage" "storage.cfg (storage definitions)" OFF \
    "users" "user.cfg / firewall (PVE users + ACLs)" OFF \
    "ssh" "SSH host keys + /root/.ssh" OFF \
    "apt" "APT sources + package selections" OFF \
    "hosts" "/etc/hosts" OFF \
    "network" "/etc/network/interfaces  (!! DANGER !!)" OFF \
    "hostname" "hostname  (!! DANGER !!)" OFF \
    3>&1 1>&2 2>&3) || return
  sel="${sel//\"/}"
  [ -z "$sel" ] && return

  if [[ "$sel" == *storage* ]]; then
    if [ -f "$bundle/host/etc-pve/storage.cfg" ]; then
      cp /etc/pve/storage.cfg "/etc/pve/storage.cfg.bak.$(date +%s)" 2>/dev/null
      cp "$bundle/host/etc-pve/storage.cfg" /etc/pve/storage.cfg
      msg_ok "Restored storage.cfg (review with: pvesm status)"
    else
      msg_error "storage.cfg not in bundle"
    fi
  fi

  if [[ "$sel" == *users* ]]; then
    [ -f "$bundle/host/etc-pve/user.cfg" ] && cp "$bundle/host/etc-pve/user.cfg" /etc/pve/user.cfg && msg_ok "Restored user.cfg"
    [ -d "$bundle/host/etc-pve/firewall" ] && cp -a "$bundle/host/etc-pve/firewall/." /etc/pve/firewall/ 2>/dev/null && msg_ok "Restored firewall rules"
  fi

  if [[ "$sel" == *ssh* ]]; then
    [ -d "$bundle/host/ssh/etc-ssh" ] && cp -a "$bundle/host/ssh/etc-ssh/." /etc/ssh/ 2>/dev/null && msg_ok "Restored /etc/ssh"
    [ -d "$bundle/host/ssh/root-ssh" ] && cp -a "$bundle/host/ssh/root-ssh/." /root/.ssh/ 2>/dev/null && chmod 700 /root/.ssh && msg_ok "Restored /root/.ssh"
  fi

  if [[ "$sel" == *apt* ]]; then
    [ -f "$bundle/host/apt/sources.list" ] && cp "$bundle/host/apt/sources.list" /etc/apt/sources.list && msg_ok "Restored sources.list"
    [ -d "$bundle/host/apt/sources.list.d" ] && cp -a "$bundle/host/apt/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null && msg_ok "Restored sources.list.d"
    msg_warn "Package selections saved as reference: apt/packages.selections (not auto-installed)"
  fi

  if [[ "$sel" == *hosts* ]]; then
    [ -f "$bundle/host/hosts" ] && cp /etc/hosts "/etc/hosts.bak.$(date +%s)" && cp "$bundle/host/hosts" /etc/hosts && msg_ok "Restored /etc/hosts"
  fi

  if [[ "$sel" == *network* ]]; then
    import_network "$bundle"
  fi

  if [[ "$sel" == *hostname* ]]; then
    import_hostname "$bundle"
  fi

  read -rp "Press ENTER to continue..."
}

# Dangerous: applying a foreign network config can disconnect the host.
function import_network {
  local bundle="$1"
  local src="$bundle/host/network/interfaces"
  [ -f "$src" ] || {
    msg_error "No interfaces file in bundle"
    return
  }

  local target_nics source_nics
  target_nics=$(ip -br link 2>/dev/null | awk '{print $1}' | grep -vE '^(lo|vmbr|tap|veth|fwbr|fwln|fwpr|bond)' | tr '\n' ' ')
  source_nics=$(grep -oE 'en[a-z0-9]+|eth[0-9]+' "$src" 2>/dev/null | sort -u | tr '\n' ' ')

  whiptail --backtitle "$BACKTITLE" --title "!! NETWORK WARNING !!" --scrolltext --msgbox \
    "Applying the source network config can leave THIS host without network access if NIC names differ.\n\nSource NICs referenced:\n  ${source_nics:-none detected}\n\nNICs on THIS host:\n  ${target_nics:-none detected}\n\nThe current /etc/network/interfaces will be backed up.\nChanges require a reboot (no auto ifreload)." 22 82

  local mode
  mode=$(whiptail --backtitle "$BACKTITLE" --title "Network Import Mode" --menu \
    "\nHow do you want to handle the network config?" 15 80 2 \
    "template" "Save as /root/migrate-interfaces.template (safe, recommended)" \
    "apply" "Overwrite /etc/network/interfaces (DANGEROUS)" \
    3>&1 1>&2 2>&3) || return

  if [ "$mode" = "template" ]; then
    cp "$src" /root/migrate-interfaces.template
    msg_ok "Saved to /root/migrate-interfaces.template (apply manually after review)"
    return
  fi

  local confirm
  confirm=$(whiptail --backtitle "$BACKTITLE" --inputbox \
    "\nType exactly  APPLY-NETWORK  to overwrite /etc/network/interfaces:" 11 70 \
    --title "Final Confirmation" 3>&1 1>&2 2>&3) || return
  if [ "$confirm" != "APPLY-NETWORK" ]; then
    msg_warn "Confirmation mismatch - network NOT changed"
    return
  fi
  cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
  cp "$src" /etc/network/interfaces
  msg_ok "Overwrote /etc/network/interfaces (backup created)"
  msg_warn "Verify NIC names, then reboot. You may lose connectivity!"
}

# Dangerous: hostname change affects /etc/pve/nodes/<name> layout.
function import_hostname {
  local bundle="$1"
  local src="$bundle/host/hostname"
  [ -f "$src" ] || {
    msg_error "No hostname file in bundle"
    return
  }
  local new_name
  new_name=$(tr -d '[:space:]' <"$src")

  whiptail --backtitle "$BACKTITLE" --title "!! HOSTNAME WARNING !!" --scrolltext --msgbox \
    "Changing the hostname to '${new_name}' affects:\n - /etc/pve/nodes/<name>/ (node-specific guest configs)\n - storage ownership and certificates\n\nRecommended only on a FRESH target before restoring guests.\nA reboot is required afterwards." 18 80

  if ! whiptail --backtitle "$BACKTITLE" --yesno "Set hostname to '${new_name}' now?" 9 70; then
    return
  fi
  cp /etc/hostname "/etc/hostname.bak.$(date +%s)"
  echo "$new_name" >/etc/hostname
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$new_name" 2>/dev/null
  fi
  msg_ok "Hostname set to ${new_name} (reboot required)"
  msg_warn "Node-specific configs under /etc/pve/nodes may need manual migration"
}

function do_import {
  choose_location "Import Source" "/mnt/" || return
  pick_bundle || return

  # Show manifest summary
  # shellcheck disable=SC1090
  source "$BUNDLE/manifest.env" 2>/dev/null
  whiptail --backtitle "$BACKTITLE" --title "Bundle Information" --scrolltext --msgbox \
    "Origin host : ${EXPORT_HOSTNAME:-?}\nExported    : ${EXPORT_DATE:-?}\nPVE version : ${EXPORT_PVE_VERSION:-?}\nArch        : ${EXPORT_ARCH:-?}\nComponents  : ${EXPORT_COMPONENTS:-?}\nGuest method: ${EXPORT_GUEST_METHOD:-?}\n\nThis (target) host: $(hostname) / $(pveversion | head -n1)" 18 82

  # Preflight: storage comparison
  if [ -f "$BUNDLE/host/storage.info" ]; then
    local src_stores cur_stores missing=""
    src_stores=$(awk 'NR>1 {print $1}' "$BUNDLE/host/storage.info" 2>/dev/null)
    cur_stores=$(pvesm status 2>/dev/null | awk 'NR>1 {print $1}')
    local s
    for s in $src_stores; do
      grep -qx "$s" <<<"$cur_stores" || missing+="$s "
    done
    if [ -n "$missing" ]; then
      whiptail --backtitle "$BACKTITLE" --title "Storage Preflight" --msgbox \
        "These storages from the source are MISSING on this host:\n\n  ${missing}\n\nRestores using them may fail. Create them first or pick a different target storage during restore." 14 78
    fi
  fi

  while true; do
    local choice
    choice=$(whiptail --backtitle "$BACKTITLE" --title "Import Menu" --menu \
      "\nBundle: $(basename "$BUNDLE")" 15 78 4 \
      "guests" "Restore LXC / VM guests" \
      "hostcfg" "Restore host configuration (selective)" \
      "back" "Back to main menu" \
      3>&1 1>&2 2>&3) || break
    case "$choice" in
    guests) import_guests "$BUNDLE" ;;
    hostcfg) import_hostcfg "$BUNDLE" ;;
    back) break ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
while true; do
  header_info
  ACTION=$(whiptail --backtitle "$BACKTITLE" --title "Proxmox VE Host Migrate" --menu \
    "\nExport this host or import a bundle onto a new host." 15 78 3 \
    "export" "Export host + guests to a bundle (mount/SSD/NFS)" \
    "import" "Import a bundle onto THIS host" \
    "quit" "Exit" \
    3>&1 1>&2 2>&3) || break

  case "$ACTION" in
  export) do_export ;;
  import) do_import ;;
  quit) break ;;
  esac
done

cleanup
clear
