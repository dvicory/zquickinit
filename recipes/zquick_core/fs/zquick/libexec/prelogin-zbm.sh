#!/bin/bash
# vim: softtabstop=2 shiftwidth=2 expandtab

# This file was mostly copied and serves the same function as "zfsbootmenu-init" from the zfsbootmenu project
# It has been adapted to exit instead of launch an emergecy shell

# disable ctrl-c (SIGINT)
trap '' SIGINT

# Source functional libraries, logging and configuration
sources=(
  /lib/profiling-lib.sh
  /etc/zfsbootmenu.conf
  /lib/zfsbootmenu-kcl.sh
  /lib/zfsbootmenu-core.sh
  /lib/kmsg-log-lib.sh
  /etc/profile
)

stop() {
  tput clear
  echo $(colorize green "zquickinit prelogin finished")${1:+: $1}
  echo
  read -rs -t3 -n1 -p $'Press any key or wait to continue ...\n\n'
  echo
  exit 1
}

for src in "${sources[@]}"; do
  # shellcheck disable=SC1090
  if ! source "${src}" >/dev/null 2>&1; then
    echo -e "\033[0;31mWARNING: ${src} was not sourced; unable to proceed\033[0m"
    exec /bin/bash
  fi
done

unset src sources

mkdir -p "${BASE:=/zfsbootmenu}"

# explicitly mount efivarfs as read-only
mount_efivarfs "ro"

# Attempt to load spl normally
if ! _modload="$(modprobe spl 2>&1)"; then
  zdebug "${_modload}"

  # Capture the filename for spl.ko
  _modfilename="$(modinfo -F filename spl)"

  if [ -n "${_modfilename}" ]; then
    zinfo "loading ${_modfilename}"

    # Load with a hostid of 0, so that /etc/hostid takes precedence and
    # invalid spl.spl_hostid values are ignored

    # There's a race condition between udev and insmod spl
    # insmod failures are no longer a hard failure - they can be because
    #  1. spl.ko is already loaded because of the race condition
    #  2. there's an invalid parameter or value for spl.ko

    if ! _modload="$(insmod "${_modfilename}" "spl_hostid=0" 2>&1)"; then
      zwarn "${_modload}"
      zwarn "unable to load SPL kernel module; attempting to load ZFS anyway"
    fi
  fi
fi

if ! _modload="$(modprobe zfs 2>&1)"; then
  zerror "${_modload}"
  stop "unable to load ZFS kernel modules"
fi

udevadm settle

# Write out a default or overridden hostid
if [ -n "${spl_hostid}" ]; then
  if write_hostid "${spl_hostid}"; then
    zinfo "writing /etc/hostid from command line: ${spl_hostid}"
  else
    # write_hostid logs an error for us, just note the new value
    # shellcheck disable=SC2154
    write_hostid "${default_hostid}"
    zinfo "defaulting hostid to ${default_hostid}"
  fi
elif [ ! -e /etc/hostid ]; then
  zinfo "no hostid found on kernel command line or /etc/hostid"
  # shellcheck disable=SC2154
  zinfo "defaulting hostid to ${default_hostid}"
  write_hostid "${default_hostid}"
fi

# Import ZBM hooks from an external root, if they exist
if [ -n "${zbm_hook_root}" ]; then
  import_zbm_hooks "${zbm_hook_root}"
fi

# Remove the executable bit from any hooks in the skip list
if zbm_skip_hooks="$(get_zbm_arg zbm.skip_hooks)" && [ -n "${zbm_skip_hooks}" ]; then
  zdebug "processing hook skip directives: ${zbm_skip_hooks}"
  IFS=',' read -r -a zbm_skip_hooks <<<"${zbm_skip_hooks}"
  for _skip in "${zbm_skip_hooks[@]}"; do
    [ -n "${_skip}" ] || continue

    for _hook in /libexec/{early-setup,setup,teardown}.d/*; do
      [ -e "${_hook}" ] || continue
      if [ "${_skip}" = "${_hook##*/}" ]; then
        zinfo "Disabling hook: ${_hook}"
        chmod 000 "${_hook}"
      fi
    done
  done
  unset _hook _skip
fi

# Run early setup hooks, if they exist
tput clear
/libexec/zfsbootmenu-run-hooks "early-setup.d"

# Prefer a specific pool when checking for a bootfs value
# shellcheck disable=SC2154
if [ "${root}" = "zfsbootmenu" ]; then
  boot_pool=
else
  boot_pool="${root}"
fi

# If a boot pool is specified, that will be tried first
try_pool="${boot_pool}"
zbm_import_attempt=0

