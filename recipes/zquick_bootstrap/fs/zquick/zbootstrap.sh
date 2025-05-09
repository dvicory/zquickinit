#!/bin/bash

: "${DEBUG:=}"
: "${INSTALLER_DIR:=/zquick/libexec/installer}"

if [[ -d /mnt/qemu-host/recipes/zquick_bootstrap/fs/zquick/libexec/installer ]]; then
    echo "DEVMODE: Running from qemu-host!!"
    INSTALLER_DIR=/mnt/qemu-host/recipes/zquick_bootstrap/fs/zquick/libexec/installer
fi

envs=(DEBUG="${DEBUG}" INSTALLER_DIR="${INSTALLER_DIR}")

env "${envs[@]}" "${INSTALLER_DIR}"/installer.sh "$@"
