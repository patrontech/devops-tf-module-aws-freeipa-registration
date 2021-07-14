#!/bin/bash
# Set up FreeIPA client for the instance - this will also set the hostname.
# This is automatically generated by Terraform
# Expects freeipa-client, and jq to be installed on the machine.
REGION="`curl --silent http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region`"
INSTANCE_ID="`curl --silent http://instance-data/latest/meta-data/instance-id`"
TAG_NAME="${ec2_fqdn_tag}"
FREEIPA_SECRET_NAME=${freeipa_secret_name}
FQDN="`aws ec2 describe-tags --filters \"Name=resource-id,Values=$INSTANCE_ID\" --region $REGION \"Name=key,Values=$TAG_NAME\" | jq -r .Tags[0].Value`"
FREEIPA_HOSTS="`aws secretsmanager get-secret-value --region \"$REGION\" --secret-id \"$FREEIPA_SECRET_NAME\" | jq -c '.SecretString | fromjson' | jq -r .Host`"
FREEIPA_PRINCIPAL_USER="`aws secretsmanager get-secret-value --region \"$REGION\" --secret-id \"$FREEIPA_SECRET_NAME\" | jq -c '.SecretString | fromjson' | jq -r .User`"
FREEIPA_PRINCIPAL_PASSWORD="`aws secretsmanager get-secret-value --region \"$REGION\" --secret-id \"$FREEIPA_SECRET_NAME\" | jq -c '.SecretString | fromjson' | jq -r .Password`"
FREEIPA_DOMAIN="`aws secretsmanager get-secret-value --region \"$REGION\" --secret-id \"$FREEIPA_SECRET_NAME\" | jq -c '.SecretString | fromjson' | jq -r .Domain`"
ipa-client-install --unattended -N --force-join --mkhomedir --domain=$FREEIPA_DOMAIN --server=$FREEIPA_HOSTS --principal=$FREEIPA_PRINCIPAL_USER --password=$FREEIPA_PRINCIPAL_PASSWORD --hostname=$FQDN
