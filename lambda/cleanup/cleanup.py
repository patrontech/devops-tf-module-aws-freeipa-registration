import json
import logging
import os
import random
import re
import sys
import time

import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

autoscaling = boto3.client('autoscaling')
ec2 = boto3.client('ec2')
route53 = boto3.client('route53')
secrets = boto3.client('secretsmanager')
cloudwatch = boto3.client('cloudwatch')

HOSTNAME_TAG_NAME = "asg:hostname_pattern"
LIFECYCLE_KEY = "LifecycleHookName"
ASG_KEY = "AutoScalingGroupName"

METRIC_NAMESPACE = os.environ.get('METRIC_NAMESPACE', 'FreeIPA/Registration')

# Concurrent ASG churn causes 389-ds transaction collisions, which the IPA JSON
# API returns as DatabaseError. These are transient and succeed on retry. The
# previous version never looked at the response at all, so every one of these
# was silently discarded and left a stale host entry behind holding a valid
# host principal.
RETRYABLE_ERRORS = {
    "DatabaseError",
    "TimeLimitExceeded",
    "NetworkError",
    "ServerNetworkError",
    "ServerTimeout",
    "RequestError",
}
MAX_ATTEMPTS = int(os.environ.get('HOST_DEL_MAX_ATTEMPTS', '5'))

# The IPA server presents a certificate signed by the realm's own CA, which is
# not in certifi's trust store. Point FREEIPA_CA_BUNDLE at a bundled CA cert to
# enable verification; unset, we fall back to the previous unverified behaviour
# rather than breaking every caller that has not shipped the CA yet.
CA_BUNDLE = os.environ.get('FREEIPA_CA_BUNDLE')


# Builds a hostname according to pattern
# take value like this gtix-app-ecs-node-#instanceid.hendrix.growtix.io@Z03189832E1MB6GAGNFFA and make it
# like this gtix-app-ecs-node-i-092c9621eb2fddc09.hendrix.growitx.io
def get_instance_fqdn(hostname_pattern, instance_id):
    fqdn = hostname_pattern.replace('#instanceid', instance_id)
    fqdn_split = fqdn.split("@", 1)
    return fqdn_split[0]

# Fetches relevant tags from ASG
# Returns tuple of hostname_pattern, zone_id
def fetch_tag_metadata(asg_name):
    logger.info("Fetching tags for ASG: %s", asg_name)

    tag_value = autoscaling.describe_tags(
        Filters=[
            {'Name': 'auto-scaling-group', 'Values': [asg_name]},
            {'Name': 'key', 'Values': [HOSTNAME_TAG_NAME]}
        ],
        MaxRecords=1
    )['Tags'][0]['Value']
    logger.info("Found tags for ASG %s: %s", asg_name, tag_value)
    return tag_value.split("@")


def _freeipa_credentials():
    arn = os.environ['FREEIPA_SECRET_ARN']
    secret = json.loads(secrets.get_secret_value(SecretId=arn)['SecretString'])
    return secret["Host"], secret["User"], secret["Password"]


def _ipa_session(freeipa_host, user, password):
    session = requests.Session()
    session.verify = CA_BUNDLE if CA_BUNDLE else False
    if not CA_BUNDLE:
        logger.warning(
            "FREEIPA_CA_BUNDLE is unset - TLS verification is DISABLED for %s",
            freeipa_host,
        )
    url = 'https://{}/ipa/session/login_password'.format(freeipa_host)
    header = {
        'referer': url,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'text/plain',
    }
    response = session.post(
        url, headers=header,
        data={'user': user, 'password': password},
        timeout=30,
    )
    response.raise_for_status()
    return session


def _host_del_once(session, freeipa_host, fqdn):
    """Issue one host_del. Returns (ok, error_name).

    A host that is already absent counts as success - this has to be idempotent
    because we retry, and because the reconcile sweep may have got there first.
    """
    url = 'https://{}/ipa/session/json'.format(freeipa_host)
    header = {
        'referer': url,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
    data = {
        "method": "host_del",
        "params": [[fqdn], {"version": "2.239", "updatedns": False}],
        "id": 0,
    }
    response = session.post(url, headers=header, data=json.dumps(data), timeout=30)
    if response.status_code != 200:
        return False, "HTTP{}".format(response.status_code)

    try:
        body = response.json()
    except ValueError:
        return False, "UnparseableResponse"

    error = body.get("error")
    if not error:
        return True, None
    if error.get("name") == "NotFound":
        logger.info("FreeIPA record %s was already absent", fqdn)
        return True, None
    return False, error.get("name", "unknown")


def _emit_failure_metric(fqdn, reason):
    try:
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{
                'MetricName': 'HostDelFailed',
                'Value': 1,
                'Unit': 'Count',
                'Dimensions': [{'Name': 'Reason', 'Value': reason[:255]}],
            }],
        )
    except Exception:  # never let telemetry break the lifecycle path
        logger.exception("Could not publish HostDelFailed metric for %s", fqdn)


