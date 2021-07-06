# devops-tf-module-aws-freeipa-registration

The following module is designed to be used with autoscaling groups and ec2 instances to create the aws resources necessary
to register a instance or autoscaling group with a freeIPA server(s). 

The idea is to use this module to create a snippet of a bash script which will execute when the instance is started, 
the module can be used in one of two ways. Either you pass through the appropriate aws secrets and role ARNs or alternatively it will create them on your behalf.

The module will fail if the IAM roles or secrets already exists so preferrably you would make them prior and pass the values in.

We expect the secret to be in JSON format and contain the following key value pair:
freeipa_principal_user: XXXXXXXX
freeipa_principal_password: XXXXXXXX

The AWS Secrets GUI console will help you format this automatically.