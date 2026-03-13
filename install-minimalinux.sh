#!/usr/bin/env bash

set -euo pipefail

export LC_MESSAGES=C
export LANG=C

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/minimalinux-install-$(date +%Y%m%d-%H%M%S).log"

MODE="full-install"
TARGET_MNT="/mnt"
DISK=""
ROOT_PART=""
EFI_PART=""
BOOT_PART=""
SWAP_PART=""
BOOTLOADER="grub"
FS_TYPE="ext4"
SWAP_MODE="none"
SWAP_SIZE_GIB="4"
GPU_PROFILE="auto"
BROWSER_CHOICE="firefox"
HOSTNAME="minimalinux"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
USERNAME="user"
USER_PASSWORD=""
ROOT_PASSWORD=""
FIRMWARE_MODE=""
BOOTLOADER_DONE_BY_ARCHINSTALL="0"

msg() {
  printf "\n==> %s\n" "$1"
}

warn() {
  printf "\n[WARN] %s\n" "$1" >&2
}

die() {
  printf "\nERROR: %s\n" "$1" >&2
  printf "See log: %s\n" "$LOG_FILE" >&2
  exit 1
}

show_welcome_banner() {
  cat <<'EOF'
=========================================
  minimaLinux Guided Installer
=========================================
This installer will:
  - Partition and format the selected disk
  - Install Arch Linux + selected bootloader
  - Apply minimaLinux packages and configuration

WARNING: Selected disk data will be permanently erased.
EOF
}

run_preflight_checks() {
  msg "Running preflight checks"

  if ! ping -c 1 -W 2 archlinux.org >/dev/null 2>&1; then
    warn "Internet check failed (archlinux.org unreachable). Install may fail while fetching packages."
  fi

  if [[ ! -d /sys/firmware/efi && ! -d /sys/firmware/efi/efivars ]]; then
    warn "System appears to be booted in BIOS mode."
  fi
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") --disk /dev/nvme0n1 --bootloader grub --hostname minimalinux --username tonekneeo
  $(basename "$0") --provision-existing

Modes:
  default full-install     Full install: partition disk, install base Arch, install bootloader, provision minimaLinux stack.
  --provision-existing     Skip partition/base install; provision minimaLinux stack on current system.

Options:
  --disk <device>          Install target disk (for full-install mode)
  --target-mnt <path>      Mountpoint used during full install (default: /mnt)
  --bootloader <value>     grub | systemd-boot (default: grub)
  --fs <value>             ext4 | btrfs | xfs (default: ext4)
  --swap <value>           none | partition | swapfile (default: none)
  --swap-size <gib>        Swap size in GiB for partition/swapfile (default: 4)
  --hostname <name>
  --username <name>
  --timezone <tz>
  --locale <locale>
  --browser <value>        firefox | chromium | vivaldi | brave | zen | none
  --gpu <value>            auto | amd | intel | nouveau | nvidia-open | nvidia-proprietary | all-open
  -h, --help
EOF
}

init_logging() {
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run this script as root."
}

require_common_tools() {
  command -v pacman >/dev/null 2>&1 || die "pacman is required."
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required."
}

require_full_install_tools() {
  command -v archinstall >/dev/null 2>&1 || die "archinstall is required."
  command -v pacstrap >/dev/null 2>&1 || die "pacstrap is required."
  command -v genfstab >/dev/null 2>&1 || die "genfstab is required."
  command -v arch-chroot >/dev/null 2>&1 || die "arch-chroot is required."
  command -v parted >/dev/null 2>&1 || die "parted is required."
  command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 is required."
  command -v mkfs.btrfs >/dev/null 2>&1 || die "mkfs.btrfs is required."
  command -v mkfs.xfs >/dev/null 2>&1 || die "mkfs.xfs is required."
  command -v mkfs.fat >/dev/null 2>&1 || die "mkfs.fat is required for UEFI installs."
  command -v mkswap >/dev/null 2>&1 || die "mkswap is required."
  command -v lsblk >/dev/null 2>&1 || die "lsblk is required."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provision-existing)
        MODE="provision-existing"
        ;;
      --chroot-finalize)
        MODE="chroot-finalize"
        shift
        [[ $# -gt 0 ]] || die "Missing env file path for --chroot-finalize"
        ENV_FILE="$1"
        ;;
      --disk)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --disk"
        DISK="$1"
        ;;
      --target-mnt)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --target-mnt"
        TARGET_MNT="$1"
        ;;
      --bootloader)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --bootloader"
        BOOTLOADER="$1"
        ;;
      --fs)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --fs"
        FS_TYPE="$1"
        ;;
      --swap)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --swap"
        SWAP_MODE="$1"
        ;;
      --swap-size)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --swap-size"
        SWAP_SIZE_GIB="$1"
        ;;
      --hostname)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --hostname"
        HOSTNAME="$1"
        ;;
      --username)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --username"
        USERNAME="$1"
        ;;
      --timezone)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --timezone"
        TIMEZONE="$1"
        ;;
      --locale)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --locale"
        LOCALE="$1"
        ;;
      --browser)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --browser"
        BROWSER_CHOICE="$1"
        ;;
      --gpu)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --gpu"
        GPU_PROFILE="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