def remove_freeipa_record(ec2_hostname, remaining_ms=None):
    """Delete the host from FreeIPA, retrying transient collisions.

    Returns True on success. On permanent failure we log and emit a metric but
    do NOT raise - see lambda_handler for why the ASG must still be released.

    `remaining_ms` is an optional callable returning the lambda's remaining
    execution time. Retrying is what makes this function slow, and SNS delivers
    records in batches, so without a budget check a few slow records could burn
    the whole invocation and leave later instances stuck until their lifecycle
    hook times out. We stop retrying rather than let that happen.
    """
    freeipa_host, user, password = _freeipa_credentials()

    try:
        session = _ipa_session(freeipa_host, user, password)
    except Exception as exc:
        logger.error("FreeIPA login failed for %s: %s", freeipa_host, exc)
        _emit_failure_metric(ec2_hostname, "LoginFailed")
        return False

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            ok, error = _host_del_once(session, freeipa_host, ec2_hostname)
        except requests.exceptions.RequestException as exc:
            ok, error = False, "RequestError"
            logger.warning(
                "host_del %s raised a transport error on attempt %d/%d: %s",
                ec2_hostname, attempt, MAX_ATTEMPTS, exc,
            )
        if ok:
            logger.info("Deleted FreeIPA record %s (attempt %d)", ec2_hostname, attempt)
            return True

        if error not in RETRYABLE_ERRORS:
            logger.error(
                "host_del %s failed permanently: %s", ec2_hostname, error
            )
            _emit_failure_metric(ec2_hostname, error)
            return False

        if attempt == MAX_ATTEMPTS:
            break

        delay = min(2 ** attempt, 20) + random.uniform(0, 3)

        # Leave enough headroom to finish this record and release the remaining
        # records' lifecycle hooks.
        if remaining_ms is not None:
            budget_ms = (delay * 1000) + 30000 + 15000
            if remaining_ms() < budget_ms:
                logger.warning(
                    "host_del %s got %s but only %dms of lambda time remains - "
                    "giving up on retries to avoid stranding the batch",
                    ec2_hostname, error, remaining_ms(),
                )
                break

        logger.warning(
            "host_del %s got %s (attempt %d/%d); retrying in %.1fs",
            ec2_hostname, error, attempt, MAX_ATTEMPTS, delay,
        )
        time.sleep(delay)

    logger.error(
        "host_del %s exhausted %d attempts - stale entry left behind",
        ec2_hostname, MAX_ATTEMPTS,
    )
    _emit_failure_metric(ec2_hostname, "RetriesExhausted")
    return False


# Processes a scaling event
# Builds a hostname from tag metadata, fetches a IP, and updates records accordingly
def process_message(message, remaining_ms=None):
    if 'LifecycleTransition' not in message:
        logger.info("Processing %s event", message.get('Event'))
        return
    logger.info("Processing %s event", message['LifecycleTransition'])
    if message['LifecycleTransition'] in (
        "autoscaling:EC2_INSTANCE_TERMINATING",
        "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    ):
        asg_name = message['AutoScalingGroupName']
        instance_id = message['EC2InstanceId']
        hostname_pattern, zone_id = fetch_tag_metadata(asg_name)
        remove_freeipa_record(
            get_instance_fqdn(hostname_pattern, instance_id),
            remaining_ms=remaining_ms,
        )
    else:
        logger.info("Was a %s event - skipping", message.get('Event'))
    return


def complete_lifecycle(message):
    """Release the ASG lifecycle hook for one record.

    This is deliberately called whether or not the FreeIPA deletion succeeded.
    For EC2_INSTANCE_TERMINATING both CONTINUE and ABANDON terminate the
    instance anyway, so refusing to complete buys nothing and risks stranding
    ASG capacity until the hook times out. A stale directory entry is the far
    smaller problem - it is alarmed on via the HostDelFailed metric and swept
    up by the reconcile lambda.
    """
    if LIFECYCLE_KEY not in message or ASG_KEY not in message:
        logger.info("No lifecycle hook on this message - nothing to complete")
        return
    response = autoscaling.complete_lifecycle_action(
        LifecycleHookName=message['LifecycleHookName'],
        AutoScalingGroupName=message['AutoScalingGroupName'],
        InstanceId=message['EC2InstanceId'],
        LifecycleActionToken=message['LifecycleActionToken'],
        LifecycleActionResult='CONTINUE',
    )
    logger.info("ASG action complete: %s", response)


# Main handler where the SNS events end up to
# Events are bulked up, so process each Record individually
def lambda_handler(event, context):
    logger.info("Processing SNS event: %s", json.dumps(event))

    # Previously the lifecycle action was completed once, after the loop, using
    # the leaked loop variable - so in a batch of N records only the last
    # instance was ever released and the rest hung until the hook timed out.
    remaining_ms = None
    if context is not None and hasattr(context, 'get_remaining_time_in_millis'):
        remaining_ms = context.get_remaining_time_in_millis

    completion_error = None
    for record in event['Records']:
        message = json.loads(record['Sns']['Message'])
        try:
            process_message(message, remaining_ms=remaining_ms)
        except Exception:
            logger.exception("Failed processing record; releasing lifecycle anyway")
        finally:
            try:
                complete_lifecycle(message)
            except ClientError as exc:
                # On a Lambda retry of the whole SNS batch, hooks released on the
                # previous attempt are already gone. Treat that as done, or the
                # retry fails forever on records that succeeded the first time.
                if "No active Lifecycle Action" in str(exc):
                    logger.info("Lifecycle action already completed or expired: %s", exc)
                else:
                    logger.exception("Could not complete lifecycle action")
                    completion_error = completion_error or exc
            except Exception as exc:
                logger.exception("Could not complete lifecycle action")
                completion_error = completion_error or exc

    if completion_error is not None:
        raise completion_error


# if invoked manually, assume someone pipes in a event json
if __name__ == "__main__":
    logging.basicConfig()
    lambda_handler(json.load(sys.stdin), None)
