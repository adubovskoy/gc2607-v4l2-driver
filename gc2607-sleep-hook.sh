#!/bin/bash
# Drive gc2607-camera.service across suspend/resume.
#
# pre:  stop the service so gc2607_isp closes its V4L2 fds before the
#       IPU6 powers down (otherwise we'd see -EBUSY / sensor stuck on
#       resume).
# post: start the service again.
#
# We use --no-block on start to avoid waiting on systemd-suspend.service
# transactions still in flight during early resume. The pre stop is
# blocking with a small timeout so the service is fully down before
# systemd-sleep proceeds with the actual suspend syscall.

case "$1/$2" in
    pre/suspend|pre/hibernate|pre/hybrid-sleep|pre/suspend-then-hibernate)
        systemctl stop gc2607-camera.service
        ;;
    post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
        systemctl --no-block start gc2607-camera.service
        ;;
esac
