
+++
title = "Creating an AWS Client VPN with Terraform and Serverless CA"
slug= "aws-client-vpn-terraform"
description = "Create a certificate-based AWS Client VPN for less than $400 a month"
date = "2025-04-11"
[taxonomies] 
tags = ["aws", "terraform", "vpn", "serverless-ca", "spiffe"]
+++

This post guides you through setting up a secure, cost-effective AWS Client VPN using Terraform and the open-source Serverless CA for certificate management.

## Problem Statement

You have resources in a private subnet in your AWS VPC - such as an EC2 instance, an RDS or Aurora database, or an MSK Kafka cluster - that are not publicly accessible. You'd like to access these resources from outside your VPC (e.g., from your laptop), without exposing them to the public internet.

## Solution

We'll setup an AWS Client VPN to enable you connect to the resources from anywhere. AWS Client VPN is a managed service, which means AWS handles the infrastructure and scaling, so you can focus on access and security.

![Architecture diagram showing the setup involving connecing a GitHub Codespaces to an EC2 in a private subnet via AWS Client VPN](./client-vpn.png)

Our setup here will be just a VPC with a private subnet and no internet gateway, A.K.A a fully private VPC. 

## Prerequisites

- Route 53 Zone

- AWS VPC with a private subnet (i.e subnet with no route to an internet gateway)

- AWS resource that we'll be connecting to via the VPN, e.g. an EC2 instance

- A private CA

## Why use a CA

