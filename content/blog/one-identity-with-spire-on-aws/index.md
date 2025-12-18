+++
title = "The Secret Problem Isn’t Secrets – It's Identity"
slug= "spiffe-spire-secret-sprawl-fix"
description = "Use spiffe/spire as the one source of truth for identity across your cloud, clusters, laptops, and runtime services"
date = "2025-05-07"
[taxonomies] 
tags = [
  "spiffe-spire",
  "identity",
  "secrets management",
  "zero trust",
  "aws"
]

+++

### Preamble

Most organizations suffer from secret sprawl. There are IAM credentials for cloud workloads, SSH keys for devs, .env files passed around in Slack, or API keys hardcoded into CI jobs. If you've lived this, you know that revoking these credentials is a nightmare, auditing is incomplete, and breaches become treasure hunts for whatever got copied where.

### How SPIFFE Solves Secret Sprawl

SPIFFE gives every workload its own digital passport: a short-lived X.509 certificate called an [SVID](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#spiffe-verifiable-identity-document-svid). This certificate identifies the workload with a [SPIFFE ID](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#spiffe-id) (e.g. `spiffe://example.org/web/frontend`). The certificate expires quickly, lets the service prove who it is without dragging around long-lived secrets, and is rotated frequently so it's hard to steal or misuse.

Inside your infra, you can often drop secrets entirely. Services use mutual TLS to prove who they are, and authorization logic decides what they can do. When secrets are still needed, for example for third-party APIs, your workloads use the SVID to authenticate to your secrets manager and obtain the credentials its authorized to access. SPIFFE thus solves the secret zero problem because you don't have to worry about how to securely store the credential used by the workload to access your secret manager. 
### How It Works

A SPIFFE-enabled system fetches secrets securely on demand. The flow looks something like this:

![Image showing how SPIFFE/SPIRE works - Different workload types obtain a certificate from the Spire Server via the Spire Agent which performs attestation](diagram.svg)

1. **[Attestation](https://spiffe.io/docs/latest/spire-about/spire-concepts/#attestation):**
   The SPIRE Agent running on the same node as the workload requiring a secret first attests to the SPIRE Server through Node Attestation. This step of proving the machine it's running on is trusted is done using cloud identity documents such as AWS instance identity. After the SPIRE Server attests the node with out-of-band checks, the SPIRE Agent also performs Workload Attestation, verifying the identity of the workload using markers like Kubernetes metadata or process runtime attributes.

2. **[SVID Issuance](https://spiffe.io/docs/latest/spire-about/spire-concepts/#a-day-in-the-life-of-an-svid):**
   If both attestations check out, the SPIRE Server issues a short-lived X.509-SVID bound to a SPIFFE ID representing the workload and sends it to the SPIRE Agent. The SPIRE Agent then delivers the certificate to the workload.

3. **[Secret Fetching](https://spiffe.io/docs/latest/keyless/vault/readme/):**
   The workload uses its SVID to authenticate to a secrets manager, fetching the secrets it needs without ever storing credentials locally.

### Identity Comes First. Secrets Come Second.

SPIFFE/SPIRE doesn’t magically eliminate secrets. However, it requires us to change how we think about access. Instead of relying on possession of a token or API key, workloads now have to prove their identity. That verified identity becomes the basis for gated, auditable access. SPIFFE handles the identity while your app logic or [policy engine](https://spiffe.io/docs/latest/microservices/envoy-opa/readme/) decides what that identity is authorized to do.

Does this fix everything? Of course not. You'll likely need to use a [sidecar](https://github.com/spiffe/spiffe-helper) for your legacy apps, or build an [auth library](https://www.uber.com/blog/our-journey-adopting-spiffe-spire/) that abstracts the complexity of SVID retrieval and usage so your devs can focus on business logic. And if your team is still uploading .env files to Slack, you'll need to perform a culture overhaul on your way to secrets nirvana. 

And yes, all the SPIRE components represent another piece of infra to manage. You’ll have to think about SPIRE agent health, the SPIRE server DB/read replica health, and all the usual operational stuff. In return however, you'll gain observability, revocation, and a verifiable audit trail. 

### What this series covers

I’ll walk through setting up SPIRE on AWS and using it as the single source of identity for everything from dev machines to EKS workloads.

We won’t cover HA deployments, multi-region SPIRE, or plugging into enterprise PKI. But we’ll go over the basics and you can swap out the toy pieces for enterprise-grade alternatives that meet your security posture.

If you’ve ever wished for one source of truth for identity across your cloud, clusters, laptops, and runtime services you're in the right spot!

---

**Part 1:** [Grant AWS Access to GitHub Codespaces via SPIFFE/SPIRE & IAM Roles Anywhere](https://misaac.me/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/)

**Part 2:** [Connecting GitHub Codespaces to AWS VPN via SPIFFE/SPIRE & IAM Roles Anywhere](https://misaac.me/blog/connecting-github-codespaces-to-aws-vpn-via-spiffe-spire-and-iam-roles-anywhere/)

**Part 3:** [Automated AWS Credential Renewal Using SPIFFE Helper and IAM Roles Anywhere](https://misaac.me/blog/automated-aws-credential-renewal-spiffe-helper-roles-anywhere/)

**Part 4:** [Grant AWS Access to Kubernetes Workloads via SPIFFE/SPIRE & IAM Roles Anywhere](https://misaac.me/blog/grant-aws-access-to-kubernetes-workloads-via-spiffe-spire-and-iam-roles-anywhere/)
