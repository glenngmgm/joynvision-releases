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
# TWO SIZES, ALTERNATING, AND THE SMALL ONE IS NOT AN AFTERTHOUGHT.
#
# This asked only for 2 OCPU / 12 GB, for the same reason the Mac loop did: the
# step down was written for a quota refusal, and 2/12 passes quota. So 26 hours
# of asking never once tried 1 OCPU, and a one core slot frees up more often
# than a two core one. The stack ran inside 6 GB on a laptop before it ever saw
# Oracle, so a smaller server that exists still beats a larger one that does not.
#
# 4 OCPU is deliberately absent: Oracle cut the allowance when it disabled the
# old instance and refuses that size on quota outright, and a request that
# cannot succeed still spends one of the few the rate limiter allows. The Mac
# loop re-tests it every half hour in case the allowance comes back.
# Ordered by likelihood of winning, not by size. Oracle halved the Always Free
# A1 allowance from 4/24 to 2/12 and disabled free-only instances above the new
# limit, which is exactly what happened here. So every affected user in the
# world is now asking for the same 2/12 replacement: the famine at that size is
# a stampede, not ordinary scarcity. 1/6 is inside the free limit, still 6 GB,
# and far less contested; the stack ran inside 6 GB on a laptop before it ever
# saw Oracle. 1/1 cannot serve but can be resized, and nobody is fighting for it.
SIZES=("1 6" "1 1" "1 6" "2 12")

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
# MOSTLY NO CORNER AT ALL, WHICH IS THE WIDER ASK AND ORACLE'S OWN ADVICE.
#
# Capacity is counted per fault domain, so naming one and being told it is full
# answers for one corner of the room rather than the room. The first version
# named a corner on three runs out of four to map them. Wrong way round: the
# refusal itself says "Try creating the instance without specifying fault
# domain", and a request that names none can be filled from ANY of the three, so
# it wins whenever a named one would and whenever either of the others has room.
#
# One named corner still rides along, rotating, because a refusal carries the
# fault domain back and that is the only way to see a corner that is cold for
# good rather than briefly full. Which entry this run uses is derived from the
# clock, so consecutive runs differ with nothing stored between them.
FDS=('' '' '' '"faultDomain":"FAULT-DOMAIN-1",' '' '' '' '"faultDomain":"FAULT-DOMAIN-2",' '' '' '' '"faultDomain":"FAULT-DOMAIN-3",')
FD=${FDS[$(( ($(date +%s) / 120) % ${#FDS[@]} ))]}
# sed cannot supply the fallback: with an empty FD it is given no line at all
# and prints nothing, so the empty case has to be handled by the shell.
WHERE=${FD:+$(printf '%s' "$FD" | sed -E 's/.*"(FAULT-DOMAIN-[0-9])".*/\1/')}
WHERE=${WHERE:-the placement Oracle picks}

# 2 OCPU / 12 GB by default. Oracle cut the allowance when it disabled the old
# instance: 4 OCPU is refused on quota outright, and a request that cannot
# succeed still spends one of the few the rate limiter allows.
BODY=$(printf '{"availabilityDomain":"%s",%s"compartmentId":"%s","displayName":"joynvision-central","shape":"%s","shapeConfig":{"ocpus":%s,"memoryInGBs":%s},"sourceDetails":{"sourceType":"bootVolume","bootVolumeId":"%s"},"createVnicDetails":{"subnetId":"%s","privateIp":"%s","assignPublicIp":true}}' \
  "$AD" "$FD" "$TENANCY" "${SHAPE_NAME:-VM.Standard.A1.Flex}" "$OCPUS" "$MEMGB" "$BOOTVOL" "$SUBNET" "$PRIVATE_IP")

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
                   echo "$(date -u '+%H:%M:%S') no free host for $OCPUS OCPU / $MEMGB GB: $WHERE was full" ;;
  TooManyRequests) echo "$(date -u '+%H:%M:%S') rate limited asking for $OCPUS/$MEMGB, again shortly" ;;
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

# WATCH FOR THE SECOND MACHINE TYPE OPENING, AND TAKE IT IF IT DOES.
#
# ap-batam-1 offers two shapes. A1 has had nothing spare since 27 October. A2 is
# aarch64 too, so the preserved disk boots on it, and this account is already
# allowed 8 A2 cores: the limit was never what stopped it. Oracle simply has not
# finished turning A2 on here, which the shapes API states plainly as
# minPerOcpuInGBs 0 and maxPerOcpuInGBs 0. Nothing can be sized into a range of
# zero to zero.
#
# The day those become real numbers, A2 is an allowance we already hold with no
# crowd in front of it. This watch exists in the Mac loop too, but the Mac is
# off while Glenn travels from the end of November, which is exactly the stretch
# where nobody would otherwise notice. One cheap read an hour.
a2_is_open() {
  local d sig path
  path="/20160918/shapes?compartmentId=$TENANCY&availabilityDomain=CLhg%3AAP-BATAM-1-AD-1&limit=500"
  d=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S GMT")
  sig=$(sign "$(printf '(request-target): get %s\ndate: %s\nhost: %s' "$path" "$d" "$HOST")")
  curl -s --max-time 45 "https://$HOST$path" \
    -H "date: $d" -H "host: $HOST" \
    -H "Authorization: Signature version=\"1\",keyId=\"$KEYID\",algorithm=\"rsa-sha256\",headers=\"(request-target) date host\",signature=\"$sig\"" \
  | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    if not isinstance(d, list): raise ValueError(d)
    for sh in d:
        if sh.get("shape")=="VM.Standard.A2.Flex":
            print((sh.get("memoryOptions") or {}).get("maxPerOcpuInGBs") or 0); break
    else: raise ValueError("A2 not offered")
except Exception: print("ERR")' 2>/dev/null
}

DEADLINE=$(( $(date +%s) + LOOP_MINUTES * 60 ))
tries=0
a2_open=no
a2_last=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  tries=$((tries + 1))

  if [ "$a2_open" = no ] && [ $(( $(date +%s) - a2_last )) -ge 3600 ]; then
    a2_last=$(date +%s)
    a2max=$(a2_is_open)
    case "$a2max" in
      ERR|'')
        # A failed read is not the same fact as "A2 is still shut", and printing
        # 0 for both is how a watch dies without anyone noticing.
        echo "$(date -u '+%H:%M:%S') cannot read whether A2 has opened - the watch is blind this hour" ;;
      0|0.0) ;;
      *)
      a2_open=yes
      echo "A2 HAS OPENED IN BATAM: maxPerOcpuInGBs=$a2max - asking for it as well from now on"
      curl -s -o /dev/null --max-time 20 \
        "https://api.telegram.org/bot${TG:-}/sendMessage" \
        --data-urlencode "chat_id=${CHAT:-}" \
        --data-urlencode "text=Oracle has just turned on the second ARM machine type in Batam. Nobody is queueing for it and your account is already allowed it, so JoynVision now asks for that as well as the one everyone is fighting over." || true ;;
    esac
  fi

  # A2 takes every other turn once it is open, so A1 is never abandoned: the
  # check says A2 can be SIZED, not that it has a free host.
  SHAPE_NAME=VM.Standard.A1.Flex
  if [ "$a2_open" = yes ] && [ $(( tries % 2 )) -eq 0 ]; then
    SHAPE_NAME=VM.Standard.A2.Flex
  fi

  size=${SIZES[$(( (tries - 1) % ${#SIZES[@]} ))]}
  OCPUS=${size% *}; MEMGB=${size#* }
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
