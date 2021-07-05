provider "aws"
  profile = "default"
  region = ""


module "aws_secret"{
  source = "patrontech/devops-tf-module-aws-freeipa-registration"

  secret = [
  {
  name          = "secret1"
  description   = "AWS secret"
  secret_binary = "example"
  }
  ]
}


resource "aws_instance" "web" {


  provisioner "bootstrap" {
    source      = "bootstrap.sh"
    destination = "patrontech/sc-devops/blob/master/terraform/aws/modules/cluster/bootsrap.sh"
  }
  provisioner "remote-exec" {
    inline = [
    "chmod +x patrontech/sc-devops/blob/master/terraform/aws/modules/cluster/bootsrap.sh",
    "patrontech/sc-devops/blob/master/terraform/aws/modules/cluster/bootsrap.sh"
    ]
  }
}


resource "aws_iam_role" "script_role" {
  name = "script_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}