while true; do
  if [ -n "${try_pool}" ]; then
    zdebug "attempting to import preferred pool ${try_pool}"
  fi

  read_write='' import_pool "${try_pool}"

  # shellcheck disable=SC2154
  if check_for_pools; then
    if [ "${zbm_require_bpool}" = "only" ]; then
      zdebug "only importing ${try_pool}"
      break
    elif [ -n "${try_pool}" ]; then
      # If a single pool was requested and imported, try importing others
      try_pool=""
      continue
    else
      # Otherwise, all possible pools were imported, nothing more to try
      break
    fi
  elif [ "${import_policy}" == "hostid" ] && poolmatch="$(match_hostid "${try_pool}")"; then
    zdebug "match_hostid returned: ${poolmatch}"

    spl_hostid="${poolmatch##*;}"

    export spl_hostid

    # Store the hostid to use for for KCL overrides
    echo -n "$spl_hostid" >"${BASE}/spl_hostid"

    # If match_hostid succeeds, it has imported *a* pool...
    if [ -n "${try_pool}" ] && [ "${zbm_require_bpool}" = "only" ]; then
      # In "only" bpool mode, the import was the sole pool desired; nothing more to do
      break
    else
      # Otherwise, try one more pass to pick up other pools matching this hostid
      try_pool=""
      continue
    fi
  elif [ -n "${try_pool}" ] && [ -z "${zbm_require_bpool}" ]; then
    # If a specific pool was tried unsuccessfully but is not a requirement,
    # allow another pass to try any other importable pools
    try_pool=""
    continue
  fi

  zbm_import_attempt="$((zbm_import_attempt + 1))"
  zinfo "unable to import a pool on attempt ${zbm_import_attempt}"

  # Just keep retrying after a delay until the user presses ESC
  if timed_prompt -d "${zbm_import_delay:-5}" \
    -p "Unable to import $(colorize magenta "${try_pool:-pool}"), retrying in $(colorize yellow "%0.2d") seconds" \
    -r "to retry immediately" \
    -e "for a recovery shell"; then
    continue
  fi

  log_unimportable
  # Allow the user to attempt recovery
  stop "unable to successfully import a pool"
done

# restrict read-write access to any unhealthy pools
while IFS=$'\t' read -r _pool _health; do
  if [ "${_health}" != "ONLINE" ]; then
    echo "${_pool}" >>"${BASE}/degraded"
    zerror "prohibiting read/write operations on ${_pool}"
  fi
done <<<"$(zpool list -H -o name,health)"

zdebug && zdebug "$(zreport)"

unsupported=0
while IFS=$'\t' read -r _pool _property; do
  if [[ "${_property}" =~ "unsupported@" ]]; then
    zerror "unsupported property: ${_property}"
    if ! grep -q "${_pool}" "${BASE}/degraded" >/dev/null 2>&1; then
      echo "${_pool}" >>"${BASE}/degraded"
    fi
    unsupported=1
  fi
done <<<"$(zpool get all -H -o name,property)"

if [ "${unsupported}" -ne 0 ]; then
  zerror "Unsupported features detected, Upgrade ZFS modules in ZFSBootMenu with generate-zbm"
  timed_prompt -m "$(colorize red 'Unsupported features detected')" \
    -m "$(colorize red 'Upgrade ZFS modules in ZFSBootMenu with generate-zbm')"
fi

# Attempt to find the bootfs property
# shellcheck disable=SC2086
while read -r line; do
  if [ "${line}" = "-" ]; then
    BOOTFS=
  else
    BOOTFS="${line}"
    break
  fi
done <<<"$(zpool list -H -o bootfs ${boot_pool})"

if [ -n "${BOOTFS}" ]; then
  export BOOTFS
  echo "${BOOTFS}" >"${BASE}/bootfs"
fi

: >"${BASE}/initialized"

# If BOOTFS is not empty display the fast boot menu
# shellcheck disable=SC2154
if [ "${menu_timeout}" -ge 0 ] && [ -n "${BOOTFS}" ]; then
  # Draw a countdown menu
  # shellcheck disable=SC2154
  if timed_prompt -d "${menu_timeout}" \
    -p "Booting $(colorize cyan "${BOOTFS}") in $(colorize yellow "%0.${#menu_timeout}d") seconds" \
    -r "boot now " \
    -e "boot menu"; then
    # This lock file is present if someone has SSH'd to take control
    # Do not attempt to automatically boot if present
    if [ ! -e "${BASE}/active" ]; then
      # Clear screen before a possible password prompt
      tput clear
      if ! NO_CACHE=1 load_key "${BOOTFS}"; then
        stop "unable to load key for $(colorize cyan "${BOOTFS}")"
      elif find_be_kernels "${BOOTFS}" && [ ! -e "${BASE}/active" ]; then
        # Automatically select a kernel and boot it
        kexec_kernel "$(select_kernel "${BOOTFS}")"
      fi
    fi
  fi
fi

# If the lock file is present, drop to a recovery shell to avoid
# stealing control back from an SSH session
if [ -e "${BASE}/active" ]; then
  stop "an active instance is already running"
fi

while true; do
  if [ -x /bin/zfsbootmenu ]; then
    /bin/zfsbootmenu
  fi

  stop
done
