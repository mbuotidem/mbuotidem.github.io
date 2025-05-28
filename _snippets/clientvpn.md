
To setup an AWS Client VPN endpoint, we need to :

- Set up logging
- Add a security group rule to allow access to your target resource
- Create the VPN endpoint
- Associate a target network
- Add an authorization rule

### Setting up logging

Connection logging records client connection requests, outcomes (success or failure), failure reasons, and client
termination time. Since we care about security, this observability is something we want to have.

```
resource "aws_cloudwatch_log_group" "client_vpn" {
name = "aws-client-vpn-logs"
}

resource "aws_cloudwatch_log_stream" "client_vpn" {
name = "aws-client-vpn"
log_group_name = aws_cloudwatch_log_group.client_vpn.name
}
```

### Add a security group rule to allow access to your target resource

If you create an AWS Client VPN endpoint without specifiying a security group, the VPC's default security group is
automatically applied to it.

AWS strongly recommends that default security groups restrict all inbound and outbound traffic, even though they cannot
be deleted. This is because inadvertently assigning a new AWS resource to the default security group can lead to
unauthorized access if it has open rules.

If your are following this best practice (which you should), you'll need to create a security group/security group rule
to allow access from the VPN to your target resource. Adjust the ingress rules (port, protocol) based on the resource
you need to access (e.g., port 5432 for PostgreSQL).

```
resource "aws_security_group" "allow_ssh" {
name = "allow_ssh"
description = "Allow SSH inbound traffic and all outbound traffic"
vpc_id = aws_vpc.main.id

tags = {
Name = "allow_ssh"
}
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ipv4" {
security_group_id = aws_security_group.allow_ssh.id
cidr_ipv4 = aws_vpc.main.cidr_block
from_port = 22
ip_protocol = "tcp"
to_port = 22
}
resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
security_group_id = aws_security_group.allow_ssh.id
cidr_ipv4 = "0.0.0.0/0"
ip_protocol = "-1" # semantically equivalent to all ports
}
```
<br>

### Create the Client VPN Endpoint

This is the central resource you create and manage to enable secure connections between your remote users and your AWS
resources. It acts as the termination point for all client VPN sessions.

> **Note:**
> Take care to select a cidr range for your vpn endpoint that does not clash with the cidr range of your VPC.


```
resource "aws_ec2_client_vpn_endpoint" "org" {
description = "misaac.me VPN"
server_certificate_arn = aws_acm_certificate.vpncert.arn
client_cidr_block = "172.16.0.0/16"

authentication_options {
type = "certificate-authentication"
root_certificate_chain_arn = aws_acm_certificate.vpncert.arn
}

connection_log_options {
enabled = true
cloudwatch_log_group = aws_cloudwatch_log_group.client_vpn.name
cloudwatch_log_stream = aws_cloudwatch_log_stream.client_vpn.name
}
split_tunnel = true
vpc_id = aws_vpc.main.id
security_group_ids = [aws_security_group.allow_ssh.id]
}
```
Notice how we reference the server certificate issued which we previously imported into ACM — in both
`server_certificate_arn` and `root_certificate_chain_arn`.

Since our client certificates will also be issued by the same CA, we can use the same certificate ARN as
the trust anchor for both server and client authentication. This allows any client certificate signed by the same CA to
be accepted during mutual TLS authentication.

We're also setting `split_tunnel` to `true`. This ensures that only traffic destined for resources inside the VPN is
routed through the VPN tunnel, while all other internet traffic continues to go through the user's local network.

If we left `split_tunnel` set to its default value of `false`, all traffic—including internet-bound requests—would be
routed through the VPN. Because the our fully-private VPC has no public internet access, this would effectively break
the user's connection, blackholing their traffic the moment they connect.

If you're reading this and you intend to set this up with an internet-connected vpc, note that `split_tunnel` might
still be useful for you if your security posture allows and you'd like to save on data transfer costs by only routing
AWS-bound traffic through the VPN.


### Associate the VPN endpoint with the VPC and subnet

To route VPN traffic into your VPC, you need to associate the endpoint with a **target network** — which is just a
subnet in your VPC. This tells AWS where to send traffic from connected clients.

```
resource "aws_ec2_client_vpn_network_association" "subnet_b" {
client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.org.id
subnet_id = aws_subnet.subnet_b.id
}
```
### Add an authorization rule for the VPC

Even after associating a subnet, clients can’t access anything yet — you need to explicitly allow it with an
authorization rule.

```
resource "aws_ec2_client_vpn_authorization_rule" "subnet_b" {
client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.org.id
target_network_cidr = aws_vpc.main.cidr_block
authorize_all_groups = true
}
```

<br>

## Connecting to Client VPN

To connect to the Client VPN, we'll need both the Client VPN endpoint configuration file and our generated client key
and certificate.

### Prepare the Client VPN endpoint configuration file
1. Open the Amazon VPC console at [https://console.aws.amazon.com/vpc/](https://console.aws.amazon.com/vpc/)

1. In the navigation pane, choose **Client VPN Endpoints**.

1. Select the Client VPN endpoint that was just created, and choose **Download client configuration**.

1. Open the Client VPN endpoint configuration file using your preferred text editor. Add `<cert></cert>` and `<key>
</key>` tags to the file. Place the contents of the client certificate and the contents of the private key between the
corresponding tags, as such:

```
<cert>
path to client certificate (.crt) file
</cert>

<key>
path to private key (.key) file
</key>
```
1. Save and close the Client VPN endpoint configuration file.

1. Add the line `pull-filter ignore "redirect-gateway"` to the ovpn file.

> **Note:** Step 6 deserves a bit of explanation. During testing on a local device using the AWS-provided VPN client, I
found that AWS Client VPN was still routing all traffic through the VPN—even though `split_tunnel` was enabled. The
culprit was the `redirect-gateway` flag which the AWS provided client was setting.
>
>Fortunately, `pull-filter` is one of the supported [OpenVPN
directives](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/connect-aws-client-vpn-connect.html#support-openvpn)
in the AWS client. By adding `pull-filter ignore "redirect-gateway"`, we instruct the client to ignore that directive
and preserve split-tunnel behavior.

### Connect to the Client VPN endpoint

How you'll connect to the VPN depends on your OS as well as your VPN client. AWS provides its own [custom OpenVPN
client](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/user-getting-started.html#install-client) that is designed
to be compatible with all features of AWS Client VPN. However, since the goal was to use this in an Ubuntu Linux GitHub
Codespace, we'll just use the bog standard OpenVPN client.

First we'll install openvpn.
```
sudo apt-get update && sudo apt-get install openvpn
```

Then we can connect using:

```
sudo openvpn --config /path/to/config/file
```