confirm() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "$prompt [y/N]: " answer
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

detect_firmware_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    FIRMWARE_MODE="uefi"
  else
    FIRMWARE_MODE="bios"
  fi
}

partition_path() {
  local disk="$1"
  local number="$2"
  if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
    echo "${disk}p${number}"
  else
    echo "${disk}${number}"
  fi
}

choose_disk_if_missing() {
  if [[ -n "$DISK" ]]; then
    [[ -b "$DISK" ]] || die "Disk not found: $DISK"
    return
  fi

  msg "Select target install disk"

  local -a disk_rows=()
  local -a disk_paths=()
  local line
  local idx
  local choice

  while IFS='|' read -r path size model; do
    [[ -n "$path" ]] || continue
    disk_paths+=("$path")
    disk_rows+=("$path $size ${model:-UnknownModel}")
    done < <(lsblk -J -d -o PATH,SIZE,MODEL,TYPE | python -c "import json,sys; data=json.load(sys.stdin); [print(f\"{(d.get('path') or '')}|{(d.get('size') or '')}|{(d.get('model') or '')}\") for d in data.get('blockdevices', []) if d.get('type')=='disk' and (d.get('path') or '').startswith('/dev/') and not (d.get('path') or '').startswith('/dev/zram') and (d.get('size') or '') not in ('0B','')]" )

  if [[ ${#disk_paths[@]} -eq 0 ]]; then
    warn "Auto-detection found no installable disks."
    read -r -p "Enter install disk manually (example: /dev/vda): " DISK
    [[ -b "$DISK" ]] || die "Disk not found: $DISK"
    return
  fi

  for idx in "${!disk_rows[@]}"; do
    printf "  %d) %s\n" "$((idx + 1))" "${disk_rows[$idx]}"
  done

  while true; do
    read -r -p "Choose disk number [1-${#disk_paths[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disk_paths[@]} )); then
      DISK="${disk_paths[$((choice - 1))]}"
      break
    fi
    echo "Invalid selection."
  done

  [[ -b "$DISK" ]] || die "Disk not found: $DISK"
}

prompt_install_options() {
  local choice

  read -r -p "Hostname [${HOSTNAME}]: " choice
  [[ -n "$choice" ]] && HOSTNAME="$choice"

  read -r -p "Username [${USERNAME}]: " choice
  [[ -n "$choice" ]] && USERNAME="$choice"

  prompt_account_passwords

  read -r -p "Timezone [${TIMEZONE}] (example: America/New_York): " choice
  [[ -n "$choice" ]] && TIMEZONE="$choice"

  read -r -p "Locale [${LOCALE}] (example: en_US.UTF-8): " choice
  [[ -n "$choice" ]] && LOCALE="$choice"

  echo "Bootloader choice:"
  echo "  1) grub"
  if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
    echo "  2) systemd-boot"
  fi
  read -r -p "Select bootloader [${BOOTLOADER}]: " choice
  case "$choice" in
    "" ) ;;
    1|grub) BOOTLOADER="grub" ;;
    2|systemd-boot)
      [[ "$FIRMWARE_MODE" == "uefi" ]] || die "systemd-boot requires UEFI firmware mode."
      BOOTLOADER="systemd-boot"
      ;;
    *) die "Invalid bootloader choice: $choice" ;;
  esac

  echo "Filesystem choice:"
  echo "  1) ext4"
  echo "  2) btrfs"
  echo "  3) xfs"
  read -r -p "Select filesystem [${FS_TYPE}]: " choice
  case "$choice" in
    "" ) ;;
    1|ext4) FS_TYPE="ext4" ;;
    2|btrfs) FS_TYPE="btrfs" ;;
    3|xfs) FS_TYPE="xfs" ;;
    *) die "Invalid filesystem choice: $choice" ;;
  esac

  echo "Swap choice:"
  echo "  1) none"
  echo "  2) partition"
  echo "  3) swapfile"
  read -r -p "Select swap mode [${SWAP_MODE}]: " choice
  case "$choice" in
    "" ) ;;
    1|none) SWAP_MODE="none" ;;
    2|partition) SWAP_MODE="partition" ;;
    3|swapfile) SWAP_MODE="swapfile" ;;
    *) die "Invalid swap mode choice: $choice" ;;
  esac

  if [[ "$SWAP_MODE" != "none" ]]; then
    read -r -p "Swap size in GiB [${SWAP_SIZE_GIB}]: " choice
    [[ -n "$choice" ]] && SWAP_SIZE_GIB="$choice"
  fi

  echo "Browser choice:"
  echo "  1) firefox"
  echo "  2) chromium"
  echo "  3) vivaldi"
  echo "  4) brave"
  echo "  5) zen"
  echo "  6) none"
  read -r -p "Select browser [${BROWSER_CHOICE}]: " choice
  case "$choice" in
    "" ) ;;
    1|firefox) BROWSER_CHOICE="firefox" ;;
    2|chromium) BROWSER_CHOICE="chromium" ;;
    3|vivaldi) BROWSER_CHOICE="vivaldi" ;;
    4|brave) BROWSER_CHOICE="brave" ;;
    5|zen) BROWSER_CHOICE="zen" ;;
    6|none) BROWSER_CHOICE="none" ;;
    *) die "Invalid browser choice: $choice" ;;
  esac

  echo "GPU profile:"
  echo "  1) auto"
  echo "  2) amd"
  echo "  3) intel"
  echo "  4) nouveau"
  echo "  5) nvidia-open"
  echo "  6) nvidia-proprietary"
  echo "  7) all-open"
  read -r -p "Select GPU profile [${GPU_PROFILE}]: " choice
  case "$choice" in
    "" ) ;;
    1|auto) GPU_PROFILE="auto" ;;
    2|amd) GPU_PROFILE="amd" ;;
    3|intel) GPU_PROFILE="intel" ;;
    4|nouveau) GPU_PROFILE="nouveau" ;;
    5|nvidia-open) GPU_PROFILE="nvidia-open" ;;
    6|nvidia-proprietary) GPU_PROFILE="nvidia-proprietary" ;;
    7|all-open) GPU_PROFILE="all-open" ;;
    *) die "Invalid GPU profile choice: $choice" ;;
  esac

}

