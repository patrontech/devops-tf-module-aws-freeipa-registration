module "freeipa_module" {
  source = "../"
  name = "scx"
  aws_tags = {
    env_name = "testenv"
    env = "test"
  }
  freeipa_domain = "AWSCLIX.IO"
  freeipa_principal_user = "ADMIN"
  freeipa_principal_password = "PASSWORD"
  freeipa_secret_arn = ""
  freeipa_create_iam_policy = true
}

resource "aws_iam_instance_profile" "my_example" {
  name = "my_profile"
  role = aws_iam_role.my_example.name
}

resource "aws_iam_role_policy_attachment" "my_example" {
  policy_arn = module.freeipa_module.freeipa_policy_arn
  role       = aws_iam_role.my_example.name
}

resource "aws_iam_role" "my_example" {
  name = "test_role"
  path = "/"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_instance" "my_example" {
  ami = "some-ami-goes-here"
  instance_type = "t2.small"
  iam_instance_profile = aws_iam_instance_profile.my_example.name
  user_data = base64encode(module.freeipa_module.bash_script_snippet)
}