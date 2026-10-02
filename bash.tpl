#!/bin/bash
# FreeIPA enrolment for ASG instances. Rendered by Terraform templatefile() and
# concatenated IN FRONT of other userdata (Wazuh, EKS bootstrap), so:
#   * Enrolment failure must not stop the remaining userdata. Work runs in a
#     supervised child shell; the enclosing subshell always returns success.
#   * Only Terraform variables may use dollar-brace. Bash expansions that need
#     braces are escaped with a doubled dollar sign. This applies to comments.
# Deliberately top level: the EKS wrapper runs "set -ex" and later snippets
# (Wazuh) handle secrets and rely on tracing/errexit being off from here on.
set +e +x +v
(
set +e +x +v
exec > >(tee -a /var/log/freeipa-enrol.log) 2>&1

TAG_NAME="${ec2_fqdn_tag}"
SECRET_ID="${freeipa_secret_name}"
FAILURE_WEBHOOK="${failure_webhook}"

DEADLINE_SECONDS=300
NOTIFY_SECONDS=10
WORK_SECONDS=$(( DEADLINE_SECONDS - NOTIFY_SECONDS ))
log() { echo "$(date -u +%FT%TZ) freeipa-enrol: $*"; }

# GNU timeout (coreutils on AL2/AL2023) supervises the whole worker, including
# AWS CLI retries, DNS, clock sync, uninstall, kinit and installer subprocesses.
# KILL stops the process group at the deadline even if a child ignores TERM.
# Keep notification outside that group, with its own share of the 300s budget.
if ! command -v timeout >/dev/null 2>&1; then
  log "FAILED: GNU timeout is required; skipping enrolment to preserve bootstrap"
  exit 0
fi
umask 077
STATUS_FILE=$(mktemp) || { log "FAILED: cannot create enrolment status file"; exit 0; }
trap 'rm -f "$STATUS_FILE"' EXIT
printf '%s\n' 'initialising (instance identity not yet available)' > "$STATUS_FILE"

# The worker is passed with bash -c, not fed on stdin: with "bash -s <<EOF" any
# child that reads stdin (installer prompts, init scripts) would consume the
# rest of the script. Its stdin is /dev/null so nothing can block on input.
IFS= read -r -d '' FREEIPA_ENROL_WORKER_SCRIPT <<'FREEIPA_ENROL_WORKER'
set +e +x +v
TAG_NAME=$1
SECRET_ID=$2
STATUS_FILE=$3
DEADLINE_SECONDS=$4
FQDN_WAIT_SECONDS=90    # the DNS handler lambda sets the tag; cold starts under churn are slow
# With prompt tag/secret, worst-case jitter and ~15 s installs, 4 attempts fit
# the admission check below; a slow tag (full FQDN wait) leaves room for ~2.
MAX_ATTEMPTS=4
ATTEMPT_BUDGET=60       # retry admission estimate; the outer watchdog enforces the deadline
START=$SECONDS
INSTANCE_ID=""
FQDN=""

log() { echo "$(date -u +%FT%TZ) freeipa-enrol: $*"; }

fail() {
  printf '%s\n' "$INSTANCE_ID ($FQDN): $*" > "$STATUS_FILE"
  exit 1
}

imds() {
  local token i
  for i in 1 2 3 4 5; do
    token=$(curl -sf -m 5 -X PUT http://169.254.169.254/latest/api/token \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 300') &&
      curl -sf -m 5 -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/$1" && return 0
    sleep $(( i * 2 ))
  done
  return 1
}

INSTANCE_ID=$(imds meta-data/instance-id) || fail "IMDS unreachable (instance-id)"
printf '%s\n' "$INSTANCE_ID: discovering region and FQDN" > "$STATUS_FILE"
REGION=$(imds meta-data/placement/region) || fail "IMDS unreachable (region)"

# 1. Wait for the FQDN tag. An AWS CLI error yields "", a missing tag "None";
#    both mean "not yet", never "enrol with an empty hostname".
while (( SECONDS - START < FQDN_WAIT_SECONDS )); do
  FQDN=$(AWS_MAX_ATTEMPTS=2 aws ec2 describe-tags --cli-connect-timeout 5 --cli-read-timeout 5 --region "$REGION" \
           --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=$TAG_NAME" \
           --query 'Tags[0].Value' --output text 2>/dev/null)
  [[ -n "$FQDN" && "$FQDN" != "None" && "$FQDN" != "null" ]] && break
  FQDN=""
  sleep 10
done
[[ -n "$FQDN" ]] || fail "tag $TAG_NAME not set after $FQDN_WAIT_SECONDS s"
[[ "$FQDN" == *.* && "$FQDN" != *'#instanceid'* ]] || fail "tag $TAG_NAME has an invalid FQDN: $FQDN"
log "instance $INSTANCE_ID will enrol as $FQDN"
printf '%s\n' "$INSTANCE_ID ($FQDN): enrolment in progress" > "$STATUS_FILE"

# 2. Read the secret once, with retries, and validate it.
SECRET=""
for i in 1 2 3 4 5; do
  SECRET=$(AWS_MAX_ATTEMPTS=2 aws secretsmanager get-secret-value --cli-connect-timeout 5 --cli-read-timeout 5 --region "$REGION" --secret-id "$SECRET_ID" \
             --query SecretString --output text 2>/dev/null) && [[ -n "$SECRET" ]] && break
  sleep $(( i * 3 ))
done
IPA_DOMAIN=$(jq -r '.Domain // empty' <<<"$SECRET" 2>/dev/null)
IPA_USER=$(jq -r '.User // empty' <<<"$SECRET" 2>/dev/null)
IPA_PASSWORD=$(jq -r '.Password // empty' <<<"$SECRET" 2>/dev/null)
unset SECRET
[[ -n "$IPA_DOMAIN" && -n "$IPA_USER" && -n "$IPA_PASSWORD" ]] \
  || fail "secret $SECRET_ID unreadable or missing Domain/User/Password"

# 3. Kerberos rejects clock skew over 5 minutes, and --no-ntp means IPA won't fix it.
if command -v chronyc >/dev/null 2>&1; then
  chronyc -a waitsync 12 1.0 >/dev/null 2>&1 \
    || log "warning: clock not confirmed in sync; Kerberos may reject the join"
fi

# 4. Idempotency: a baked AMI or an earlier partial run leaves client config
#    behind, and every join then aborts with "already configured".
if [[ -f /etc/ipa/default.conf ]]; then
  if grep -qixF "host = $FQDN" /etc/ipa/default.conf \
     && KRB5CCNAME=MEMORY: kinit -k -t /etc/krb5.keytab "host/$FQDN" >/dev/null 2>&1; then
    log "already enrolled as $FQDN - nothing to do"
    exit 0
  fi
  log "stale IPA client config found - uninstalling before enrolment"
  ipa-client-install --uninstall --unattended >/dev/null 2>&1 || true
fi

# 5. Enrol with retries (DEVOPS-7459). Concurrent ASG churn causes 389-ds
#    transaction collisions ("join: DatabaseError") that succeed on retry.
#    Jitter is load-bearing: a scale-out launches many nodes at once and
#    without it they retry in lockstep and collide again.
#    Servers are found via the realm's DNS SRV records, so replicas can be
#    added or retired without touching this script or the secret.
#    Known limitation: ipa-client-install only takes the enrolment password on
#    argv, so it is briefly visible to local processes (ps) during the join.
sleep $(( RANDOM % 20 ))
attempt=1
while :; do
  out=$(ipa-client-install --unattended --no-ntp --force-join --mkhomedir \
          --domain="$IPA_DOMAIN" --principal="$IPA_USER" --password="$IPA_PASSWORD" \
          --hostname="$FQDN" 2>&1)
  rc=$?
  echo "$out" | tail -n 15

  # rc 0 alone is not proof: verify the host keytab actually authenticates.
  if [[ $rc -eq 0 ]] && KRB5CCNAME=MEMORY: kinit -k -t /etc/krb5.keytab "host/$FQDN" >/dev/null 2>&1; then
    log "enrolled as $FQDN on attempt $attempt after $(( SECONDS - START )) s"
    break
  fi

  # Only a wrong enrolment password is fatal (retrying risks locking the account).
  # "not found in Kerberos database", "Insufficient access ... Credential cache is
  # empty" and "Invalid credentials" are transient KDC/389-ds failures under churn
  # (seen in prod for principals that work on the next boot) - keep retrying those.
  fatal=$(grep -m1 -iE 'password incorrect|preauthentication failed' <<<"$out")
  [[ -n "$fatal" ]] && fail "non-retryable error: $fatal"

  if (( attempt >= MAX_ATTEMPTS || SECONDS - START >= DEADLINE_SECONDS )); then
    fail "ipa-client-install failed after $attempt attempt(s), rc=$rc: $(tail -n 1 <<<"$out")"
  fi

  delay=$(( 10 * 2 ** (attempt - 1) ))
  (( delay > 120 )) && delay=120
  delay=$(( delay + RANDOM % 15 ))
  if (( SECONDS - START + delay + ATTEMPT_BUDGET > DEADLINE_SECONDS )); then
    fail "ipa-client-install failed after $attempt attempt(s), rc=$rc, no time left for another: $(tail -n 1 <<<"$out")"
  fi

  [[ -f /etc/ipa/default.conf ]] && ipa-client-install --uninstall --unattended >/dev/null 2>&1

  log "attempt $attempt failed (rc=$rc); retrying in $delay s"
  sleep "$delay"
  attempt=$(( attempt + 1 ))
done
unset IPA_PASSWORD

# The hostname changed; restart Datadog (if present) so it reports the new one.
if service --status-all 2>/dev/null | grep -Fq 'datadog-agent'; then
  service datadog-agent restart
fi
exit 0
FREEIPA_ENROL_WORKER
timeout --signal=KILL "$WORK_SECONDS" bash -c "$FREEIPA_ENROL_WORKER_SCRIPT" freeipa-enrol-worker \
  "$TAG_NAME" "$SECRET_ID" "$STATUS_FILE" "$WORK_SECONDS" </dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
  detail=$(cat "$STATUS_FILE")
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    detail="enrolment exceeded $WORK_SECONDS s worker budget; $detail"
  else
    detail="worker exited $rc; $detail"
  fi
  log "FAILED: $detail"
  if [[ -n "$FAILURE_WEBHOOK" ]]; then
    # Bound JSON creation and notification together; never print the webhook.
    timeout --signal=KILL "$NOTIFY_SECONDS" bash -c '
      set +e +x +v
      payload=$(jq -nc --arg t "FreeIPA enrolment failed: $2" "{text: \$t}") || exit 1
      curl -sf -m "$3" -X POST -H "Content-type: application/json" \
        --data "$payload" "$1" >/dev/null
    ' freeipa-notify "$FAILURE_WEBHOOK" "$detail" "$NOTIFY_SECONDS" \
      || log "could not send failure notification within $NOTIFY_SECONDS s"
  fi
fi
exit 0
)
