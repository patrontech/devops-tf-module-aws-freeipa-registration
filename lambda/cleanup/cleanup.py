import json
import logging
import boto3
import sys
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

autoscaling = boto3.client('autoscaling')
ec2 = boto3.client('ec2')
route53 = boto3.client('route53')

HOSTNAME_TAG_NAME = "asg:hostname_pattern"
LIFECYCLE_KEY = "LifecycleHookName"
ASG_KEY = "AutoScalingGroupName"

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
            {'Name': 'auto-scaling-group','Values': [asg_name]},
            {'Name': 'key','Values': [HOSTNAME_TAG_NAME]}
        ],
        MaxRecords=1
    )['Tags'][0]['Value']
    logger.info("Found tags for ASG %s: %s", asg_name, tag_value)
    return tag_value.split("@")

def remove_freeipa_record(ec2_hostname):
    freeipa_credential_aws_secret_arn = os.environ['FREEIPA_SECRET_ARN']
    freeipa_host = json.loads(secrets.get_secret_value(SecretId=freeipa_credential_aws_secret_arn)['SecretString'])["Host"]
    freeipa_user = json.loads(secrets.get_secret_value(SecretId=freeipa_credential_aws_secret_arn)['SecretString'])["User"]
    freeipa_password = json.loads(secrets.get_secret_value(SecretId=freeipa_credential_aws_secret_arn)['SecretString'])["Password"]
    session = requests.Session()
    session.verify = False
    url = 'https://{}/ipa/session/login_password'.format(freeipa_host)
    header = {'referer':'https://{}/ipa/session/login_password'.format(freeipa_host),'Content-Type':'application/x-www-form-urlencoded','Accept':'text/plain'}
    login = {'user':freeipa_user,'password':freeipa_password}
    response = session.post(url, headers=header, data=login)
    url = 'https://{}/ipa/session/json'.format(freeipa_host)
    header = {'referer':'https://{}/ipa/session/json'.format(freeipa_host),'Content-Type':'application/json','Accept':'application/json'}
    data = {"method":"host_del","params":[[ec2_hostname],{"version":"2.239","updatedns":False}],"id":0}
    response = session.post(url, headers=header, data=json.dumps(data))
    logger.info("Deleted FreeIPA Record %s", response.content)
    return

# Processes a scaling event
# Builds a hostname from tag metadata, fetches a IP, and updates records accordingly
def process_message(message):
    if 'LifecycleTransition' not in message:
        logger.info("Processing %s event", message['Event'])
        return
    logger.info("Processing %s event", message['LifecycleTransition'])
    if message['LifecycleTransition'] == "autoscaling:EC2_INSTANCE_TERMINATING" or message['LifecycleTransition'] == "autoscaling:EC2_INSTANCE_LAUNCH_ERROR":
        asg_name = message['AutoScalingGroupName']
        instance_id = message['EC2InstanceId']
        hostname_pattern, zone_id = fetch_tag_metadata(asg_name)
        remove_freeipa_record(get_instance_fqdn(hostname_pattern,instance_id))
    else:
        logger.info("Was a %s event - skipping", message['Event'])
        return
    return

# Picks out the message from a SNS message and deserializes it
def process_record(record):
    process_message(json.loads(record['Sns']['Message']))

# Main handler where the SNS events end up to
# Events are bulked up, so process each Record individually
def lambda_handler(event, context):
    logger.info("Processing SNS event: " + json.dumps(event))

    for record in event['Records']:
        process_record(record)

# Finish the asg lifecycle operation by sending a continue result
    logger.info("Finishing ASG action")
    message =json.loads(record['Sns']['Message'])
    if LIFECYCLE_KEY in message and ASG_KEY in message :
        response = autoscaling.complete_lifecycle_action (
            LifecycleHookName = message['LifecycleHookName'],
            AutoScalingGroupName = message['AutoScalingGroupName'],
            InstanceId = message['EC2InstanceId'],
            LifecycleActionToken = message['LifecycleActionToken'],
            LifecycleActionResult = 'CONTINUE'

        )
        logger.info("ASG action complete: %s", response)
    else :
        logger.error("No valid JSON message")

# if invoked manually, assume someone pipes in a event json
if __name__ == "__main__":
    logging.basicConfig()
    lambda_handler(json.load(sys.stdin), None)
