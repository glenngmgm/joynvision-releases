#!/usr/bin/env bash
# Ask Oracle, once, for an ARM host to boot the preserved JoynVision disk on.
# Prints "won=yes" or "won=no" to $GITHUB_OUTPUT when running in Actions, and
# says in plain words what Oracle answered.
#
# A SCRIPT RATHER THAN SHELL INSIDE THE WORKFLOW, and the reason is not taste.
# The first version embedded this in a `run: |` block. Everything further
# indented than the block keeps that extra indentation, so the little python
# one-liners arrived with leading spaces and would have died on IndentationError
# on the first scheduled run - at four in the morning, in a repository nobody
# watches, while the Mac loop looked like it was still covering. A file can be
# run locally before it is trusted, which is the only reason to believe it works.
set -uo pipefail

HOST=iaas.ap-batam-1.oraclecloud.com
AD='CLhg:AP-BATAM-1-AD-1'
PRIVATE_IP=10.0.0.152
OCPUS=${OCPUS:-2}
MEMGB=${MEMGB:-12}

for v in TENANCY USER_OCID FP OCI_KEY BOOTVOL SUBNET; do
  [ -n "${!v:-}" ] || { echo "missing $v"; exit 2; }
done
KEYID="$TENANCY/$USER_OCID/$FP"

# The key lives in a temp file that goes with the process, never in the workspace.
KEYFILE=$(mktemp); trap 'rm -f "$KEYFILE"' EXIT
printf '%s\n' "$OCI_KEY" > "$KEYFILE"; chmod 600 "$KEYFILE"

out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "won=$1" >> "$GITHUB_OUTPUT"; }

# HOW LONG ONE RUN KEEPS ASKING, and why this is not one request per run.
#
# A workflow set to every five minutes does not run every five minutes. The
# uptime check in this same repository is set to every ten and actually runs
# every four hours: median 229 minutes between runs, worst case 378. GitHub
# deprioritises schedules and silently skips them, and nothing in the workflow
# file hints at it. A once-per-run script on a five minute cron would therefore
# have asked Oracle about six times a day while claiming to ask 288 times, and
# the claim is worse than the gap.
#
# A hosted runner may live six hours, so instead each run STAYS and asks every
# minute until its time is up. GitHub firing the schedule a few times a day is
# then enough for near continuous cover, because each firing buys hours rather
# than one request. Minutes are free on a public repository, so the only cost is
# a runner sitting in a sleep loop.
LOOP_MINUTES=${LOOP_MINUTES:-330}   # runner hard limit is 360
EVERY_SECONDS=${EVERY_SECONDS:-60}

sign() { printf '%s' "$1" | openssl dgst -sha256 -sign "$KEYFILE" | openssl enc -e -base64 -A; }

ask_once() {
# THREE CORNERS, AND ORACLE'S OWN PICK. Capacity is counted per fault domain, so
# "out of host capacity" answers for one corner of the room, not the room. Which
# corner this run asks is derived from the clock, so consecutive runs differ with
# nothing stored between them.
FDS=('"faultDomain":"FAULT-DOMAIN-1",' '"faultDomain":"FAULT-DOMAIN-2",' '"faultDomain":"FAULT-DOMAIN-3",' '')
FD=${FDS[$(( ($(date +%s) / 300) % 4 ))]}
# sed cannot supply the fallback: with an empty FD it is given no line at all
# and prints nothing, so the empty case has to be handled by the shell.
WHERE=${FD:+$(printf '%s' "$FD" | sed -E 's/.*"(FAULT-DOMAIN-[0-9])".*/\1/')}
WHERE=${WHERE:-the placement Oracle picks}

# 2 OCPU / 12 GB by default. Oracle cut the allowance when it disabled the old
# instance: 4 OCPU is refused on quota outright, and a request that cannot
# succeed still spends one of the few the rate limiter allows.
BODY=$(printf '{"availabilityDomain":"%s",%s"compartmentId":"%s","displayName":"joynvision-central","shape":"VM.Standard.A1.Flex","shapeConfig":{"ocpus":%s,"memoryInGBs":%s},"sourceDetails":{"sourceType":"bootVolume","bootVolumeId":"%s"},"createVnicDetails":{"subnetId":"%s","privateIp":"%s","assignPublicIp":true}}' \
  "$AD" "$FD" "$TENANCY" "$OCPUS" "$MEMGB" "$BOOTVOL" "$SUBNET" "$PRIVATE_IP")

DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S GMT")
BH=$(printf '%s' "$BODY" | openssl dgst -sha256 -binary | openssl enc -e -base64 -A)
SS=$(printf '(request-target): post /20160918/instances\ndate: %s\nhost: %s\ncontent-length: %s\ncontent-type: application/json\nx-content-sha256: %s' \
  "$DATE" "$HOST" "${#BODY}" "$BH")

OUT=$(curl -s --max-time 60 -X POST "https://$HOST/20160918/instances" \
  -H "date: $DATE" -H "host: $HOST" -H "content-length: ${#BODY}" \
  -H "content-type: application/json" -H "x-content-sha256: $BH" \
  -H "Authorization: Signature version=\"1\",keyId=\"$KEYID\",algorithm=\"rsa-sha256\",headers=\"(request-target) date host content-length content-type x-content-sha256\",signature=\"$(sign "$SS")\"" \
  --data-binary "$BODY")

CODE=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('code') or 'OK')" 2>/dev/null)
CODE=${CODE:-PARSE}

