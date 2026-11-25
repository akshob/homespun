#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

pose_call() { timed "pose.$1" "$DUOCTL" -d "$SIM" "$@"; }

turn() {
    local attempt
    for attempt in 1 2 3 4; do
        pose_call rotate "$1" && return 0
        sleep 3
    done
    return 1
}

apply_duo_pose() {
    local action=$1 name command x1="" y1="" x2="" y2=""
    case "$action" in
        shot\ *)
            name=${action#shot }
            case "$name" in
                ""|*/*|*\\*) echo "Invalid pose screenshot name" >&2; return 1;;
            esac
            pose_call screenshot "$SHOTS/$name.png";;
        landscape) pose_call hinge 180 && turn landscape;;
        portrait) pose_call hinge 180 && turn portrait;;
        laptop) pose_call hinge 180 && turn portrait && pose_call hinge 100;;
        folded) pose_call hinge 0 && timed pose.fold-wait sleep 2 && turn portrait;;
        swipe\ *)
            read -r command x1 y1 x2 y2 <<< "$action"
            pose_call swipe "$x1" "$y1" "$x2" "$y2";;
        *) echo "Unknown pose request: $action" >&2; return 1;;
    esac
}

process_duo_pose_request() {
    local claimed="$POSEFILE.inflight" request token action reply outcome newline
    [[ -f "$POSEFILE" ]] || return 0
    [[ ! -e "$claimed" ]] || { echo "An earlier pose request is still claimed" >&2; return 1; }
    mv "$POSEFILE" "$claimed" || return 1
    request=$(cat "$claimed") || return 1
    newline='
'
    token=${request%%"$newline"*}
    action=${request#*"$newline"}
    if [[ "$action" == "$request" ]] || ! printf '%s\n' "$token" |
        grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'; then
        echo "Malformed pose request" >&2
        rm -f "$claimed"
        return 1
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) request $token: $action"
    stamp pose.request.start
    if apply_duo_pose "$action"; then outcome=ok; else outcome=failed; fi
    stamp pose.request.end
    echo "request $token result: $outcome"
    reply="$POSEFILE.$token.result"
    rm -f "$claimed" || return 1
    printf '%s\n' "$outcome" > "$reply.tmp" && mv "$reply.tmp" "$reply" || return 1
}