prompt_account_passwords() {
  local confirm_value

  while true; do
    read -r -s -p "Set root password: " ROOT_PASSWORD
    echo
    read -r -s -p "Confirm root password: " confirm_value
    echo
    [[ "$ROOT_PASSWORD" == "$confirm_value" && -n "$ROOT_PASSWORD" ]] && break
    echo "Passwords did not match. Try again."
  done

  while true; do
    read -r -s -p "Set password for ${USERNAME}: " USER_PASSWORD
    echo
    read -r -s -p "Confirm password for ${USERNAME}: " confirm_value
    echo
    [[ "$USER_PASSWORD" == "$confirm_value" && -n "$USER_PASSWORD" ]] && break
    echo "Passwords did not match. Try again."
  done
}

validate_install_choices() {
  case "$FS_TYPE" in
    ext4|btrfs|xfs) ;;
    *) die "Unsupported filesystem: ${FS_TYPE}" ;;
  esac

  case "$SWAP_MODE" in
    none|partition|swapfile) ;;
    *) die "Unsupported swap mode: ${SWAP_MODE}" ;;
  esac

  [[ "$SWAP_SIZE_GIB" =~ ^[0-9]+$ ]] || die "Swap size must be a whole number in GiB."
  [[ "$SWAP_SIZE_GIB" -ge 1 ]] || die "Swap size must be at least 1 GiB."
}

format_root_filesystem() {
  case "$FS_TYPE" in
    ext4)
      mkfs.ext4 -F "$ROOT_PART"
      ;;
    btrfs)
      mkfs.btrfs -f "$ROOT_PART"
      ;;
    xfs)
      mkfs.xfs -f "$ROOT_PART"
      ;;
    *)
      die "Unsupported filesystem: ${FS_TYPE}"
      ;;
  esac
}

mount_root_filesystem() {
  case "$FS_TYPE" in
    btrfs)
      mount -o compress=zstd:1 "$ROOT_PART" "$TARGET_MNT"
      ;;
    *)
      mount "$ROOT_PART" "$TARGET_MNT"
      ;;
  esac
}

setup_swap_for_target() {
  case "$SWAP_MODE" in
    none)
      return
      ;;
    partition)
      [[ -n "$SWAP_PART" ]] || die "Swap partition mode selected but swap partition not found."
      mkswap "$SWAP_PART"
      swapon "$SWAP_PART"
      ;;
    swapfile)
      if [[ "$FS_TYPE" == "btrfs" ]]; then
        install -d "$TARGET_MNT/swap"
        chattr +C "$TARGET_MNT/swap" 2>/dev/null || true
        btrfs property set "$TARGET_MNT/swap" compression none >/dev/null 2>&1 || true

        if command -v btrfs >/dev/null 2>&1 && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
          btrfs filesystem mkswapfile --size "${SWAP_SIZE_GIB}g" "$TARGET_MNT/swap/swapfile"
        else
          truncate -s 0 "$TARGET_MNT/swap/swapfile"
          chattr +C "$TARGET_MNT/swap/swapfile" 2>/dev/null || true
          dd if=/dev/zero of="$TARGET_MNT/swap/swapfile" bs=1M count=$((SWAP_SIZE_GIB * 1024)) status=progress
          chmod 600 "$TARGET_MNT/swap/swapfile"
          mkswap "$TARGET_MNT/swap/swapfile"
        fi

        chmod 600 "$TARGET_MNT/swap/swapfile"
        swapon "$TARGET_MNT/swap/swapfile"
      else
        fallocate -l "${SWAP_SIZE_GIB}G" "$TARGET_MNT/swapfile" 2>/dev/null || dd if=/dev/zero of="$TARGET_MNT/swapfile" bs=1M count=$((SWAP_SIZE_GIB * 1024)) status=progress
        chmod 600 "$TARGET_MNT/swapfile"
        mkswap "$TARGET_MNT/swapfile"
        swapon "$TARGET_MNT/swapfile"
      fi
      ;;
    *)
      die "Unsupported swap mode: ${SWAP_MODE}"
      ;;
  esac
}

