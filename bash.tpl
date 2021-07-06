# Set up FreeIPA client
# In FreeIPA hosts register with their default AWS hostname
REGION="`wget -qO- http://instance-data/latest/meta-data/placement/availability-zone | sed -e 's:\([0-9][0-9]*\)[a-z]*\$:\\1:'`"
## These two need to be tweaked to pull the two secret values correctly.
FREEIPA_PRINCIPAL_USER ="`aws secretsmanager get-secret-value --region "$REGION" --secret-id ${freeipa_secret_id} --query 'SecretString' | sed 's|["\{}]||g' | cut -d':' -f 2`"
FREEIPA_PRINCIPAL_PASSWORD ="`aws secretsmanager get-secret-value --region "$REGION" --secret-id ${freeipa_secret_id} --query 'SecretString' | sed 's|["\{}]||g' | cut -d':' -f 2`"
ipa-client-install --unattended -N --force-join --mkhomedir --domain=${freeipa_domain} --server=${freeipa_servers} --principal="$FREEIPA_PRINCIPAL_USER" --password="$FREEIPA_PRINCIPAL_PASSWORD"