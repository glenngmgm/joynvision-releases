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

sign() { printf '%s' "$1" | openssl dgst -sha256 -sign "$KEYFILE" | openssl enc -e -base64 -A; }

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
  D2=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S GMT")
  S2=$(printf '(request-target): get /20160918/instances?compartmentId=%s\ndate: %s\nhost: %s' "$TENANCY" "$D2" "$HOST")
  LIVE=$(curl -s --max-time 45 "https://$HOST/20160918/instances?compartmentId=$TENANCY" \
    -H "date: $D2" -H "host: $HOST" \
    -H "Authorization: Signature version=\"1\",keyId=\"$KEYID\",algorithm=\"rsa-sha256\",headers=\"(request-target) date host\",signature=\"$(sign "$S2")\"" \
    | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(len([i for i in d if i.get('lifecycleState') not in ('TERMINATED','TERMINATING')]))" 2>/dev/null)
  if [ "${LIVE:-0}" -gt 0 ] 2>/dev/null; then
    echo "Oracle's reply was unreadable but a machine is running, so a server exists"
    CODE=OK
  fi
fi

case "$CODE" in
  OK)              out yes; echo "a server was created, $OCPUS OCPU / $MEMGB GB" ; exit 0 ;;
  InternalError|OutOfCapacity)
                   out no;  echo "no free host: $WHERE was full" ;;
  TooManyRequests) out no;  echo "rate limited, the next run asks again" ;;
  LimitExceeded)   out no;  echo "quota refused at $OCPUS/$MEMGB - the allowance changed, check the shape" ;;
  *)               out no;  echo "refused: $CODE" ;;
esac
exit 0