partition_and_mount_disk() {
  msg "Partitioning disk: ${DISK}"

  if ! confirm "This will erase all data on ${DISK}. Continue?"; then
    die "Aborted by user."
  fi

  local confirmation_input
  read -r -p "Type the exact disk path to confirm (${DISK}): " confirmation_input
  [[ "$confirmation_input" == "$DISK" ]] || die "Disk confirmation mismatch. Aborted."

  swapoff -a || true
  umount -R "$TARGET_MNT" >/dev/null 2>&1 || true

  if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" set 1 esp on
    if [[ "$SWAP_MODE" == "partition" ]]; then
      parted -s "$DISK" mkpart primary ext4 1025MiB "-$((SWAP_SIZE_GIB))GiB"
      parted -s "$DISK" mkpart primary linux-swap "-$((SWAP_SIZE_GIB))GiB" 100%
    else
      parted -s "$DISK" mkpart primary ext4 1025MiB 100%
    fi
    partprobe "$DISK" || true
    udevadm settle || true
    EFI_PART="$(partition_path "$DISK" 1)"
    BOOT_PART="$EFI_PART"
    ROOT_PART="$(partition_path "$DISK" 2)"
    if [[ "$SWAP_MODE" == "partition" ]]; then
      SWAP_PART="$(partition_path "$DISK" 3)"
    fi

    mkfs.fat -F32 "$EFI_PART"
    format_root_filesystem

    mount_root_filesystem
    mkdir -p "$TARGET_MNT/boot"
    mount "$EFI_PART" "$TARGET_MNT/boot"
  else
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary ext4 1MiB 1025MiB
    if [[ "$SWAP_MODE" == "partition" ]]; then
      parted -s "$DISK" mkpart primary ext4 1025MiB "-$((SWAP_SIZE_GIB))GiB"
      parted -s "$DISK" mkpart primary linux-swap "-$((SWAP_SIZE_GIB))GiB" 100%
    else
      parted -s "$DISK" mkpart primary ext4 1025MiB 100%
    fi
    parted -s "$DISK" set 1 boot on
    partprobe "$DISK" || true
    udevadm settle || true
    BOOT_PART="$(partition_path "$DISK" 1)"
    ROOT_PART="$(partition_path "$DISK" 2)"
    if [[ "$SWAP_MODE" == "partition" ]]; then
      SWAP_PART="$(partition_path "$DISK" 3)"
    fi

    mkfs.ext4 -F "$BOOT_PART"
    format_root_filesystem
    mount_root_filesystem
    mkdir -p "$TARGET_MNT/boot"
    mount "$BOOT_PART" "$TARGET_MNT/boot"
  fi
}

install_arch_base() {
  msg "Installing Arch base system"

  local base_pkgs=(base linux linux-firmware sudo networkmanager grub)
  if [[ "$FS_TYPE" == "btrfs" ]]; then
    base_pkgs+=(btrfs-progs)
  elif [[ "$FS_TYPE" == "xfs" ]]; then
    base_pkgs+=(xfsprogs)
  fi
  if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
    base_pkgs+=(efibootmgr dosfstools mtools)
  fi

  pacstrap -K "$TARGET_MNT" "${base_pkgs[@]}"
  setup_swap_for_target
  genfstab -U "$TARGET_MNT" > "$TARGET_MNT/etc/fstab"

  if [[ "$SWAP_MODE" == "swapfile" ]]; then
    local swapfile_path="/swapfile"
    if [[ "$FS_TYPE" == "btrfs" ]]; then
      swapfile_path="/swap/swapfile"
    fi

    if ! grep -qE "^[^#].*${swapfile_path//\//\\/}[[:space:]]+none[[:space:]]+swap" "$TARGET_MNT/etc/fstab"; then
      echo "${swapfile_path} none swap defaults 0 0" >> "$TARGET_MNT/etc/fstab"
    fi
  fi
}

ensure_swap_fstab_entry_in_target() {
  if [[ "$SWAP_MODE" == "swapfile" ]]; then
    local swapfile_path="/swapfile"
    if [[ "$FS_TYPE" == "btrfs" ]]; then
      swapfile_path="/swap/swapfile"
    fi

    if ! grep -qE "^[^#].*${swapfile_path//\//\\/}[[:space:]]+none[[:space:]]+swap" "$TARGET_MNT/etc/fstab"; then
      echo "${swapfile_path} none swap defaults 0 0" >> "$TARGET_MNT/etc/fstab"
    fi
  elif [[ "$SWAP_MODE" == "partition" && -n "$SWAP_PART" ]]; then
    local swap_uuid
    swap_uuid="$(blkid -s UUID -o value "$SWAP_PART" 2>/dev/null || true)"
    if [[ -n "$swap_uuid" ]] && ! grep -q "$swap_uuid" "$TARGET_MNT/etc/fstab"; then
      echo "UUID=${swap_uuid} none swap defaults 0 0" >> "$TARGET_MNT/etc/fstab"
    fi
  fi
}

