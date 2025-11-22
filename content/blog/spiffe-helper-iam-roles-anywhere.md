+++
title = "Automated AWS Credential Renewal Using SPIFFE Helper and IAM Roles Anywhere"
slug = "automated-aws-credential-renewal-spiffe-helper-roles-anywhere"
description = "Learn how to combine SPIFFE Helper's SVID management with IAM Roles Anywhere's credential helper to achieve automated AWS credential renewal"
date = "2025-05-24"
[taxonomies] 
tags = [
  "spiffe/spire",
  "identity",
  "secrets management",
  "zero trust",
  "aws",
  "iam",
]
+++

In [Grant AWS Access to GitHub Codespaces via SPIFFE/SPIRE & IAM Roles Anywhere](http://127.0.0.1:1111/blog/grant-aws-access-to-codespaces-via-spiffe-spire-iam-roles-anywhere/#use-a-spiffe-svid-to-obtain-aws-credentials-via-iam-roles-anywhere), we demonstrated how to authenticate to AWS using SPIRE-issued X.509 certificates and IAM Roles Anywhere. 

While it works, this approach requires manual intervention: you need to repeatedly request new SVIDs when they expire after an hour, as well as manually call the Roles Anywhere credential helper each time to obtain AWS credentials. But what if we could automate this entire process?

Enter [spiffe-helper](https://github.com/spiffe/spiffe-helper). It takes care of fetching X.509 SVID certificates from the SPIFFE agent, launching a process to use them, and automatically renewing and reloading certificates as needed. Let's combine these two to good use. 

We'll use the `serve` command of the rolesanywhere credential helper which vends temporary security credentials from IAM Roles Anywhere through a local endpoint. We'll invoke this via spiffe-helper and if all goes to plan, never need to lift a finger. 

### Set up the aws rolesanywhere credential helper
You can download the roles anywhere credential helper from the AWS docs page [here](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html) but if you encounter issues running the executable like I did, you could also just build from source. 

1. Clone the repo

    ```bash
    git clone https://github.com/aws/rolesanywhere-credential-helper.git
    cd rolesanywhere-credential-helper 
    ```

2. Follow the instructions in the [readme](https://github.com/aws/rolesanywhere-credential-helper/tree/main?tab=readme-ov-file#dependencies) to download the build dependencies for your OS. Basically, you need `git`, `gcc`, `GNU make`, and `golang`.

3. Build the executable 

    ```bash
    make release
    ```

3. Copy the executable and test it by running the help menu

    ```bash
    cp build/bin/aws_signing_helper ~/aws_signing_helper && ./aws_signing_helper -h
    ```

    You should see :

    ```
    $ ~/aws_signing_helper -h
    A tool that utilizes certificates and their associated private keys to 
    sign requests to AWS IAM Roles Anywhere's CreateSession API and retrieve temporary 
    AWS security credentials. This tool exposes multiple commands to make credential 
    retrieval and rotation more convenient.

    Usage:
    aws_signing_helper [command] [flags]
    aws_signing_helper [command]

    Available Commands:
    completion            Generate the autocompletion script for the specified shell
    credential-process    Retrieve AWS credentials in the appropriate format for external credential processes
    help                  Help about any command
    read-certificate-data Diagnostic command to read certificate data
    serve                 Serve AWS credentials through a local endpoint
    sign-string           Signs a fixed string using the passed-in private key (or reference to private key)
    update                Updates a profile in the AWS credentials file with new AWS credentials
    version               Prints the version number of the credential helper

    Flags:
    -h, --help   help for aws_signing_helper

    Use "aws_signing_helper [command] --help" for more information about a command.
    ```
<br>

### Set up spiffe-helper

If you're on a linux machine, you're in luck - you can just grab the binaries from the [releases page](https://github.com/spiffe/spiffe-helper/releases) and move on to the next section. The rest of us have to build it ourselves, but since its a `go` project, this is pretty straightforward. 

1. Clone the repo

    ```bash
    git clone https://github.com/spiffe/spiffe-helper.git
    cd spiffe-helper
    ```

2. Build the executable
    ```bash
    go build -o spiffe-helper cmd/spiffe-helper/main.go
    ```

3. Test the executable by running the help menu

    ```bash
    ./spiffe-helper -h
    ```

    You should see :

    ```
    $ ./spiffe-helper -h
    Usage of ./spiffe-helper:
    -config string
            <configFile> Configuration file path (default "helper.conf")
    -daemon-mode
            Toggle running as a daemon 
    ```

4. Configure SPIFFE Helper
   
    The repository includes a `helper.conf` configuration file that needs customization. Make these essential changes:

    - Set the command to be executed (`cmd`)
    - Specify the command arguments (`cmd_args`)
    - Enable `add_intermediates_to_bundle` by setting it to `true`

    The last setting is particularly important - it ensures the SPIRE intermediate CA certificate is included in the bundle file after the Root CA certificate. Without this, you'll encounter an `AccessDeniedException: Untrusted signing certificate` error when trying to authenticate.

    ```conf
    agent_address = "/tmp/spire-agent/public/api.sock"
    cmd = "~/aws_signing_helper"
    cmd_args = "serve --certificate /tmp/svid.0.pem --private-key /tmp/svid.0.key --intermediates /tmp/bundle.0.pem --trust-anchor-arn arn:aws:rolesanywhere:us-east-1:012345678901:trust-anchor/9f455be1-f25f-495b-9e99-f6a630d62cbb --profile-arn arn:aws:rolesanywhere:us-east-1:012345678901:profile/737869f1-ffd0-4674-ac2b-f3d6895b4499 --role-arn arn:aws:iam::012345678901:role/test"
    cert_dir = "/tmp"
    renew_signal = "SIGUSR1"
    svid_file_name = "svid.0.pem"
    svid_key_file_name = "svid.0.key"
    svid_bundle_file_name = "bundle.0.pem"
    # Add CA with intermediates into Bundle file instead of SVID file,
    # it is the expected behavior in some scenarios like MySQL.
    # Default: false
    add_intermediates_to_bundle = true
    ```

5. Run the helper
    ```bash
    ./spiffe-helper -config helper.conf
    ```

    You should see the following:

    ```
    $ ./spiffe-helper -config helper.conf
    INFO[0000] Using configuration file: "helper.conf"       system=spiffe-helper
    INFO[0000] Launching daemon                              system=spiffe-helper
    INFO[0000] Watching for X509 Context                     system=spiffe-helper
    INFO[0000] Received update                               spiffe_id="spiffe://misaac.me/myservice" system=spiffe-helper
    INFO[0000] X.509 certificates updated                    system=spiffe-helper
    2025/05/24 09:19:18 Local server started on port: 9911
    2025/05/24 09:19:18 Make it available to the sdk by running:
    2025/05/24 09:19:18 export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911/
    ```

<br>

### Profit
The final steps are simple. Open a terminal and set the `AWS_EC2_METADATA_SERVICE_ENDPOINT` environment variable to point to your local endpoint:
```bash
export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911
```

Then delete any existing credentials:

```bash
 rm -rf ~/.aws/cli/cache/*    
 rm -rf ~/.aws/sso/cache/*             
 mv ~/.aws/config aws-config-backup

```

Now, simply run your application or any AWS CLI command as usual. The AWS SDKs and CLI will automatically detect the `AWS_EC2_METADATA_SERVICE_ENDPOINT` environment variable and fetch credentials from the local endpoint provided by the credential helper. No changes to your application code are required as credential renewal and retrieval are handled transparently in the background.

Let's run `whoami`. 

```
$ aws sts get-caller-identity
{
    "UserId": "AROADBQP57FF2AEXAMPLE:30a7fe7d714958787f6075c9904ce642",
    "Account": "012345678901",
    "Arn": "arn:aws:sts::012345678901:assumed-role/test/30a7fe7d714958787f6075c9904ce642"
}

```
<br>

## Wrapping Up

By integrating the SPIFFE Helper with IAM Roles Anywhere’s credential helper, we’ve removed the need for manual SVID renewals and AWS credential refreshes. This approach is especially useful for legacy applications that need certificates but can't natively support SPIFFE authentication. 

A natural next step is deploying this setup on Kubernetes with the spiffe-helper and the rolesanywhere helper running as sidecars alongside another application. In a future post, we’ll walk through exactly that.