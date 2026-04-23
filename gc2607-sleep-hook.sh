#!/bin/bash
# Restart gc2607-camera.service after resume.
#
# The service has Conflicts=sleep.target so it stops cleanly before the
# IPU6 powers down, but systemd does not automatically restart it on
# resume — this hook does that. Called by systemd-sleep with
# $1 = pre|post and $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate.
#
# Installed by gc2607-setup-service.sh to:
#   /usr/lib/systemd/system-sleep/gc2607

case "$1/$2" in
    post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
        systemctl restart gc2607-camera.service
        ;;
esac