run_archinstall_on_premounted_target() {
  msg "Running archinstall guided install on pre-mounted target"

  local config_file
  local locale_lang
  local bootloader_name

  config_file="$(mktemp /tmp/minimalinux-archinstall-config.XXXXXX.json)"
  locale_lang="${LOCALE%%.*}"

  case "$BOOTLOADER" in
    grub) bootloader_name="Grub" ;;
    systemd-boot) bootloader_name="Systemd-boot" ;;
    *) die "Unsupported bootloader for archinstall config: ${BOOTLOADER}" ;;
  esac

  cat > "$config_file" <<EOF
{
  "archinstall-language": "English",
  "bootloader_config": {
    "bootloader": "${bootloader_name}",
    "uki": false,
    "removable": true
  },
  "disk_config": {
    "config_type": "pre_mounted_config",
    "mountpoint": "${TARGET_MNT}"
  },
  "hostname": "${HOSTNAME}",
  "kernels": ["linux"],
  "locale_config": {
    "kb_layout": "us",
    "sys_enc": "UTF-8",
    "sys_lang": "${locale_lang}"
  },
  "ntp": true,
  "packages": [],
  "script": "guided",
  "silent": true,
  "swap": {
    "enabled": false
  },
  "timezone": "${TIMEZONE}"
}
EOF

  archinstall --config "$config_file" --silent --mountpoint "$TARGET_MNT" --skip-version-check

  BOOTLOADER_DONE_BY_ARCHINSTALL="1"
}

write_install_env() {
  cat > "$TARGET_MNT/root/minimalinux-install.env" <<EOF
DISK='${DISK}'
ROOT_PART='${ROOT_PART}'
EFI_PART='${EFI_PART}'
BOOT_PART='${BOOT_PART}'
SWAP_PART='${SWAP_PART}'
BOOTLOADER='${BOOTLOADER}'
BOOTLOADER_DONE_BY_ARCHINSTALL='${BOOTLOADER_DONE_BY_ARCHINSTALL}'
FS_TYPE='${FS_TYPE}'
SWAP_MODE='${SWAP_MODE}'
SWAP_SIZE_GIB='${SWAP_SIZE_GIB}'
GPU_PROFILE='${GPU_PROFILE}'
BROWSER_CHOICE='${BROWSER_CHOICE}'
HOSTNAME='${HOSTNAME}'
TIMEZONE='${TIMEZONE}'
LOCALE='${LOCALE}'
USERNAME='${USERNAME}'
USER_PASSWORD='${USER_PASSWORD}'
ROOT_PASSWORD='${ROOT_PASSWORD}'
FIRMWARE_MODE='${FIRMWARE_MODE}'
EOF
  chmod 600 "$TARGET_MNT/root/minimalinux-install.env"
}

stage_assets_for_chroot() {
  msg "Staging installer assets in target root"
  cp "$SCRIPT_PATH" "$TARGET_MNT/root/install-minimalinux.sh"
  chmod +x "$TARGET_MNT/root/install-minimalinux.sh"

  install -d "$TARGET_MNT/root/minimalinux-assets"
  if [[ -d "$SCRIPT_DIR/hypr" ]]; then
    cp -a "$SCRIPT_DIR/hypr" "$TARGET_MNT/root/minimalinux-assets/"
  fi

  write_install_env
}

run_chroot_finalize() {
  msg "Running chroot configuration"
  arch-chroot "$TARGET_MNT" /root/install-minimalinux.sh --chroot-finalize /root/minimalinux-install.env
}

