#!/bin/bash
# Restart wireplumber for the logged-in desktop user so PipeWire picks up
# the virtual camera and applies the hide-raw-IPU6 rule.
# Called by gc2607-camera.service ExecStartPost.

set -u

# Wait for the virtualcam to register with v4l2loopback
sleep 5

# Find the active graphical session's user. Skip system users like the
# display manager's greeter account (uid < 1000, often nologin shell).
find_desktop_user() {
    local uid user
    for d in /run/user/*/; do
        uid="${d%/}"
        uid="${uid##*/}"
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ -S "/run/user/$uid/bus" ]; then
            user="$(getent passwd "$uid" | cut -d: -f1)"
            [ -n "$user" ] && echo "$user $uid" && return 0
        fi
    done
    return 1
}

for attempt in 1 2 3 4 5 6; do
    if read -r USER UID_NUM < <(find_desktop_user); then
        runuser -u "$USER" -- env \
            XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
            systemctl --user restart wireplumber 2>/dev/null && exit 0
    fi
    sleep 5
done
exit 0
