#!/bin/bash
# Replace a signed development app as a complete bundle and renew its service
# registration. This entry never starts nettop or real interface sampling.
set -euo pipefail
FQ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FQ_ARCH="$(uname -m)"
FQ_SOURCE="$FQ_ROOT/.artifacts/$FQ_ARCH/Flow Quota.app"
FQ_APP='/Applications/Flow Quota.app'
FQ_OUT="$(mktemp -d "$FQ_ROOT/.artifacts/service-repair.XXXXXX")"
FQ_DOMAIN="gui/$(id -u)"
FQ_SUCCESS=false
FQ_ENV_CHANGED=false
FQ_PREVIOUS_SET=false
FQ_PREVIOUS_PAUSE=''
FQ_STAGE=''

restore_startup_environment() {
    if [[ "$FQ_ENV_CHANGED" != true ]]; then return; fi
    if [[ "$FQ_SUCCESS" != true ]]; then
        echo 'Repair incomplete; paused startup override retained to prevent sampling.' >&2
        echo 'FLOW_QUOTA_VERIFY_PAUSED=1 remains set in launchd.' >&2
        return
    fi
    if [[ "$FQ_PREVIOUS_SET" == true ]]; then
        launchctl setenv FLOW_QUOTA_VERIFY_PAUSED "$FQ_PREVIOUS_PAUSE"
    else
        launchctl unsetenv FLOW_QUOTA_VERIFY_PAUSED
    fi
}
trap restore_startup_environment EXIT

echo "Repair evidence: $FQ_OUT"
codesign --verify --deep --strict "$FQ_SOURCE"
# Active collection requires a separate confirmed pause before replacement.
if pgrep -x FlowQuotaAgent >/dev/null || pgrep -x nettop >/dev/null; then
    echo 'An agent or sampler is running; stop collection before using this repair entry.' >&2
    exit 1
fi
launchctl print "$FQ_DOMAIN/local.flowquota.agent" > "$FQ_OUT/launchd-before.txt" 2>&1 || true
if FQ_PREVIOUS_PAUSE="$(launchctl getenv FLOW_QUOTA_VERIFY_PAUSED 2>/dev/null)" && [[ -n "$FQ_PREVIOUS_PAUSE" ]]; then
    FQ_PREVIOUS_SET=true
fi
printf '%s\n' "$FQ_PREVIOUS_SET" > "$FQ_OUT/previous-pause-set.txt"
printf '%s' "$FQ_PREVIOUS_PAUSE" > "$FQ_OUT/previous-pause-value.txt"
launchctl setenv FLOW_QUOTA_VERIFY_PAUSED 1
FQ_ENV_CHANGED=true

# Only close installed UI processes; the collector was confirmed absent above.
FQ_UI_PIDS="$(pgrep -f '^/Applications/Flow Quota\.app/Contents/MacOS/FlowQuota( --window)?$' || true)"
for FQ_PID in $FQ_UI_PIDS; do
    kill -TERM "$FQ_PID"
    for FQ_CHECK in {1..30}; do
        if ! kill -0 "$FQ_PID" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$FQ_PID" 2>/dev/null; then
        echo 'Installed interface did not exit; replacement stopped.' >&2
        exit 1
    fi
done

# Stage beside /Applications so installing the complete signed bundle is a rename.
# Temporarily retain the previous app for failure recovery; remove it on success.
FQ_STAGE="$(mktemp -d '/Applications/.FlowQuota-stage.XXXXXX')"
ditto "$FQ_SOURCE" "$FQ_STAGE/Flow Quota.app"
codesign --verify --deep --strict "$FQ_STAGE/Flow Quota.app"
if [[ -e "$FQ_APP" ]]; then mv "$FQ_APP" "$FQ_OUT/Previous Flow Quota.app"; fi
mv "$FQ_STAGE/Flow Quota.app" "$FQ_APP"
rmdir "$FQ_STAGE"
codesign --verify --deep --strict "$FQ_APP"
FQ_LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# An unregistered known copy may return -10814. It has no registration to remove;
# preserve all other LaunchServices failures instead of silently ignoring them.
unregister_known_copy() {
    local fq_path="$1" fq_output
    if fq_output="$("$FQ_LSREGISTER" -u "$fq_path" 2>&1)"; then return; fi
    if [[ "$fq_output" == *'-10814'* ]]; then
        echo "No LaunchServices entry for known copy: $fq_path"
        return
    fi
    printf '%s\n' "$fq_output" >&2
    return 1
}
unregister_known_copy "$FQ_SOURCE"
# Moving the previous bundle can leave its identity registered at the recovery path.
# Unregister that known copy before registering the newly installed service bundle.
if [[ -d "$FQ_OUT/Previous Flow Quota.app" ]]; then
    unregister_known_copy "$FQ_OUT/Previous Flow Quota.app"
fi
if [[ -d '/Volumes/Flow Quota Development/Flow Quota.app' ]]; then
    unregister_known_copy '/Volumes/Flow Quota Development/Flow Quota.app'
fi
unregister_known_copy "$FQ_APP"
"$FQ_LSREGISTER" -f "$FQ_APP"

# SMAppService performs unregister/register through the app's real identity.
# The inherited launchd override also covers the helper's cold-start branch.
for FQ_ATTEMPT in 1 2 3; do
    if (( FQ_ATTEMPT > 1 )); then
        # After an ad-hoc binary changes, launchd can initially receive an empty
        # cdhash constraint. Refresh this bundle's registration before retrying.
        unregister_known_copy "$FQ_APP"
        "$FQ_LSREGISTER" -f "$FQ_APP"
    fi
    # Exercise the actual LaunchServices application launch after refreshing
    # registration. A successful open alone is insufficient; require XPC evidence.
    if open -n -W -a "$FQ_APP" --stdout "$FQ_OUT/service-$FQ_ATTEMPT.json" \
        --stderr "$FQ_OUT/service-$FQ_ATTEMPT.err" --args --repair-agent-paused \
        && /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("pausedCheck") is True and d.get("monitoring")=="paused" and d.get("serviceStatus")==1 else 1)' "$FQ_OUT/service-$FQ_ATTEMPT.json"; then
        if pgrep -x nettop >/dev/null; then
            echo 'Unexpected sampler after repair; paused recovery is incomplete.' >&2
            exit 1
        fi
        launchctl print "$FQ_DOMAIN/local.flowquota.agent" > "$FQ_OUT/launchd-after.txt"
        open -n -a "$FQ_APP" --args --window
        if [[ -d "$FQ_OUT/Previous Flow Quota.app" ]]; then
            rm -rf -- "$FQ_OUT/Previous Flow Quota.app"
        fi
        FQ_SUCCESS=true
        cat "$FQ_OUT/service-$FQ_ATTEMPT.json"
        echo "Reopened current app; service paused. Temporary previous app removed; diagnostics in $FQ_OUT"
        exit 0
    fi
    cat "$FQ_OUT/service-$FQ_ATTEMPT.err" >&2
done
echo 'Service registration could not be recovered. See the saved diagnostics.' >&2
exit 1