configure_base_system() {
  msg "Configuring base system"

  [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Timezone not found: ${TIMEZONE}"
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  hwclock --systohc

  sed -i -E "s|^#(${LOCALE}[[:space:]]+UTF-8)|\1|" /etc/locale.gen || true
  grep -Eq "^${LOCALE}[[:space:]]+UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
  locale-gen
  echo "LANG=${LOCALE}" > /etc/locale.conf

  echo "$HOSTNAME" > /etc/hostname
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

  echo "root:${ROOT_PASSWORD}" | chpasswd

  if ! id -u "$USERNAME" >/dev/null 2>&1; then
    useradd -m -G wheel -s /bin/bash "$USERNAME"
  fi
  echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

  sed -i -E 's|^# %wheel ALL=\(ALL:ALL\) ALL|%wheel ALL=(ALL:ALL) ALL|' /etc/sudoers
}

ensure_multilib() {
  msg "Ensuring multilib is enabled"
  if ! grep -Eq '^[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
    if grep -Eq '^[[:space:]]*#\[multilib\][[:space:]]*$' /etc/pacman.conf; then
      sed -i -E '/^[[:space:]]*#\[multilib\][[:space:]]*$/,/^[[:space:]]*#Include[[:space:]]*=[[:space:]]*\/etc\/pacman\.d\/mirrorlist[[:space:]]*$/ s/^[[:space:]]*#//' /etc/pacman.conf
    else
      printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    fi
  fi
}

setup_chaotic_aur() {
  msg "Configuring Chaotic-AUR"

  if ! grep -Fq '[chaotic-aur]' /etc/pacman.conf; then
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman -U --noconfirm https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst
    pacman -U --noconfirm https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst
  fi

  sed -i '/^\[chaotic-aur\]/,/^$/d' /etc/pacman.conf
  printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf

  pacman -Syy
}

install_yay() {
  msg "Installing yay"
  if command -v yay >/dev/null 2>&1; then
    return
  fi

  pacman -S --noconfirm --needed base-devel git go
  id -u aurbuilder >/dev/null 2>&1 || useradd -m -s /usr/bin/bash aurbuilder
  rm -rf /tmp/yay-aur
  install -d -o aurbuilder -g aurbuilder /tmp/yay-aur

  runuser -u aurbuilder -- bash -lc '
    set -euo pipefail
    cd /tmp/yay-aur
    git clone --depth 1 https://aur.archlinux.org/yay.git .
    makepkg --noconfirm --needed
  '

  local pkg_file
  pkg_file="$(find /tmp/yay-aur -maxdepth 1 -type f -name 'yay-*.pkg.tar.*' ! -name '*-debug-*' | head -n 1)"
  [[ -n "$pkg_file" ]] || die "Failed to build yay package."
  pacman -U --noconfirm "$pkg_file"
}

install_aur_packages_with_builder() {
  local -a pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return

  install -d /etc/sudoers.d
  echo 'aurbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-aurbuilder-pacman
  chmod 440 /etc/sudoers.d/99-aurbuilder-pacman

  runuser -u aurbuilder -- env HOME=/home/aurbuilder bash -lc "yay -S --noconfirm --needed ${pkgs[*]}"

  rm -f /etc/sudoers.d/99-aurbuilder-pacman
}

cleanup_yay_build_user() {
  msg "Cleaning yay build artifacts"
  rm -rf /tmp/yay-aur
  if id -u aurbuilder >/dev/null 2>&1; then
    userdel -r aurbuilder >/dev/null 2>&1 || userdel aurbuilder >/dev/null 2>&1 || true
  fi
}

install_core_packages() {
  msg "Installing core packages"
  pacman -S --noconfirm --needed \
    polkit-gnome gnome-keyring hyprlock hypridle pavucontrol playerctl wlsunset fish fastfetch \
    bluez bluez-utils blueman xdg-desktop-portal-gtk xdg-user-dirs power-profiles-daemon upower flatpak
}

install_ui_packages() {
  msg "Installing UI and desktop utility packages"
  pacman -S --noconfirm --needed \
    satty grim slurp hyprshot nwg-look nwg-displays hyprland-protocols qt6ct matugen adw-gtk-theme \
    yaru-icon-theme humanity-icon-theme bibata-cursor-theme gcolor3 loupe kitty-shell-integration \
    kitty-terminfo gpu-screen-recorder
}

install_app_packages() {
  msg "Installing app and filesystem packages"
  pacman -S --noconfirm --needed \
    thunar thunar-media-tags-plugin thunar-shares-plugin thunar-vcs-plugin thunar-volman \
    thunar-archive-plugin gnome-disk-utility gedit obsidian gnome-calculator file-roller unrar unzip \
    7zip tumbler libopenraw libgsf poppler-glib ffmpegthumbnailer freetype2 libgepub gvfs ntfs-3g \
    dosfstools exfatprogs starship cava easyeffects lsp-plugins-lv2 calf cpupower update-grub
}

install_hyprland_stack() {
  msg "Installing Arch Hyprland baseline stack"
  if pacman -Q jack2 >/dev/null 2>&1; then
    pacman -R --noconfirm jack2 || pacman -Rdd --noconfirm jack2
  fi

  pacman -S --noconfirm --needed \
    hyprland dunst kitty uwsm dolphin wofi xdg-desktop-portal-hyprland qt5-wayland qt6-wayland \
    polkit-kde-agent grim slurp xorg-server nano vim openssh htop wget iwd wireless_tools smartmontools \
    xdg-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack gst-plugin-pipewire libpulse wireplumber
}

install_dev_packages() {
  msg "Installing developer packages"
  pacman -S --noconfirm --needed base-devel clang cmake go rust pkgconf meson ninja ddcutil
}

install_gaming_packages() {
  msg "Installing gaming and streaming packages"
  pacman -S --noconfirm --needed \
    steam mangohud lib32-mangohud wine winetricks protontricks lutris heroic-games-launcher-bin \
    jdk21-openjdk ttf-ms-fonts obs-studio-stable
}

package_available() {
  pacman -Si "$1" >/dev/null 2>&1
}

detect_gpu_vendors() {
  local vendors=""
  local vendor_id
  for vfile in /sys/class/drm/card*/device/vendor; do
    [[ -f "$vfile" ]] || continue
    vendor_id="$(tr '[:upper:]' '[:lower:]' < "$vfile")"
    case "$vendor_id" in
      0x10de) [[ " $vendors " == *" nvidia "* ]] || vendors="$vendors nvidia" ;;
      0x1002|0x1022) [[ " $vendors " == *" amd "* ]] || vendors="$vendors amd" ;;
      0x8086) [[ " $vendors " == *" intel "* ]] || vendors="$vendors intel" ;;
    esac
  done
  echo "$vendors"
}

