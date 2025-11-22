+++
title = "Grant AWS Access to Kubernetes Workloads via SPIFFE/SPIRE & IAM Roles Anywhere"
slug = "grant-aws-access-to-kubernetes-workloads-via-spiffe-spire-and-iam-roles-anywhere"
description = "Learn how to authenticate Kubernetes workloads to AWS using SPIRE-issued X.509 certificates and AWS IAM Roles Anywhere"
date = "2025-06-01"
[taxonomies] 
tags = [
  "spiffe/spire",
  "identity",
  "secrets management",
  "zero trust",
  "aws",
  "iam",
  "terraform",
  "iac", 
  "kubernetes"
]

+++

## Preamble

In our [last post](https://misaac.me/blog/automated-aws-credential-renewal-spiffe-helper-roles-anywhere/), we used the [spiffe-helper](https://github.com/spiffe/spiffe-helper) along with the [IAM Roles Anywhere credential helper](https://github.com/aws/rolesanywhere-credential-helper) to connect to AWS from our local machine. This solved the manual SVID renewal and AWS credential refresh problem. Specifically, it eliminated the tedious cycle of manually requesting new X.509 certificates from SPIRE every hour, and then manually exchanging those certificates for fresh AWS temporary credentials through IAM Roles Anywhere. 

In this post, we'll build on that work, deploying both the spiffe-helper and the rolesanywhere helper to serve a Kubernetes application. Along the way, we'll learn how to deploy a SPIRE agent on a Kubernetes cluster. This approach - using the spiffe-helper - makes it possible to integrate SPIFFE with applications that need certficates but can't be easily refactored to support SPIFFE. 


## What's our goal?

Our goal is to gain access to AWS from our Kubernetes pod using a SPIRE issued X.509 certificate, also known as an [SVID](https://spiffe.io/docs/latest/spire-about/spire-concepts/#a-day-in-the-life-of-an-svid). 

We'll accomplish this in three key steps: First, we'll update our SPIRE server configuration to enable communication with our Kubernetes cluster. Next, we'll deploy a SPIRE agent on the cluster that will automatically register itself with the SPIRE server. Finally, once the agent and server are communicating, we'll launch a workload that obtains AWS credentials through the spiffe-helper and IAM Roles Anywhere helper, with both operating seamlessly in the background.

### Prerequisites

Before diving into the implementation, make sure you have the following components already configured and operational:

- Public Key Infrastructure [(PKI)](http://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#setting-up-our-public-key-infrastructure-pki) established.
- IAM Roles Anywhere [configured](http://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#setting-up-iam-roles-anywhere) to use that PKI.
- A SPIRE Server [configured](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#setting-up-the-spire-server) to use the PKI.
- A Kubernetes cluster whose API is reachable from your SPIRE server.

<br>

## Update SPIRE server config to talk to Kubernetes

### Verify kubernetes cluster reachability
First verify that we can communicate with the K8's API from our SPIRE server. An easy check is to run a curl against the `version` endpoint of your Kubernetes cluster from your SPIRE server. 

```bash
$ curl https://192.168.194.129:443/version
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}$ 
```
An ‘Unauthorized’ response is fine, at this point all we care about is network reachability as we'll be creating a token for our SPIRE server shortly. 

### Create backing Kubernetes resources for the SPIRE Server

Our SPIRE server needs several Kubernetes resources to operate effectively within the cluster environment. We'll start by creating the `spire` namespace, which provides logical separation for our SPIRE components.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: spire
```

The SPIRE server requires its own service account to authenticate with the Kubernetes API. This service account will be the identity our server uses when interacting with cluster resources.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: spire
```

To enable the SPIRE server's node attestor to function properly, we need to grant it specific permissions through a ClusterRole. This role allows the server to read pods and nodes, update configmaps, and query the Token Review API, steps that are all essential for the node attestation process.

```yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spire-server-trust-role
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get"]
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["patch", "get", "list"]
```

We then bind this cluster role to our SPIRE server service account, establishing the necessary permissions for the server to operate within the cluster.

```yaml
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spire-server-trust-role-binding
subjects:
  - kind: ServiceAccount
    name: spire-server
    namespace: spire
roleRef:
  kind: ClusterRole
  name: spire-server-trust-role
  apiGroup: rbac.authorization.k8s.io
```

Finally, we create a ConfigMap named `spire-bundle`. This ConfigMap will hold the SPIRE server's trust bundle (CA certificates). SPIRE agents need this bundle during their startup to securely bootstrap and authenticate to the SPIRE server. Since we'll be deploying our SPIRE agent to the default namespace, we will also create this ConfigMap in the default namespace for easy access by the agent. The SPIRE server's [k8sbundle notifier plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_notifier_k8sbundle.md) (which we'll configure shortly) will populate and keep this ConfigMap updated.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-bundle
  namespace: default
```
### Prepare the kubeconfig file 

With our Kubernetes resources in place, we need to prepare a kubeconfig file that our server plugins will use to authenticate with the cluster. We'll extract the current cluster configuration, stripping it down to only the essential information using the --minify flag. 

```bash
kubectl config view --minify --flatten --raw > kubeconfig.yaml
```
Check the kubeconfig file - if it has the `client-certificate-data` and `client-key-data` fields, you should be good to go. 

Now that our kubeconfig is ready, we need to make it accessible to our SPIRE server. Since my SPIRE server runs on ECS, I'll store the kubeconfig as an SSM parameter for secure retrieval.

```
resource "aws_ssm_parameter" "kubeconfig" {
  name        = "/misaac-me/kubeconfig"
  description = "Kubernetes configuration for misaac.me"
  type        = "SecureString"
  value       = file("${path.module}/kubeconfig.yaml")

  tags = {
    Environment = "production"
    Project     = "misaac.me"
  }
}
```

To retrieve this configuration at runtime, I've modified my [ECS task](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#the-spire-server-ecs-task-definition) command to include an AWS CLI call that pulls the kubeconfig and saves it to the attached volume.

```bash
aws ssm get-parameter --name "/misaac-me/kubeconfig" --with-decryption --query "Parameter.Value" --output text > /opt/spire/conf/server/kubeconfig.yaml
```

### Configure the k8s_psat server plugin

With the kubeconfig in place, we can now update the [SPIRE server configuration](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#the-spire-server-config) to include the [k8s_psat](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_k8s_psat.md) plugin. This plugin handles the server-side node attestation for Kubernetes workloads.

```
NodeAttestor "k8s_psat" {
  plugin_data {
    clusters = {
      "orbstack" = {
        service_account_allow_list = ["default:spire-agent"]
        kube_config_file = "/opt/spire/conf/server/kubeconfig.yaml"
      }
    }
  }
}
```

### Configure "k8sbundle" - the Kubernetes Notifier plugin

Notifiers are specialized plugins that receive updates from the SPIRE server and can act on those changes. We'll configure the [`k8sbundle` notifier](https://github.com/spiffe/spire/blob/main/doc/plugin_server_notifier_k8sbundle.md), which has the important responsibility of pushing the latest trust bundle contents into a Kubernetes ConfigMap whenever updates occur.

```
Notifier "k8sbundle" {
  plugin_data {
      namespace = "default"
      config_map = "spire-bundle"
      config_map_key = "bundle.crt"
      kube_config_file_path = "/opt/spire/conf/server/kubeconfig.yaml"
  }
}
```

This configuration ensures that once our SPIRE server starts up successfully, it will automatically push the certificate bundle down to our cluster, making it available for agents to use during their initialization process. Next up, our SPIRE agent. 

## Deploy SPIRE agent on Kubernetes

First, we create a service account for our spire agent in the `default` namespace.
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-agent
  namespace: default
```

Next, we create the cluster role to allow the spire agent to query the k8s API server. 

```yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spire-agent-cluster-role
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "nodes/proxy"]
    verbs: ["get"]
```

Then we bind the agent cluster role to the spire agent service account. 

```yaml
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spire-agent-cluster-role-binding
subjects:
  - kind: ServiceAccount
    name: spire-agent
    namespace: default
roleRef:
  kind: ClusterRole
  name: spire-agent-cluster-role
  apiGroup: rbac.authorization.k8s.io

```

### Configure the k8s_psat agent plugin

As mentioned earlier, SPIRE’s attestation process operates at two levels to secure Kubernetes workloads, node and workload attestation. 

**1. Node Attestation (k8s\_psat NodeAttestor):**
The SPIRE agent presents a Projected Service Account Token (PSAT) to the server, which validates it against the Kubernetes API. This confirms the agent is running on an authorized node. This is done by both `k8s_psat` plugins, server and agent, working together. 

```
plugins {
  NodeAttestor "k8s_psat" {
    plugin_data {
      # NOTE: Change this to your cluster name
      cluster = "orbstack"
    }
  }
}
```

### Configure the k8s agent plugin

**2. Workload Attestation (k8s WorkloadAttestor):**
Here, the SPIRE agent authenticates pods by querying the kubelet for pod metadata using the `MY_NODE_NAME` environment variable and the default service account token for authentication. 


```
plugins {
  WorkloadAttestor "k8s" {
    plugin_data {
      node_name_env = "MY_NODE_NAME"
    }
  }
}
```


This layered design ensures only authorized nodes and workloads receive certificates and enables fine-grained control using Kubernetes selectors in SPIRE registration entries.

Here's the full config:


```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent
  namespace: default
data:
  agent.conf: |
    agent {
      data_dir = "/run/spire"
      log_level = "DEBUG"
      server_address = "spire.misaac.me"
      server_port = "8081"
      socket_path = "/run/spire/sockets/agent.sock"
      trust_bundle_path = "/run/spire/bundle/bundle.crt"
      trust_domain = "spire.misaac.me"
    }

    plugins {
      NodeAttestor "k8s_psat" {
        plugin_data {
          # NOTE: Change this to your cluster name
          cluster = "orbstack"
        }
      }

      WorkloadAttestor "k8s" {
        plugin_data {
          node_name_env = "MY_NODE_NAME"
        }
      }

      KeyManager "memory" {
        plugin_data {
        }
      }
    }

    health_checks {
      listener_enabled = true
      bind_address = "0.0.0.0"
      bind_port = "8080"
      live_path = "/live"
      ready_path = "/ready"
    }
```

Also make sure that our server address matches the server address we [configured](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#setting-up-route53-and-the-network-load-balancer) for the spire server. 


### The SPIRE Agent DaemonSet

We can now deploy our agent DaemonSet. The SPIRE agent must run on every node where workloads require SVIDs. A DaemonSet is the ideal Kubernetes construct for this, as it ensures new nodes automatically receive a SPIRE agent to attest both the node and its workloads before issuing SVIDs. 


Here's the configuration for the DaemonSet:
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: default
  labels:
    app: spire-agent
spec:
  selector:
    matchLabels:
      app: spire-agent
  template:
    metadata:
      namespace: default
      labels:
        app: spire-agent
    spec:
      hostPID: false
      hostNetwork: false
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: spire-agent
      initContainers:
        - name: init
          # This is a small image with wait-for-it, choose whatever image
          # you prefer that waits for a service to be up. This image is built
          # from https://github.com/lqhl/wait-for-it
          image: cgr.dev/chainguard/wait-for-it
          args: ["-t", "30", "spire.misaac.me:8081"]
      containers:
        - name: spire-agent
          image: ghcr.io/spiffe/spire-agent:1.12.2
          args: ["-config", "/run/spire/config/agent.conf"]
          env:
            - name: MY_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-bundle
              mountPath: /run/spire/bundle
            - name: spire-agent-socket
              mountPath: /run/spire/sockets
              readOnly: false
            - name: spire-token
              mountPath: /var/run/secrets/tokens
          livenessProbe:
            httpGet:
              path: /live
              port: 8080
            failureThreshold: 2
            initialDelaySeconds: 15
            periodSeconds: 60
            timeoutSeconds: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: spire-config
          configMap:
            name: spire-agent
        - name: spire-bundle
          configMap:
            name: spire-bundle
        - name: spire-agent-socket
          hostPath:
            path: /run/spire/sockets
            type: DirectoryOrCreate
        - name: spire-token
          projected:
            sources:
              - serviceAccountToken:
                  path: spire-agent
                  expirationSeconds: 7200
                  audience: spire-server

```

Using hostPath can introduce security risks as it provides access to the underlying node's filesystem. As such, in production, you should use the [SPIFFE CSI Driver](https://github.com/spiffe/spiffe-csi).

After applying these manifests, check the agent logs to verify successful deployment. You should see output similar to the following:

```
... level=info msg="Bundle loaded" subsystem_name=attestor trust_domain_id="spiffe://spire.misaac.me"
... level=debug msg="No pre-existing agent SVID found. Will perform node attestation" subsystem_name=attestor
... level=info msg="SVID is not found. Starting node attestation" subsystem_name=attestor trust_domain_id="spiffe://spire.misaac.me"
... level=info msg="Node attestation was successful" reattestable=true spiffe_id="spiffe://spire.misaac.me/spire/agent/k8s_psat/orbstack/84c43c5a-6219-45b2-a5a4-c56cad474827" subsystem_name=attestor trust_domain_id="spiffe://spire.misaac.me"
... level=debug msg="Bundle added" subsystem_name=svid_store_cache trust_domain_id=spire.misaac.me
... level=debug msg="Initializing health checkers" subsystem_name=health
... level=info msg="Serving health checks" address="0.0.0.0:8080" subsystem_name=health
... level=info msg="Starting Workload and SDS APIs" address=/run/spire/sockets/agent.sock network=unix subsystem_name=endpoints
```

### Creating the registration entry

With our agent up and running, we can now create a [registration entry](https://spiffe.io/docs/latest/deploying/registering/). Since our SPIRE server is running on ECS, we can use the ECS Exec feature to run the `entry create` command. 

Registration requires knowing a parent ID and if you didn't grab it from the logs, you can always run `spire-server agent list` on the SPIRE server first to retrieve it. 

```bash
aws ecs execute-command --cluster misaac-me-cluster \
  --task EXAMPLE-TASK-ID \
  --container app \
  --interactive \
  --command "/opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://spire.misaac.me/ns/default/sa/default \
  -parentID spiffe://spire.misaac.me/spire/agent/k8s_psat/orbstack/84c43c5a-6219-45b2-a5a4-c56cad474827 \
  -selector k8s:ns:default \
  -selector k8s:sa:default"
```

Notice how we specify the `parentID`. This tells the SPIRE server which agent will be responsible for issuing SVIDs for this workload. This is important because to ensure availability, SVIDs are sent to agents once they are created. This means that when a workload comes alive and requests one, the agent can serve the workload its certificate whether or not it is currently connected to the SPIRE server . 

Here's the result of the `entry create` command above:

```bash
Starting session with SessionId: ecs-execute-command-o2xbn5vhnhp6ziaectzzsq69vq
Entry ID         : 6e87aaaf-1f66-46e8-82fb-1aeb5eec9082
SPIFFE ID        : spiffe://spire.misaac.me/ns/default/sa/default
Parent ID        : spiffe://spire.misaac.me/spire/agent/k8s_psat/orbstack/84c43c5a-6219-45b2-a5a4-c56cad474827
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : k8s:ns:default
Selector         : k8s:sa:default



Exiting session with sessionId: ecs-execute-command-o2xbn5vhnhp6ziaectzzsq69vq.
```

<br>

## Profit
We are now ready to run our workload. This deployment has 3 containers. The first is the spiffe-helper, which simply starts up and uses the config to request an SVID from the spire agent. Here's said config: 

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: default
  name: spiffe-helper-config
data:
  helper.conf: |
    agent_address = "/run/spire/sockets/agent.sock"
    cmd = ""
    cmd_args = ""
    cert_dir = "/mnt/credentials"
    renew_signal = "SIGUSR1"
    svid_file_name = "svid.0.pem"
    svid_key_file_name = "svid.0.key"
    svid_bundle_file_name = "bundle.0.pem"
    add_intermediates_to_bundle = true
```

The key line here is `add_intermediates_to_bundle`, without which you'll run into an `AccessDeniedException: Untrusted signing certificate` error when trying to authenticate. This is because IAM Roles Anywhere needs to validate the entire chain of the presented SVID up to a CA it knows (from the [Trust Anchor](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#setting-up-iam-roles-anywhere)), and this flag ensures the spiffe-helper provides that chain. 

Next comes the rolesanywhere-helper container. Once it verifies that the SVIDs have been issued, it authenticates with AWS and obtains the AWS credentials. It then spins up a local AWS metadata endpoint that our app container can use to request those credentials. You can build this rolesanywhere helper image using the following Dockerfile. 

```Dockerfile
ARG BASE_IMAGE=debian:bookworm-slim
FROM --platform=${TARGETPLATFORM:-linux/amd64} ${BASE_IMAGE}

# Optionally, you can set TARGETPLATFORM at build time:
# docker build --build-arg TARGETPLATFORM=linux/arm64 .

# Install ca-certificates and jq packages
RUN apt-get update && apt-get install -y ca-certificates jq && rm -rf /var/lib/apt/lists/*

# Copy the aws_signing_helper binary from your local machine
COPY aws_signing_helper /usr/local/bin/aws_signing_helper

RUN update-ca-certificates
RUN chmod +x /usr/local/bin/aws_signing_helper

# Set the entrypoint and default command
ENTRYPOINT ["/usr/local/bin/aws_signing_helper"]
CMD ["serve", "--certificate", "/mnt/credentials/tls.crt", "--private-key", "/mnt/credentials/tls.key", "--trust-anchor-arn", "$(TRUST_ANCHOR_ARN)", "--profile-arn", "$(PROFILE_ARN)", "--role-arn", "$(ROLE_ARN)"]
```

This image packages the AWS IAM Roles Anywhere credential helper (which we refer to as aws_signing_helper in the Dockerfile's COPY command). You'll need to download the appropriate binary for your TARGETPLATFORM from the official [GitHub Releases page](https://github.com/aws/rolesanywhere-credential-helper/releases) and place it in your Docker build context, naming it aws_signing_helper.

Finally, our `app-container` simply runs the AWS CLI to verify that it has received valid credentials. It executes `aws sts get-caller-identity`, which is the AWS equivalent of a "whoami" command, confirming the pod's authenticated identity within AWS.



```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: default
  name: client
  labels:
    app: client
spec:
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
    spec:
      hostPID: false
      hostNetwork: false
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        # Step 1: SPIFFE helper sidecar to fetch and maintain certificates
        - name: spiffe-helper
          image: ghcr.io/spiffe/spiffe-helper:nightly
          command: ["./spiffe-helper"]
          args: ["-config", "/config/helper.conf"]
          resources:
            requests:
              memory: "64Mi"
              cpu: "250m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          volumeMounts:
            - name: spire-agent-socket
              mountPath: /run/spire/sockets
              readOnly: true
            - name: credentials
              mountPath: /mnt/credentials
              readOnly: false
            - name: spiffe-helper-config
              mountPath: /config
              readOnly: true

        # Step 2: Start AWS IAM Roles Anywhere service
        - name: iamra
          image: aws-signer
          command: ["sh", "-c"]
          args:
            - |
              echo "Waiting for SPIFFE certificates to be available..."
              timeout=300  # 5 minutes timeout
              elapsed=0
              while [ $elapsed -lt $timeout ]; do
                if [ -s /mnt/credentials/svid.0.pem ] && \
                  [ -s /mnt/credentials/svid.0.key ] && \
                  [ -s /mnt/credentials/bundle.0.pem ]; then
                  echo "Certificates found and non-empty, starting AWS signing helper..."
                  break
                fi
                echo "Certificates not yet available or empty, waiting... (${elapsed}s elapsed)"
                sleep 5
                elapsed=$((elapsed + 5))
              done

              if [ $elapsed -ge $timeout ]; then
                echo "Timeout waiting for certificates after ${timeout}s"
                exit 1
              fi

              exec aws_signing_helper serve \
                --certificate /mnt/credentials/svid.0.pem \
                --private-key /mnt/credentials/svid.0.key \
                --intermediates /mnt/credentials/bundle.0.pem \
                --trust-anchor-arn $TRUST_ANCHOR_ARN \
                --profile-arn $PROFILE_ARN \
                --role-arn $ROLE_ARN
          ports:
            - containerPort: 9911
              protocol: TCP
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "grep -q ':26B7 ' /proc/net/tcp"
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          env:
            - name: TRUST_ANCHOR_ARN
              value: "arn:aws:rolesanywhere:us-east-1:123456789012:trust-anchor/12345678-1234-1234-1234-123456789012"
            - name: PROFILE_ARN
              value: "arn:aws:rolesanywhere:us-east-1:123456789012:profile/87654321-4321-4321-4321-210987654321"
            - name: ROLE_ARN
              value: "arn:aws:iam::123456789012:role/example-role"
          volumeMounts:
            - mountPath: /mnt/credentials
              name: credentials
          resources:
            requests:
              memory: "64Mi"
              cpu: "250m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          imagePullPolicy: IfNotPresent
        # Step 3: Test AWS credentials (waits for iamra to be ready)
        - name: app-container
          image: public.ecr.aws/aws-cli/aws-cli:2.15.6
          command: ["sh", "-c"]
          args:
            - |
              echo "Waiting for IAM Roles Anywhere service to be ready..."
              while ! curl -s http://127.0.0.1:9911/ > /dev/null 2>&1; do
                echo "IAM Roles Anywhere service not ready, waiting..."
                sleep 5
              done
              echo "Testing AWS credentials..."
              aws sts get-caller-identity && echo "The app is running with AWS credentials!" && sleep 3600
          imagePullPolicy: Always
          resources:
            requests:
              memory: "64Mi"
              cpu: "250m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          env:
            - name: AWS_EC2_METADATA_SERVICE_ENDPOINT
              value: "http://127.0.0.1:9911/"
      volumes:
        - name: spire-agent-socket
          hostPath:
            path: /run/spire/sockets
            type: Directory
        - name: credentials
          emptyDir: {}
        - name: spiffe-helper-config
          configMap:
            name: spiffe-helper-config

```
For the spiffe-helper sidecar, we use the official nightly image for simplicity, but for production deployments, it's strongly recommended to pin to a specific stable version tag.

If everything worked, your pod logs will look similar to: 

```bash
... app-container Waiting for IAM Roles Anywhere service to be ready...
... app-container IAM Roles Anywhere service not ready, waiting...
... app-container Testing AWS credentials...
... iamra Waiting for SPIFFE certificates to be available...
... iamra Certificates not yet available or empty, waiting... (0s elapsed)
... iamra Certificates found and valid, starting AWS signing helper...
... iamra 2025/06/01 21:27:22 Local server started on port: 9911
... iamra 2025/06/01 21:27:22 Make it available to the sdk by running:
... iamra 2025/06/01 21:27:22 export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911/
... spiffe-helper time="2025-06-01T21:27:16Z" level=info msg="Using configuration file: \"/config/helper.conf\"" system=spiffe-helper
... spiffe-helper time="2025-06-01T21:27:16Z" level=info msg="Launching daemon" system=spiffe-helper
... spiffe-helper time="2025-06-01T21:27:16Z" level=info msg="Watching for X509 Context" system=spiffe-helper
... spiffe-helper time="2025-06-01T21:27:18Z" level=info msg="Received update" spiffe_id="spiffe://spire.misaac.me/ns/default/sa/default" system=spiffe-helper
... spiffe-helper time="2025-06-01T21:27:18Z" level=info msg="X.509 certificates updated" system=spiffe-helper
... app-container {
... app-container     "UserId": "AROADBQP57FF2AEXAMPLE:30a7fe7d714958787f6075c9904ce642",
... app-container     "Account": "123456789012",
... app-container     "Arn": "arn:aws:sts::123456789012:assumed-role/example-role/30a7fe7d714958787f6075c9904ce642"
... app-container }
... app-container The app is running with AWS credentials!
```


<br>

## Wrapping Up

In this post, we've successfully extended our previous work to securely grant AWS access to applications running within a Kubernetes cluster. Although our example used the spiffe-helper in service of AWS credentials, the pattern is applicable to any scenario where workloads require certificates. The foundation we've built can also be [extended](https://github.com/spiffe/spire/wiki/SPIRE-Use-Cases) in several directions based on your organization's needs. 

For microservice architectures, you could [integrate SPIRE with service meshes like Istio](https://engineering.indeedblog.com/blog/2024/07/workload-identity-with-spire-oidc-for-k8s-istio/) to enable automatic mTLS communication between services. For applications requiring JWT-based authentication, the [SPIRE OIDC Discovery Provider](https://github.com/spiffe/spire/blob/main/support/oidc-discovery-provider/README.md) and [JWT-SVIDs](https://github.com/spiffe/spiffe/blob/main/standards/JWT-SVID.md) provide a path forward.

As your infrastructure grows, SPIRE's flexible architecture supports multi-cluster and multi-cloud deployments through various [deployment topologies](https://spiffe.io/docs/latest/planning/scaling_spire/#choosing-a-spire-deployment-topology), allowing you to maintain a consistent identity fabric across diverse environments.

By [treating identity as the fundamental primitive](https://misaac.me/blog/spiffe-spire-secret-sprawl-fix/) we've architected ourselves a unified identity system spanning all our workloads, from developer machines to production services.