AWS Client VPN offers multiple [authentication options](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/client-authentication.html) including SAML and AD. However, we will be going with certificate-based mutual authentication.  I chose the CA based option because:
- I want to be able to connect to the VPN sans gui, for example in a GitHub Codespace, and the SAML option requires a browser interaction for IdP authentication
- I plan to use this CA as a foundation for other auth scenarios as well (think [SPIFFE/SPIRE](https://spiffe.io/), [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html), etc).


## Choosing a CA

While AWS offers a managed Certificate Authority through [AWS Private CA](https://docs.aws.amazon.com/privateca/latest/userguide/PcaWelcome.html), the version compatible with AWS Client VPN costs $400/month. There is a more affordable [$50/month option](https://aws.amazon.com/blogs/security/how-to-use-aws-private-certificate-authority-short-lived-certificate-mode/) that issues short-lived certificates, but I couldn’t get it working with Client VPN.

You can follow [these instructions](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/client-auth-mutual-enable.html) to manually create the necessary certificates—that approach works fine. However, if you ever need to revoke access, you'll need to ensure you still have access to the original server in order to [generate](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-working-certificates-generate.html) a certificate revocation list (CRL).

Instead, we'll use the excellent [Serverless CA on AWS](https://serverlessca.com/) project. It’s an open-source CA with an IaC-based [revocation](https://serverlessca.com/revocation/) mechanism that's available as a Terraform [module](https://registry.terraform.io/modules/serverless-ca/ca/aws/latest) and  runs on AWS for roughly $50 per year.

### Setting up Serverless CA

Create a directory where we'll store our Terraform and other config. Throughout the rest of this post, we'll assume you're working from the root of this directory.

Serverless CA expects an aws provider [alias](https://developer.hashicorp.com/terraform/language/providers/configuration#alias-multiple-provider-configurations) named with the destination region in addition to any other providers you may already have. 

```
provider "aws" {
  region = "us-east-1"

}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}
```
Once your provider is setup, you can pass it to the CA module as shown below. Make sure to specify both `issuing_ca_key_spec` and `root_ca_key_spec` as `RSA_2048`. This is necessary because in a future step, we'll want to add the generated certificates to AWS ACM and the default `ECC_NIST_P256` is [not supported](https://docs.aws.amazon.com/acm/latest/userguide/import-certificate-prerequisites.html) by ACM. As for `cert_info_files` and `csr_files`, we'll be generating them in the next section.

```
module "certificate_authority" {
  source  = "serverless-ca/ca/aws"
  version = "1.8.0"

  providers = {
    aws           = aws
    aws.us-east-1 = aws.us-east-1
  }
  hosted_zone_domain  = "cert.misaac.me"
  hosted_zone_id      = aws_route53_zone.primary.zone_id
  public_crl          = true
  issuing_ca_key_spec = "RSA_2048"
  root_ca_key_spec    = "RSA_2048"
  env                 = "dev"
  cert_info_files     = ["tls", "revoked", "revoked-root-ca"]
  csr_files           = ["vpn.csr"]
}
```

### Generating a server certificate 

You can use Terraform to generate the CA via GitOps. The steps are:
- setup subdirectories and required files
- create a CSR
- sign the CSR
- run the generate certificate step function

Let's tackle these step-by-step.

#### Setup subdirectories and required files

Run the command below to create the required files and folders. Substitute `dev` with your desired environment.

```
mkdir -p certs/dev/csrs && \
for f in revoked-root-ca revoked tls; do \
  echo "[]" > certs/dev/$f.json; \
done
```

This should generate the files structure below.  At this point, each json file currently contains just an empty array `[]`.


```
certs
└── dev
    ├── csrs
    ├── revoked-root-ca.json
    ├── revoked.json
    └── tls.json

3 directories, 3 files

```

#### Create Certificate Signing Request (CSR)

A Certificate Signing Request (CSR) is an encoded file that contains your public key and identifying details, used by a Certificate Authority (CA) to issue an SSL/TLS certificate. Let's use the Terraform `tls_cert_request` [resource](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) to create our CSR. 

First, we need to generate our private key. I'm going to change directory and place this in `~/.ssh` so that we don't accidentally commit it. 

```
cd ~/.ssh &&
openssl genrsa -out vpn.key 2048 &&
cd -  
```

Next, we'll populate the `tls_cert_request` resource and save the generated csr to the `csrs` directory. Pass the private key using your preferred method, `--var-file="secrets.tfvars.json"` or `TF_VAR_cert_private_key` enviroment variable.
```
variable "cert_private_key" {
  type      = string
  sensitive = true
}

resource "tls_cert_request" "server" {
  private_key_pem = chomp(var.cert_private_key)

  subject {
    common_name         = "vpn.misaac.me"
    organization        = "Serverless Inc"
    organizational_unit = "Security Operations"
    locality            = "London"
    province            = "England"
    country             = "GB"
  }

  dns_names = ["vpn.misaac.me"]
}
```
> **Note:** 
> By using the `tls_cert_request` resource, we are choosing to store our private key in the Terraform state file. You'll need to evaluate if this is appropriate for your security posture. If not, you should generate the CSR outside Terraform using `openssl` or another tool, and then pass only the CSR into Terraform.

#### Sign the CSR 

Signing the CSR with a CA is how you create the certificate. To do this using our ServerlessCA deployment, we need to update `certs/dev/tls.json` to specify our server certificate details and then `terraform apply`. 

```
[
    {
        "common_name": "vpn.misaac.me",
        "purposes": [
            "client_auth",
            "server_auth"
        ],
        "sans": [
            "vpn.misaac.me"
        ],
        "lifetime": 365,
        "csr_file": "vpn.csr"
    }
]
```
#### Run the certificate generation step function

Once applied, we need to run the CA Step Function, which will be named something like `serverless-ca-dev` depending on your `env` name. You can use just `{}` as the input.

![AWS Web Console showing executed StepFunction page](./serverlessca-stepfunction.png)

Serverless CA will create the certificate based on the information in the CSR as well as the details entered in `certs/dev/tls.json`. Note that details entered in JSON e.g. Organization, Locality override those included in the CSR. 

On completion, click on the `Execution input and output` tab, and then copy the output json. 

### Adding the server certificate to ACM

To import the server certificate into ACM, we need the `private_key`, `certificate_body`, and the `certificate_chain`. Fortunately, these are all present in the output json we copied above. Add the variables `cert_body` and `cert_chain` using the values of the json keys `Base64Certificate` and  `Base64CaChain` respectively. 
```
variable "cert_body" {
  type      = string
  sensitive = true
}

variable "cert_chain" {
  type      = string
  sensitive = true
}

```

Then create your `aws_acm_certificate` resource. 

```
resource "aws_acm_certificate" "vpncert" {
  private_key       = chomp(var.cert_private_key)
  certificate_body  = base64decode(chomp(var.cert_body))
  certificate_chain = base64decode(chomp(var.cert_chain))
}
```
### Generating a client certificate 

Since we're performing mutual authentication, our test client will need its own certificate. Let's add the ability to generate client certificates to our Terraform. As noted earlier, consider generating the CSR outside Terraform using `openssl` or another tool, and then passing only the CSR into Terraform if you'd prefer to keep the private keys out of your Terraform state. Just make sure you save it in a secret/password manager as you'll need it later to connect. 

First, we'll create a variable to store the private key for our first vpn client. 

```
variable "client1_private_key_pem" {
  description = "PEM content of the private key for client1."
  type        = string
  sensitive   = true # <-- Mark the key content itself as sensitive
  # No default - this MUST be provided via environment variable
}
```
We'll generate that key using `openssl` as below and then pass it to Terraform at run time via an environment variable.. 

```
openssl genrsa -out ~/.ssh/client1.key 2048
```

Next, we'll set up a local variable that we can use for this and future cert requests. 

```
locals {
  # Construct the list using the injected variable and static data
  client_cert_requests = [
    {
      # Use the sensitive variable directly here
      private_key_pem = var.client1_private_key_pem
      # Keep the rest of your static configuration
      common_name         = "client1.misaac.me"
      organization        = "Serverless Inc"
      organizational_unit = "Security Operations"
      locality            = "London"
      province            = "England"
      country             = "GB"
    },
    # If you had more clients, you'd define more variables (e.g., client2_private_key_pem)
    # and add corresponding objects to this list.
    # {
    #   private_key_pem = var.client2_private_key_pem
    #   common_name     = "client2.example.com"
    #   ...
    # }
  ]
}

```

Then we'll add the required resources. Note that we don't use the `aws_acm_certificate` resource here - unlike with the server certificate, importing the client certificates into ACM is optional.

```
resource "tls_cert_request" "client_certs" {
  for_each        = { for cert in local.client_cert_requests : cert.common_name => cert }
  private_key_pem = chomp(each.value.private_key_pem)
  subject {
    common_name         = each.value.common_name
    organization        = each.value.organization
    organizational_unit = each.value.organizational_unit
    locality            = each.value.locality
    province            = each.value.province
    country             = each.value.country
  }
  dns_names = [each.value.common_name]

}

resource "local_file" "client_csrs" {
  for_each = { for cert in local.client_cert_requests : cert.common_name => cert }
  content  = tls_cert_request.client_certs[each.key].cert_request_pem
  filename = "${path.module}/certs/dev/csrs/${each.key}.csr"
}

```

Finally, we'll update the `csr_files` attribute to read all the csr files from our `client_cert_requests` variable. 

```
module "certificate_authority" {
  source  = "serverless-ca/ca/aws"
  version = "1.8.0"

  ...

  csr_files = concat(["vpn.csr"], [for cert in local.client_cert_requests : "${cert.common_name}.csr"])
}
```

Run `terraform apply` and then go run the Step function as we did for the server certificate. Again, copy and save the step function execution output as we'll need to add the certificate to our vpn config file later. 
<br>

## Setting up Client VPN
This is where all our pre-work above starts to gel. The steps are:
- Set up logging
- Create the VPN endpoint
- Associate a target network
- Add an authorization rule

### Setting up logging
Connection logging records client connection requests, outcomes (success or failure), failure reasons, and client termination time. Since we care about security, this observability is something we want to have.

```
resource "aws_cloudwatch_log_group" "client_vpn" {
  name = "aws-client-vpn-logs"
}

resource "aws_cloudwatch_log_stream" "client_vpn" {
  name           = "aws-client-vpn"
  log_group_name = aws_cloudwatch_log_group.client_vpn.name
}
```
### Create the Client VPN Endpoint

This is the resource that you create and configure to enable and manage client VPN sessions. It's the termination point for all client VPN sessions. Notice how we use the private CA issued server certificate we imported into ACM in the `server_certificate_arn` and `root_certificate_chain_arn` attributes. 

```
resource "aws_ec2_client_vpn_endpoint" "org" {
  description            = "misaac.me VPN"
  server_certificate_arn = aws_acm_certificate.vpncert.arn
  client_cidr_block      = "172.16.0.0/16"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.vpncert.arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.client_vpn.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.client_vpn.name
  }
  split_tunnel = true
  vpc_id       = aws_vpc.main.id
}
```
This is also where we plug in the log group we created earlier. 

> **Note:** 
> Take care to select a cidr range for your vpn endpoint that does not clash with the cidr range of your VPC


### Associate the VPN endpoint with the VPC and subnet

To allow clients to establish a VPN session, you associate a target network with the Client VPN endpoint. A target network is a subnet in a VPC. 

```
resource "aws_ec2_client_vpn_network_association" "subnet_b" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.org.id
  subnet_id              = aws_subnet.subnet_b.id
}
```
### Add an authorization rule for the VPC

Even though we've associated the network with the VPN endpoint above, clients can currently only establish a VPN connection. To access resources in the VPC, we must add authorization rules. 

```
resource "aws_ec2_client_vpn_authorization_rule" "subnet_b" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.org.id
  target_network_cidr    = aws_vpc.main.cidr_block
  authorize_all_groups   = true
}
```

<br>

## Connecting to Client VPN

To connect to the Client VPN, we'll need both the Client VPN endpoint configuration file and our generated client key and certificate from [generating a client certificate](#generating-a-client-certificate). 

### Prepare the Client VPN endpoint configuration file
1. Open the Amazon VPC console at [https://console.aws.amazon.com/vpc/](https://console.aws.amazon.com/vpc/)

1. In the navigation pane, choose **Client VPN Endpoints**.

1. Select the Client VPN endpoint that was just created, and choose **Download client configuration**.

1. Open the Client VPN endpoint configuration file using your preferred text editor. Add `<cert></cert>` and `<key></key>` tags to the file. Place the contents of the client certificate and the contents of the private key between the corresponding tags, as such:

    ```
    <cert>
    Contents of client certificate (.crt) file
    </cert>

    <key>
    Contents of private key (.key) file
    </key>
    ```
1. Save and close the Client VPN endpoint configuration file.

### Connect to the Client VPN endpoint
How you'll connect to the VPN depends on your OS as well as your VPN client. AWS provides its own [custom OpenVPN client](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/user-getting-started.html#install-client) that is designed to be compatible with all features of AWS Client VPN. However, since the goal was to use this in an Ubuntu Linux GitHub Codespace, we'll just use the bog standard OpenVPN client.

First we'll install openvpn. 
```
sudo apt-get update && sudo apt-get install openvpn
```

Then we can connect using: 

```
sudo openvpn --config /path/to/config/file
```
<br>

If all went well, you should see this:

```
@mbuotidem ➜ /workspaces/mbuotidem.github.io (main) $ sudo openvpn --config o.ovpn
Sat Apr 12 00:40:17 2025 OpenVPN 2.4.12 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [PKCS11] [MH/PKTINFO] [AEAD] built on Jun 27 2024
Sat Apr 12 00:40:17 2025 library versions: OpenSSL 1.1.1f  31 Mar 2020, LZO 2.10
Sat Apr 12 00:40:17 2025 TCP/UDP: Preserving recently used remote address: [AF_INET]3.XXX.XXX.72:443
Sat Apr 12 00:40:17 2025 Socket Buffers: R=[1048576->1048576] S=[212992->212992]
...

Sat Apr 12 00:40:19 2025 Outgoing Data Channel: Cipher 'AES-256-GCM' initialized with 256 bit key
Sat Apr 12 00:40:19 2025 Incoming Data Channel: Cipher 'AES-256-GCM' initialized with 256 bit key
Sat Apr 12 00:40:19 2025 ROUTE_GATEWAY 10.0.0.1/255.255.0.0 IFACE=eth0 HWADDR=7c:1e:52:5b:bf:9b
Sat Apr 12 00:40:19 2025 TUN/TAP device tun0 opened
Sat Apr 12 00:40:19 2025 TUN/TAP TX queue length set to 100
Sat Apr 12 00:40:19 2025 /sbin/ip link set dev tun0 up mtu 1500
Sat Apr 12 00:40:19 2025 /sbin/ip addr add dev tun0 172.16.0.13/27 broadcast 172.16.0.31
Sat Apr 12 00:40:19 2025 /sbin/ip route add 172.31.0.0/16 via 172.16.0.1
Sat Apr 12 00:40:19 2025 Initialization Sequence Completed
```

You can now leave that terminal window running, open a new one, and ssh, curl, or otherwise connect to the resource in your private subnet!

### Wrapping Up

That’s it! You now have a fully functional, certificate-based AWS Client VPN setup — without having to pay AWS Private CA’s [hefty price tag](https://aws.amazon.com/private-ca/pricing/). By using Serverless CA and Terraform, we’ve built a scalable, revocable, and IaC backed VPN solution that runs for under $50 a year.

From here, we can layer on additional access controls, integrate with IAM Roles Anywhere, or extend the same CA for internal services using SPIFFE.

<!-- https://aws.amazon.com/blogs/security/connect-your-on-premises-kubernetes-cluster-to-aws-apis-using-iam-roles-anywhere/ -->