install_gpu_profile() {
  msg "Installing GPU drivers/profile: ${GPU_PROFILE}"

  local profile="$GPU_PROFILE"
  local vendors
  local -a pkgs=()

  vendors="$(detect_gpu_vendors)"

  pkgs+=(mesa vulkan-icd-loader libva-mesa-driver lib32-mesa lib32-vulkan-icd-loader lib32-libva)

  if [[ "$profile" == "auto" ]]; then
    if [[ " $vendors " == *" amd "* ]]; then
      profile="amd"
    elif [[ " $vendors " == *" intel "* ]]; then
      profile="intel"
    elif [[ " $vendors " == *" nvidia "* ]]; then
      profile="nvidia-proprietary"
    else
      profile="all-open"
    fi
  fi

  case "$profile" in
    amd)
      pkgs+=(vulkan-radeon lib32-vulkan-radeon)
      ;;
    intel)
      pkgs+=(vulkan-intel lib32-vulkan-intel intel-media-driver)
      ;;
    nouveau)
      pkgs+=(vulkan-nouveau lib32-vulkan-nouveau)
      ;;
    nvidia-open)
      if package_available nvidia-open-dkms; then
        pkgs+=(nvidia-open-dkms)
      elif package_available nvidia-open; then
        pkgs+=(nvidia-open)
      fi
      pkgs+=(nvidia-utils lib32-nvidia-utils nvidia-settings libva-nvidia-driver)
      ;;
    nvidia-proprietary)
      if package_available nvidia-dkms; then
        pkgs+=(nvidia-dkms)
      elif package_available nvidia; then
        pkgs+=(nvidia)
      elif package_available nvidia-open-dkms; then
        pkgs+=(nvidia-open-dkms)
      fi
      pkgs+=(nvidia-utils lib32-nvidia-utils nvidia-settings libva-nvidia-driver)
      ;;
    all-open)
      pkgs+=(vulkan-radeon lib32-vulkan-radeon vulkan-intel lib32-vulkan-intel intel-media-driver vulkan-nouveau lib32-vulkan-nouveau)
      ;;
    *)
      die "Unsupported GPU profile: $profile"
      ;;
  esac

  pacman -S --noconfirm --needed "${pkgs[@]}"

  if [[ "$profile" == nvidia* ]]; then
    install -d /etc/modprobe.d
    echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
  fi
}

install_minimalinux_extras() {
  msg "Installing minimaLinux extras"
  pacman -S --noconfirm --needed noctalia-shell noctalia-qs || true
  install_aur_packages_with_builder upscayl-desktop-git video-downloader mission-center protonplus deadbeef
}

install_selected_browser() {
  msg "Installing browser choice: ${BROWSER_CHOICE}"
  case "$BROWSER_CHOICE" in
    firefox)
      pacman -S --noconfirm --needed firefox
      ;;
    chromium)
      pacman -S --noconfirm --needed chromium
      ;;
    vivaldi)
      pacman -S --noconfirm --needed vivaldi || install_aur_packages_with_builder vivaldi
      ;;
    brave)
      pacman -S --noconfirm --needed brave-bin || install_aur_packages_with_builder brave-bin
      ;;
    zen)
      pacman -S --noconfirm --needed zen-browser-bin || install_aur_packages_with_builder zen-browser-bin
      ;;
    none)
      ;;
    *)
      die "Unsupported browser choice: ${BROWSER_CHOICE}"
      ;;
  esac
}