# A reply we cannot read may still have been a launch, and guessing wrong here
# builds a second server on the next run. So ask what is actually running.
if [ "$CODE" = "PARSE" ]; then
  LIVE=$(live_instances)
  if [ "${LIVE:-0}" -gt 0 ] 2>/dev/null; then
    echo "Oracle's reply was unreadable but a machine is running, so a server exists"
    CODE=OK
  fi
fi

case "$CODE" in
  OK)              echo "$(date -u '+%H:%M:%S') a server was created, $OCPUS OCPU / $MEMGB GB"; return 0 ;;
  InternalError|OutOfCapacity)
                   echo "$(date -u '+%H:%M:%S') no free host: $WHERE was full" ;;
  TooManyRequests) echo "$(date -u '+%H:%M:%S') rate limited, asking again shortly" ;;
  LimitExceeded)   echo "$(date -u '+%H:%M:%S') quota refused at $OCPUS/$MEMGB - the allowance changed, check the shape" ;;
  *)               echo "$(date -u '+%H:%M:%S') refused: $CODE" ;;
esac
return 1
}

# IS THERE ALREADY A SERVER? ASK BEFORE ASKING FOR ONE.
#
# Several of these run one after another, and the Mac loop runs too. Whichever
# wins, the others must not carry on requesting machines. The reliable signal is
# not a file or a job output, it is Oracle: one question, before the loop, and
# again whenever a reply cannot be read.
#
# It is also the honest answer to "did it work" after any confusion, which during
# this outage there has been plenty of.
live_instances() {
  local d sig
  d=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S GMT")
  sig=$(sign "$(printf '(request-target): get /20160918/instances?compartmentId=%s\ndate: %s\nhost: %s' "$TENANCY" "$d" "$HOST")")
  curl -s --max-time 45 "https://$HOST/20160918/instances?compartmentId=$TENANCY" \
    -H "date: $d" -H "host: $HOST" \
    -H "Authorization: Signature version=\"1\",keyId=\"$KEYID\",algorithm=\"rsa-sha256\",headers=\"(request-target) date host\",signature=\"$sig\"" \
    | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(len([i for i in d if i.get('lifecycleState') not in ('TERMINATED','TERMINATING')]))" 2>/dev/null
}

already=$(live_instances)
if [ "${already:-0}" -gt 0 ] 2>/dev/null; then
  out yes
  echo "there is already a server running, so this run has nothing to do"
  exit 0
fi

DEADLINE=$(( $(date +%s) + LOOP_MINUTES * 60 ))
tries=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  tries=$((tries + 1))
  if ask_once; then
    out yes
    echo "stopped after $tries tries because there is a server"
    exit 0
  fi
  sleep "$EVERY_SECONDS"
done
out no
echo "gave up this run after $tries tries over $LOOP_MINUTES minutes; the next scheduled run carries on"
exit 0
