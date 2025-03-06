+++
title = 'Using SSH tunneling to connect to private OKE kubernetes clusters'
slug= "ssh-tunneling-oke-kubernetes"
description = "How to connect to your private Kubernetes Clusters on Oracle Cloud OKE"
date = "2025-03-02"
[taxonomies] 
tags = ["k8s", "kubernetes", "ssh", "OKE","IaC","terraform"]
+++

### Preamble
This post is about using an OCI instance as a jump box to access your private kubernetes running on Oracle cloud. As such, I assume you already have a private OKE cluster you need to interact with. If you don't have one, see the prerequisites section below for a ready-to-go terraform repo which we will be adding on to.

> **Note:** 
> You can also do this with the OCI bastion service, Oracle cloud's fully managed service providing ephemeral SSH access to private resources in OCI. [Here](https://www.ateam-oracle.com/post/using-oci-bastion-service-to-manage-private-oke-kubernetes-clusters) is an Oracle blog post explaining how, and [here](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupbastion.htm) is the full documentation for that approach. If you're curious about the differences between the two, this [article](https://www.ateam-oracle.com/post/simplify-secure-access-to-oracle-workloads-using-bastions) has an excellent breakdown. 


### Prerequisites

- OKE [Private Cluster](https://github.com/oracle-devrel/terraform-oci-arch-oke/tree/main/examples/oke-public-lb-private-api-endpoint-and-workers-no-existing-network) with Private Kubernetes API Endpoint, Private Worker Nodes, and Public Load Balancers. Read [this](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfigexample.htm#example-flannel-cni-privatek8sapi_privateworkers_publiclb) for an explainer

- OKE Cluster compartment id

- OKE CLI [installed](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#InstallingCLI) and [configured](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#configfile)

- An SSH key. You'll need the public key to setup the instance, and the private key to connect to the bastion. If you need a primer on how to generate an SSH key, [Generate an SSH Key Pair](https://docs.oracle.com/en/cloud/cloud-at-customer/occ-get-started/generate-ssh-key-pair.html) or [Generate SSH keys](https://docs.oracle.com/en/learn/generate_ssh_keys/index.html#introduction) should help.

- Kubectl [installed](https://kubernetes.io/docs/tasks/tools/#kubectl)

### Adding a bastion subnet 

Since we've decided to do things the old school way, we need a public subnet to place our bastion jump box. A public subnet is a subnet that has a route to an internet gateway in its route table. This allows resources within the subnet to send and receive traffic from the internet. We'll be connecting to our bastion using SSH so we'll need rules that allow ingress SSH traffic (port 22) from trusted IPs. Let's add the terraform required. 

First, our security list:

```terraform
resource "oci_core_security_list" "bastion" {
  compartment_id = var.compartment_ocid
  display_name   = "bastion_subnet_sec_list"
  vcn_id         = oci_core_vcn.oke_vcn[0].id
  defined_tags   = var.defined_tags

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0" # You can make this more restrictive depending on your security posture
  }

  /* This entry is used for DNS resolving (open UDP traffic). */
  ingress_security_rules {
    protocol = "17"
    source   = var.vcn_cidrs
  }

  ingress_security_rules {
    stateless   = false
    source      = "203.0.113.0/24" # replace with your own ip - you also probably want a /32
    source_type = "CIDR_BLOCK"
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # Get protocol numbers from https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
    
}
```

Next, we'll add the subnet. The subnets created by the terraform [used](https://github.com/oracle-devrel/terraform-oci-arch-oke/blob/main/variables.tf#L36-L55) `10.0.1.0/24`, `10.0.2.0/24` and `10.0.3.0/24` so we can take `10.0.4.0/24` for our bastion.


```terraform
variable "bastion_subnet_cidr" {
  default = "10.0.4.0/24"
}


resource "oci_core_subnet" "bastion" {
  cidr_block     = var.bastion_subnet_cidr
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.oke_vcn[0].id
  display_name   = "bastion_subnet"

  security_list_ids = [oci_core_vcn.oke_vcn[0].default_security_list_id, oci_core_security_list.bastion.id]
  route_table_id    = oci_core_route_table.oke_rt_via_igw[0].id
}
```

### Adding a bastion instance

With the subnet in place, we can launch our jump box. You'll likely need to change the source id based on your region. See [here](https://docs.oracle.com/en-us/iaas/images/ubuntu-2204/) for a list of Ubuntu instances and their corresponding ocids. This is also where we'll use the SSH public key you either already have, or created following the guides in the prerequisites. To add it to the instance, pass its location to `ssh_authorized_keys`. We also add an output that will give us the public ip which we'll use to connect via SSH.

Here's the terraform:

```terraform
resource "oci_core_instance" "ubuntu_bastion_instance" {
  # Required
  availability_domain = data.oci_identity_availability_domains.ADs.availability_domains[0].name
  compartment_id      = var.compartment_id
  shape               = "VM.Standard.A1.Flex"
  source_details {
    source_id   = "ocid1.image.oc1.us-chicago-1.aaaaaaaa64e73jfbns5ivnphb2oqyfqvuumbghlfouvudebolh4yev6gckdq" 
    source_type = "image"
  }

  # Optional
  display_name = "bastion"
  create_vnic_details {
    assign_public_ip = true
    subnet_id        = oci_core_subnet.bastion.id
  }
  metadata = {
    ssh_authorized_keys = file(var.bastion_public_key_path)
  }
  preserve_boot_volume = false

  shape_config {
    ocpus         = 1
    memory_in_gbs = 1
  }
}


# Outputs for compute instance

output "public-ip-for-compute-instance" {
  value = oci_core_instance.ubuntu_bastion_instance.public_ip
}

```

### Connecting to the jump box via ssh

Before we try to connect to our OKE cluster, we need to verify that basic SSH works. Here are the steps:

1. Make sure that your private key is in your ssh directory, usually 

    ```
    ~/.ssh
    ```

1. Refresh or start your ssh agent with 
    ```
    eval "$(ssh-agent -s)"
    ```

1. Add your private key to your local ssh agent. Enter your passphrase if/when asked
    ```
    ssh-add ~/.ssh/private-key-file-name
    ```

1. SSH in, replacing this IP with the IP from the terraform output. Accept the remote fingerprint and voila! 
    ```
    ssh ubuntu@203.0.113.255
    ```


### Connecting to the OKE cluster

Now that we've established that we can ssh to our bastion host, all we need to hit the Kubernetes API is to create our kubeconfig, edit the kubeconfig file to change the server IP address to point to our localhost, and then start a port fowarding session via our bastion. To begin:

1. Use the oci cli to create your kubeconfig, replacing `cluster-id` and `region` with your details

    ```
    oci ce cluster create-kubeconfig --cluster-id ocid1.cluster.oc1.phx.aaaaaaaaae... --file $HOME/.kube/config  --region us-chicago-1 --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT
    ```

1. Change the server ip with this regex

    ```
    sed -i.bak 's|server: https://[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}:6443|server: https://127.0.0.1:6443|' ~/.kube/config
    ```

1. Grab your cluster API endpoint
    ```
    CLUSTER_API=$(oci ce cluster list --compartment-id ocid1.compartment.oc1..aaaaaaaah...a | jq --raw-output '.data[0].endpoints["private-endpoint"]')
    ```
1. Launch the port forwarding session. Note that this terminal window must stay open.  
    ```
    ssh -L 6443:$CLUSTER_API ubuntu@203.0.113.255
    ```

1. Get the kubernetes context name with 
    ```
    kubectl config get-contexts -o name
    ```

1. Set the current kubernetes context with 
    ```
    kubectl config use-context context-name-of-your-context
    ```

1. Connect to the cluster
    ```
    kubectl cluster-info
    ```