apply_hypr_config_assets() {
  local src="/root/minimalinux-assets/hypr"
  [[ -d "$src" ]] || return

  msg "Applying Hypr config assets for ${USERNAME}"
  install -d "/home/${USERNAME}/.config/hypr"
  cp -a "$src"/* "/home/${USERNAME}/.config/hypr/"
  chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

  if [[ -d "/home/${USERNAME}/.config/hypr/Scripts" ]]; then
    find "/home/${USERNAME}/.config/hypr/Scripts" -type f -exec chmod +x {} \;
  fi
}

setup_i2c() {
  msg "Configuring i2c-dev"
  modprobe i2c-dev || true
  echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
  usermod -aG i2c "$USERNAME" || true
}

setup_services() {
  msg "Enabling services"
  pacman -S --noconfirm --needed networkmanager wpa_supplicant network-manager-applet sddm
  systemctl enable NetworkManager.service
  systemctl enable sddm
  systemctl enable bluetooth
  systemctl set-default graphical.target
}

configure_grub_defaults() {
  local defaults="/etc/default/grub"
  if [[ -f "$defaults" ]]; then
    if grep -qE '^GRUB_DISTRIBUTOR=' "$defaults"; then
      sed -i -E 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="minimaLinux"|' "$defaults"
    else
      echo 'GRUB_DISTRIBUTOR="minimaLinux"' >> "$defaults"
    fi
  fi
}

install_bootloader() {
  msg "Installing bootloader: ${BOOTLOADER}"

  case "$BOOTLOADER" in
    grub)
      configure_grub_defaults
      if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=minimaLinux --recheck
      else
        local install_disk="$DISK"
        local parent_kname=""

        if [[ -n "$ROOT_PART" && -b "$ROOT_PART" ]] && command -v lsblk >/dev/null 2>&1; then
          parent_kname="$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null | head -n 1 || true)"
          if [[ -n "$parent_kname" ]]; then
            install_disk="/dev/${parent_kname}"
          fi
        fi

        [[ -b "$install_disk" ]] || die "Disk not available in chroot for BIOS grub install: ${install_disk}"

        msg "BIOS GRUB target disk: ${install_disk} (root partition: ${ROOT_PART})"

        grub-install --target=i386-pc --boot-directory=/boot --recheck "$install_disk" \
          || grub-install --target=i386-pc --boot-directory=/boot --recheck --force "$install_disk"

        if ! dd if="$install_disk" bs=440 count=1 2>/dev/null | strings | grep -q 'GRUB'; then
          msg "MBR does not contain GRUB signature after initial install; retrying with explicit modules"
          grub-install --target=i386-pc --boot-directory=/boot --recheck --force \
            --modules="part_msdos ext2 biosdisk" "$install_disk"
        fi

        if command -v hexdump >/dev/null 2>&1; then
          local mbr_sig
          mbr_sig="$(dd if="$install_disk" bs=440 count=1 2>/dev/null | hexdump -ve '1/1 "%02x"' | tr -d '0')"
          [[ -n "$mbr_sig" ]] || die "MBR boot code appears empty on ${install_disk} after grub-install."
        fi

        dd if="$install_disk" bs=440 count=1 2>/dev/null | strings | grep -q 'GRUB' \
          || die "GRUB signature not found in MBR boot code on ${install_disk}."
      fi
      grub-mkconfig -o /boot/grub/grub.cfg
      [[ -s /boot/grub/grub.cfg ]] || die "GRUB config was not generated."
      [[ -f /boot/grub/i386-pc/core.img || "$FIRMWARE_MODE" == "uefi" ]] || die "GRUB BIOS core image missing; bootloader install failed."
      ;;
    systemd-boot)
      [[ "$FIRMWARE_MODE" == "uefi" ]] || die "systemd-boot requires UEFI mode"
      bootctl install
      mkdir -p /boot/loader/entries
      cat > /boot/loader/loader.conf <<EOF
default minimalinux
timeout 3
editor no
EOF
      local root_uuid
      local root_ref
      root_uuid="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
      if [[ -n "$root_uuid" ]]; then
        root_ref="PARTUUID=${root_uuid}"
      else
        root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
        root_ref="UUID=${root_uuid}"
      fi
      cat > /boot/loader/entries/minimalinux.conf <<EOF
title minimaLinux
linux /vmlinuz-linux
initrd /initramfs-linux.img
    options root=${root_ref} rw
EOF
      ;;
    *)
      die "Unsupported bootloader: ${BOOTLOADER}"
      ;;
  esac
}

provision_minimalinux_stack() {
  require_common_tools
  ensure_multilib
  setup_chaotic_aur
  install_yay
  install_core_packages
  install_ui_packages
  install_app_packages
  install_hyprland_stack
  install_dev_packages
  install_gaming_packages
  install_gpu_profile
  install_minimalinux_extras
  install_selected_browser
  setup_i2c
  setup_services
  cleanup_yay_build_user
}

finalize_in_chroot() {
  [[ -f "${ENV_FILE}" ]] || die "Env file not found: ${ENV_FILE}"
  source "${ENV_FILE}"
  configure_base_system
  provision_minimalinux_stack
  apply_hypr_config_assets
  if [[ "${BOOTLOADER_DONE_BY_ARCHINSTALL:-0}" != "1" ]]; then
    install_bootloader
  else
    msg "Bootloader was already installed by archinstall; skipping manual bootloader step"
  fi
  msg "Chroot install complete"
}

run_full_install() {
  require_full_install_tools
  show_welcome_banner
  run_preflight_checks
  detect_firmware_mode
  choose_disk_if_missing
  prompt_install_options
  validate_install_choices

  msg "Install summary"
  echo "Disk:       ${DISK}"
  echo "Firmware:   ${FIRMWARE_MODE}"
  echo "Bootloader: ${BOOTLOADER}"
  echo "Filesystem: ${FS_TYPE}"
  echo "Swap mode:  ${SWAP_MODE}"
  if [[ "$SWAP_MODE" != "none" ]]; then
    echo "Swap size:  ${SWAP_SIZE_GIB} GiB"
  fi
  echo "Hostname:   ${HOSTNAME}"
  echo "Username:   ${USERNAME}"
  echo "Timezone:   ${TIMEZONE}"
  echo "Locale:     ${LOCALE}"
  echo "Browser:    ${BROWSER_CHOICE}"
  echo "GPU:        ${GPU_PROFILE}"

  confirm "Proceed with installation?" || die "Aborted by user."

  partition_and_mount_disk
  setup_swap_for_target
  run_archinstall_on_premounted_target
  ensure_swap_fstab_entry_in_target
  stage_assets_for_chroot
  run_chroot_finalize

  msg "Full install finished"
  cat <<EOF
Installation completed.

Before rebooting, recommended quick checks:
  - lsblk -f
  - cat ${TARGET_MNT}/etc/fstab
  - Ensure boot files exist under ${TARGET_MNT}/boot

Then reboot into your new minimaLinux system.
EOF
}

main() {
  parse_args "$@"

  require_root
  init_logging

  msg "Log file: ${LOG_FILE}"

  case "$MODE" in
    full-install)
      run_full_install
      ;;
    provision-existing)
      provision_minimalinux_stack
      ;;
    chroot-finalize)
      finalize_in_chroot
      ;;
    *)
      die "Unsupported mode: $MODE"
      ;;
  esac
}

main "$@"
