#!/usr/bin/env bash
# shellcheck disable=SC1090

PIKONEK_INSTALL_DIR="/etc/pikonek"

# Remove existing files
rm -rf "${PIKONEK_INSTALL_DIR}/configs"
rm -rf "${PIKONEK_INSTALL_DIR}/scripts"
rm -rf "${PIKONEK_INSTALL_DIR}/pikonek"
rm -rf "${PIKONEK_INSTALL_DIR}/packages"
rm -rf "${PIKONEK_INSTALL_DIR}/setupVars.conf"
rm -rf "${PIKONEK_INSTALL_DIR}/setupVars.conf.update.bak"
rm -rf "${PIKONEK_INSTALL_DIR}/install.log"
rm -rf "${PIKONEK_INSTALL_DIR}/blocked"
rm -rf "${PIKONEK_INSTALL_DIR}"
rm -rf /etc/logrotate.d/pikonek
rm -rf /etc/dnsmasq.d/01-pikonek.conf
rm -rf /etc/init.d/S70piknkmain
rm -rf /etc/sudoers.d/pikonek
rm -rf /etc/cron.d/pikonek
rm -rf /etc/cron.daily/pikonekupdateblockedlist