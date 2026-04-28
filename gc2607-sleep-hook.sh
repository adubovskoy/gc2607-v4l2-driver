#!/bin/bash
# Restart gc2607-camera.service after resume.
#
# The service has Conflicts=sleep.target so it is already stopped when
# we resume — use 'start --no-block' rather than 'restart' to avoid
# colliding with the still-completing systemd-suspend.service transaction
# (otherwise systemd refuses with a 'destructive transaction' error).
# Called by systemd-sleep with $1 = pre|post and
# $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate.

case "$1/$2" in
    post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
        systemctl --no-block start gc2607-camera.service
        ;;
esac
