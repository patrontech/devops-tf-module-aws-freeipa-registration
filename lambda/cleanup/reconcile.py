"""Reconcile FreeIPA host entries against live EC2 instances.

Retries in the cleanup lambda reduce the rate of missed deregistrations; they
do not take it to zero, and they do nothing about entries already orphaned.
Every orphan keeps a valid host principal alive and grows the 389-ds userRoot
database - which is the same database whose growth is making compaction fail.

This runs on a schedule and deletes host entries whose embedded EC2 instance no
longer exists.

Safety rules, in order of importance:

  1. Only FQDNs ending in one of IPA_MANAGED_SUFFIXES are ever considered.
  2. Only FQDNs containing an EC2 instance id are ever considered. Anything
     hand-created or not ASG-managed is invisible to this job.
  3. An instance is only an orphan if EC2 does not return it AT ALL. Terminated
     instances stay visible in the API for roughly an hour, so this gives a free
     grace period and avoids racing the cleanup lambda's own retries.
     A stopped instance is alive and is never touched.
  4. Dry run unless RECONCILE_APPLY is explicitly "true".
  5. Refuses to delete more than RECONCILE_MAX_DELETES in one run - if the sweep
     ever decides half the realm is stale, it should stop and page someone
     rather than act on it.
"""

import json
import logging
import os
import re
import sys

import boto3

from cleanup import (
    _emit_failure_metric,
    _freeipa_credentials,
    _host_del_once,
    _ipa_session,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2')
cloudwatch = boto3.client('cloudwatch')

METRIC_NAMESPACE = os.environ.get('METRIC_NAMESPACE', 'FreeIPA/Registration')

INSTANCE_ID_RE = re.compile(r'\b(i-[0-9a-f]{8,17})\b')

# describe_instances caps filter values; stay well inside it.
DESCRIBE_CHUNK = 190


def _managed_suffixes():
    raw = os.environ.get('IPA_MANAGED_SUFFIXES', '').strip()
    if not raw:
        raise RuntimeError(
            "IPA_MANAGED_SUFFIXES is unset - refusing to sweep the whole realm"
        )
    suffixes = tuple(
        s.strip().lower().rstrip('.').lstrip('.')
        for s in raw.split(',')
        if s.strip()
    )
    if not suffixes or any(not suffix for suffix in suffixes):
        raise RuntimeError(
            "IPA_MANAGED_SUFFIXES contains an empty suffix - refusing to sweep"
        )
    return tuple(dict.fromkeys(suffixes))


def list_ipa_hosts(session, freeipa_host):
    """Return every FQDN FreeIPA knows about."""
    url = 'https://{}/ipa/session/json'.format(freeipa_host)
    header = {
        'referer': url,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
    data = {
        "method": "host_find",
        "params": [[], {"sizelimit": 0, "all": False, "version": "2.239"}],
        "id": 0,
    }
    response = session.post(url, headers=header, data=json.dumps(data), timeout=120)
    response.raise_for_status()
    body = response.json()
    if body.get("error"):
        raise RuntimeError("host_find failed: {}".format(body["error"]))

    result = body["result"]
    if result.get("truncated"):
        raise RuntimeError(
            "host_find result was truncated - raise the IPA search size limit "
            "before trusting this sweep"
        )

    fqdns = []
    for entry in result.get("result", []):
        value = entry.get("fqdn")
        if isinstance(value, list) and value:
            fqdns.append(value[0])
        elif isinstance(value, str):
            fqdns.append(value)
    return fqdns


def live_instance_ids(instance_ids):
    """Return the subset of instance_ids EC2 still knows about, in any state."""
    alive = set()
    ids = sorted(instance_ids)
    for start in range(0, len(ids), DESCRIBE_CHUNK):
        chunk = ids[start:start + DESCRIBE_CHUNK]
        paginator = ec2.get_paginator('describe_instances')
        pages = paginator.paginate(
            Filters=[{'Name': 'instance-id', 'Values': chunk}]
        )
        for page in pages:
            for reservation in page.get('Reservations', []):
                for instance in reservation.get('Instances', []):
                    alive.add(instance['InstanceId'])
    return alive


def find_orphans(fqdns, suffixes):
    """Map instance_id -> fqdn for candidates inside the managed suffixes."""
    candidates = {}
    for fqdn in fqdns:
        normalized_fqdn = fqdn.rstrip('.').lower()
        if not any(
            normalized_fqdn == suffix or normalized_fqdn.endswith("." + suffix)
            for suffix in suffixes
        ):
            continue
        match = INSTANCE_ID_RE.search(fqdn)
        if not match:
            continue
        candidates[match.group(1)] = fqdn
    return candidates


def lambda_handler(event, context):
    suffixes = _managed_suffixes()
    apply_changes = os.environ.get('RECONCILE_APPLY', 'false').lower() == 'true'
    max_deletes = int(os.environ.get('RECONCILE_MAX_DELETES', '25'))

    freeipa_host, user, password = _freeipa_credentials()
    session = _ipa_session(freeipa_host, user, password)

    fqdns = list_ipa_hosts(session, freeipa_host)
    candidates = find_orphans(fqdns, suffixes)
    logger.info(
        "FreeIPA knows %d hosts; %d are ASG-managed under %s",
        len(fqdns), len(candidates), ",".join(suffixes),
    )

    if not candidates:
        return {"checked": len(fqdns), "orphans": 0, "deleted": 0}

    alive = live_instance_ids(set(candidates))
    orphans = {iid: fqdn for iid, fqdn in candidates.items() if iid not in alive}

    logger.info("%d managed hosts, %d alive, %d orphaned",
                len(candidates), len(alive), len(orphans))
    for iid, fqdn in sorted(orphans.items(), key=lambda kv: kv[1]):
        logger.info("ORPHAN %s (instance %s absent from EC2)", fqdn, iid)

    _put_metric('OrphanedHosts', len(orphans))

    if len(orphans) > max_deletes:
        logger.error(
            "Found %d orphans which exceeds RECONCILE_MAX_DELETES=%d - refusing "
            "to delete anything. Investigate before raising the cap.",
            len(orphans), max_deletes,
        )
        _put_metric('ReconcileAborted', 1)
        return {"checked": len(fqdns), "orphans": len(orphans),
                "deleted": 0, "aborted": True}

    if not apply_changes:
        logger.info(
            "RECONCILE_APPLY is not 'true' - dry run, nothing deleted. "
            "The %d host(s) above would have been removed.", len(orphans),
        )
        return {"checked": len(fqdns), "orphans": len(orphans),
                "deleted": 0, "dry_run": True}

    deleted = 0
    for iid, fqdn in sorted(orphans.items(), key=lambda kv: kv[1]):
        ok, error = _host_del_once(session, freeipa_host, fqdn)
        if ok:
            logger.info("Reconcile deleted stale host %s", fqdn)
            deleted += 1
        else:
            logger.error("Reconcile could not delete %s: %s", fqdn, error)
            _emit_failure_metric(fqdn, "Reconcile:{}".format(error))

    _put_metric('ReconcileDeleted', deleted)
    return {"checked": len(fqdns), "orphans": len(orphans), "deleted": deleted}


def _put_metric(name, value):
    try:
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{'MetricName': name, 'Value': value, 'Unit': 'Count'}],
        )
    except Exception:
        logger.exception("Could not publish %s metric", name)


if __name__ == "__main__":
    logging.basicConfig()
    print(json.dumps(lambda_handler({}, None), indent=2))
