+++
title = "Secure GitHub or any MCP Server with Okta via AgentCore Gateway"
slug = "secure-mcp-servers-okta-agentcore-gateway"
description = "Use Okta, OAuth, and Amazon Bedrock AgentCore Gateway to centralize MCP access, authenticate users, and connect to downstream services like GitHub without relying on shared service-account access."
date = "2026-05-31"
draft = false
[taxonomies] 
tags = ["aws", "okta", "identity", "authentication", "oauth", "oidc", "agentcore", "iam", "zero-trust", "mcp", "ai", "security"]
[extra]
mermaid = true 
+++

I've spent much of this year thinking about how to help teams adopt AI. MCPs have become a big part of that journey because all of a sudden, it seems like every company, even those who previously refused to expose an API, now has an MCP. 

While this is great for end users, you need a strategy for protecting the various MCPs in use. One way to achieve this is to deploy a [centralized gateway](https://builder.aws.com/content/3CSDSWZNYyNtDxLbaV5YUgMnXb0/long-live-mcp-the-dev-summit-recap#:~:text=Gateways%20and%20registries%20became%20the%20architectural%20consensus) where you can apply governance controls.  As a bonus, your developers get to add just one MCP server config, and all tools from target MCPs, GitHub, Jira, Linear, Notion, you name it, will be accessible via the unified MCP.

[Amazon Bedrock AgentCore Gateway](https://aws.amazon.com/blogs/machine-learning/transform-your-mcp-architecture-unite-mcp-servers-through-agentcore-gateway/) can help you do this. It sits in front of your MCP servers and presents MCP clients with a single endpoint where security teams can enforce [organizational policy](#where-to-go-from-here). Here's what that might look like:

{{ youtube(id="pCuqpFUS1sw") }}

If that looks like your end goal, lets start with some theory first!

## Client ID Metadata Documents - CIMD
Before [CIMD](https://client.dev/), the original auth story for MCP revolved around Dynamic Client Registration. The idea was that you could let MCP clients like Claude Code or VS Code automatically register themselves with the authorization server that protects an MCP server. This was always a non-starter for most enterprises because it flew in the face of security to just let random clients register themselves with your authorization server. 

Enter CIMD. CIMD's core innovation is to let OAuth clients identify themselves using a URL. A client like VS Code or Claude Code hosts a JSON metadata document at a well-known URL and that URL **doubles as** the client ID. Here's VS Code's: 

```json
{
  "client_name": "Visual Studio Code",
  "logo_uri": "https://code.visualstudio.com/assets/branding/code-stable.png",
  "grant_types": [
    "authorization_code",
    "refresh_token",
    "urn:ietf:params:oauth:grant-type:device_code"
  ],
  "response_types": [
    "code"
  ],
  "token_endpoint_auth_method": "none",
  "application_type": "native",
  "client_id": "https://vscode.dev/oauth/client-metadata.json",
  "client_uri": "https://vscode.dev/product",
  "redirect_uris": [
    "http://127.0.0.1:33418/",
    "https://vscode.dev/redirect"
  ]
}
```

<a id="mcp-server-setup"></a>In your IDE or coding agent, you'd set up the MCP server as below. Note that setting `MCP-Protocol-Version` to `2025-11-25` is required, as that's the MCP spec version that introduced CIMD.

```json
{
"servers": {
  "example": {
    "url": "https://example-mcp-server.com/mcp",
    "type": "http",
    "oauth": {
      "clientId": "https://vscode.dev/oauth/client-metadata.json"
    },
    "headers": {
      "MCP-Protocol-Version": "2025-11-25"
    }
  }
},
"inputs": []
}
```
When your IDE or coding agent attempts to authenticate with the MCP, the MCP's  authorization server fetches the client's metadata document using the url-shaped client id, and validates that the `client_id` in the metadata document matches the presented URL. There are a bunch of other [recommended validation steps](https://client.dev/servers), but once completed, the authorization server can then use the values in the metadata document in its authorization decisions. 

Unfortunately, as of May 2026, Okta authorization servers do not support CIMD. 

## The OAuth proxy

To workaround this, we'll need a proxy. Instead of registering the CIMD clients in Okta, we create an Okta [native](https://developer.okta.com/docs/guides/configure-native-sso/main/) client. Our proxy maps any allowlisted CIMD MCP clients onto this client and performs the Okta authorization flow. For this to work with the gateway, we'll register the Okta native app client ID — not the CIMD URL — in AgentCore Gateway's `allowedClients` field.


Our proxy does more than just substitute the Okta client. It performs the recommended CIMD validation steps hinted at earlier. For instance, it verifies that the requested `redirect_uri` is well-formed and matches an entry in the metadata document's `redirect_uris` list. 

### Session binding

When a user calls a GitHub tool, the call flows through our proxy to AgentCore Gateway. If a valid token already exists for this user, the gateway uses it immediately. If not, [AgentCore Identity](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity.html) returns an authorization URL and a session URI, and AgentCore Gateway surfaces them as a `-32042` URL [elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation). The proxy intercepts it, extracting the session URI and storing it in DynamoDB alongside the initiating user’s Okta subject. Then it forwards the elicitation to the MCP client. It does all this to support [session binding](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/oauth2-authorization-url-session-binding.html).

Session binding ensures that the user who initiated the tool call that needs authorization is the same user who granted consent. Without it, if the initiating user forwards the authorization URL and someone else completes the GitHub consent flow, their GitHub access token would get stored in the [token vault](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/key-features-and-benefits.html#secure-credential-storage) under the initiating user’s identity.

To prevent this, AWS provides us with a regular OAuth callback URL which we register with GitHub so GitHub can deliver the authorization code to AgentCore Identity. After AgentCore Identity receives that code, it doesn't immediately use it to obtain an access token. Instead, it redirects the user’s browser to a callback URL, `/sessionbinding/callback`, served by our proxy.

Here the proxy looks up the stored session binding and immediately redirects to Okta with `prompt=none`. Okta uses the existing browser session to issue an authorization code without showing a login prompt, then redirects to `/sessionbinding/okta-callback` on our proxy.

At `/sessionbinding/okta-callback`, the proxy exchanges that code for an ID token, extracts the `sub` claim, and compares it against the stored initiating user’s subject. Only if they match does it call [`CompleteResourceTokenAuth`](https://docs.aws.amazon.com/bedrock-agentcore/latest/APIReference/API_CompleteResourceTokenAuth.html) which signals to AgentCore that its safe to get an access token for the user, i.e ***bind the session*** . Once the binding succeeds, AgentCore Identity caches the GitHub access token for that user in the token vault, and subsequent tool calls complete normally.


{% mermaid_zoomable() %}
sequenceDiagram
    actor U as MCP Client
    participant P as Proxy
    participant O as Okta
    participant G as AgentCore Gateway
    participant I as AgentCore Identity
    participant GH as GitHub

    Note over U,GH: 1. Inbound auth — MCP client authenticates via proxy
    U->>P: /authorize (CIMD client_id, redirect_uri, PKCE)
    P->>P: Check CIMD URL against allowlist, fetch metadata doc, validate redirect_uri
    Note right of P: Swap CIMD URL to OKTA_CLIENT_ID<br/>Sign state blob with HMAC-SHA256
    P-->>U: 302 to Okta /v1/authorize
    U->>O: Authenticate
    O-->>U: 302 to /callback?code=...
    U->>P: GET /callback — verify HMAC, re-validate CIMD
    P-->>U: 302 to original redirect_uri?code=...
    U->>P: POST /token (CIMD client_id + PKCE verifier)
    P->>O: POST /v1/token (OKTA_CLIENT_ID substituted)
    O-->>P: Okta access token
    P-->>U: Okta access token

    Note over U,GH: 2. First tool call — triggers GitHub OAuth flow
    U->>P: tools/call with Bearer Okta JWT
    P->>G: Forward request
    G->>I: GetWorkloadAccessTokenForJWT (workload identity + JWT)
    I-->>G: Workload access token
    G->>I: GetResourceOauth2Token
    I-->>G: No cached token — GitHub auth URL + session URI
    G-->>P: -32042 elicitation
    Note right of P: Extract session_uri from request_uri param<br/>Store session_uri, uid claim, user_token in DynamoDB
    P-->>U: -32042 with GitHub consent URL + session URI
    U->>GH: Open consent URL, authorize GitHub access
    GH-->>I: Auth code to AgentCore Identity callback URL
    I-->>U: 302 to /sessionbinding/callback?session_id=SESSION_URI

    Note over U,GH: 3. Session binding — confirm initiating user == consenting user
    U->>P: GET /sessionbinding/callback
    P->>P: Look up session_uri in DynamoDB
    Note right of P: Build Okta auth URL with prompt=none + PKCE<br/>Store PKCE state in DynamoDB
    P-->>U: 302 to Okta /v1/authorize with prompt=none
    U->>O: Silent auth (reuse existing browser session)
    O-->>U: 302 to /sessionbinding/okta-callback?code=...
    U->>P: GET /sessionbinding/okta-callback
    P->>P: Atomic DDB delete of PKCE state
    P->>O: POST /v1/token
    O-->>P: ID token
    P->>P: Verify ID token sub matches stored initiating user sub
    P->>I: CompleteResourceTokenAuth (userToken + sessionUri)
    I->>I: Cache GitHub token in Token Vault (workload/user pair)
    P-->>U: Authorization complete

    Note over U,GH: 4. Subsequent tool calls — cached token path
    U->>P: tools/call with Bearer Okta JWT
    P->>G: Forward request
    G->>I: GetWorkloadAccessTokenForJWT
    I-->>G: Workload access token
    G->>I: GetResourceOauth2Token — cached GitHub token
    I-->>G: GitHub OAuth token
    G->>GH: Invoke tool
    GH-->>G: Tool result
    G-->>P: Tool result
    P-->>U: Tool result
{% end %}

### The proxy contract
Since the proxy handles [PKCE](https://developer.okta.com/blog/2019/08/22/okta-authjs-pkce#use-pkce-to-make-your-apps-more-secure), [CSRF defense](https://www.okta.com/identity-101/csrf-attack/), [token exchange](https://developer.okta.com/docs/concepts/token-lifecycles/), and [identity verification](https://developer.okta.com/docs/guides/validate-id-tokens/main/), it is critical that you understand what each line of code does and why. So instead of providing a full copy-paste proxy implementation, the sequence diagram above coupled with the table below outlines what each endpoint must do. I've included links to documentation and reference implementations for specific parts to help you build your own.

| Endpoint | Purpose |
|---|---|
| `/.well-known/oauth-protected-resource` | [Tells](https://datatracker.ietf.org/doc/html/rfc9728) MCP clients that the proxy [is the authorization server](https://github.com/modelcontextprotocol/python-sdk/blob/v1.27.2/src/mcp/server/auth/routes.py#L209-L253) for our gateway. |
| `/.well-known/oauth-authorization-server` | [Publishes](https://datatracker.ietf.org/doc/html/rfc8414) the proxy's authorization server capabilities, [the authorize and token endpoints](https://github.com/modelcontextprotocol/python-sdk/blob/v1.27.2/src/mcp/server/auth/routes.py#L69-L149), so MCP clients know how to authenticate. |
| `/authorize` | [Validates](https://github.com/PrefectHQ/fastmcp/blob/1a06130fcfaece1d494bf444c1561e752d94c61a/fastmcp_slim/fastmcp/server/auth/cimd.py#L1) the presented `client_id` and `redirect_uri` against the metadata document, then [redirects to Okta substituting](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/mcp_proxy_lambda.py#L88-L120) the Okta client ID. |
| `/callback` | [Receives](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/mcp_proxy_lambda.py#L123-L160) Okta's authorization code, verifies the state HMAC and re-validates the CIMD `redirect_uri`, then forwards the code to the MCP client's original redirect URI. |
| `/token` | [Proxies](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/mcp_proxy_lambda.py#L163-L194) token requests to Okta after validating CIMD client identity, substituting the Okta client ID, and rewriting `redirect_uri` to match what `/authorize` used. |
| `/sessionbinding/callback` | [Receives](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/callback_lambda.py) AgentCore Identity's 3LO return redirect, looks up the session binding, then redirects to Okta with `prompt=none` to silently identify the current browser user. |
| `/sessionbinding/okta-callback` | [Exchanges](https://developer.okta.com/docs/guides/implement-grant-type/authcodepkce/main/#exchange-the-code-for-tokens) the code for an ID token, compares the current user against the stored initiating user, and calls [`CompleteResourceTokenAuth`](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/callback_lambda.py#L56) if they match. |
| `/{full_path:path}` | [Proxies](https://github.com/awslabs/agentcore-samples/blob/main/06-workshops/02-AgentCore-gateway/04-integration/03-ide-gateway-tool/lambda/mcp_proxy_lambda.py#L211-L284) MCP traffic to AgentCore Gateway. On a `-32042` response, extracts the `session_uri` from the elicitation URL and stores the initiating user's identity in DynamoDB so `/sessionbinding/okta-callback` can complete the binding. |
| `/register` | Rejects [Dynamic Client Registration](https://datatracker.ietf.org/doc/html/rfc7591) requests with a 400 since only CIMD clients are trusted. |

Once you've coded your proxy and have it deployed, hooked up to DynamoDB, and ready to receive requests, we can proceed with setting up Okta. 

## Setting up Okta

Every Okta org comes with a built-in org [authorization server](https://developer.okta.com/docs/concepts/auth-servers/). **Do not** use this for your AgentCore Gateway as you cannot customize its audience, claims, policies, or scopes. Instead, set up a custom authorization server. 

If you don't have an Okta org to play with, or are nervous about experimenting in your prod org, you can set one up using their [Integrator Free Plan](https://developer.okta.com/docs/reference/org-defaults/) orgs option. It is limited to 10 users but that should be more than enough for you and a few beta-testers.

### Set up an Authorization Server

1. Go to **Security** > **API** > **Add Authorization Server**. Enter a name, desired audience, and a description
1. Open the authorization server you just created, click the **Claims** tab, and choose **Add Claim**
1. Name the new claim `client_id` and set its value to `app.clientId` 
1. Set **Include in token type** to **Access Token** and choose **Save**
1. Follow the same steps to add a `scopes` claim and set its value to `app.scopes`
1. Click the **Scopes** tab and add any custom scopes you need
1. Open the **Access Policies** tab and create an [access policy](https://developer.okta.com/docs/guides/configure-access-policy/main/)
1. Choose **All clients** in the **Assign to** field. You can always modify it to specific clients later
1. Click **Add Rule** on the policy you just created. Without a rule, Okta will reject all authorization requests against this server. 
1. Enable **Authorization Code** as a grant type, leave user and scope conditions as **Any**, and **Save**

If everything went well, you should see a JSON object that describes your authorization server's capabilities at [https://your-tenant.okta.com/oauth2/your-authorization-server-name/.well-known/openid-configuration](https://your-tenant.okta.com/oauth2/your-authorization-server-name/.well-known/openid-configuration). We'll use this URL later when setting up the gateway.

### Set up an Okta client

1. From the Okta developer console left navigation pane, click **Applications**
1. Select **Create App Integration**
1. Select **OIDC - OpenID Connect** and then **Native Application** as your application type
1. Under **Sign-in redirect URIs**, click **Add URI** twice and add:
   - `https://<your-proxy-domain>/callback`
   - `https://<your-proxy-domain>/sessionbinding/okta-callback`
1. Under **Assignments** select **Allow everyone in your organization to access**. 
1. Leave **Enable immediate access with Federation Broker Mode** checked. You can always return and modify these later
1. Hit **Save** and copy the generated client ID and use it as the proxy's static okta client id



## Setting up AgentCore Gateway
Before we can fully setup AgentCore Gateway, we need a [GitHub OAuth](https://docs.github.com/en/apps/oauth-apps/using-oauth-apps) app which will provide us with a client ID and secret for use in setting up AgentCore Gateway's [Outbound auth](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-outbound-auth.html).


### Setting up GitHub

1. Go to [https://github.com/settings/apps](https://github.com/settings/apps) and select **New GitHub App**
1. Fill in details, note that the GitHub App name must be unique
1. Under **Authorization callback URL**, enter a temporary value like `https://bedrock-agentcore.us-east-1.amazonaws.com/oauth/callback`. We will replace it with the generated AgentCore callback URL after creating the outbound identity.
1. Uncheck all the checkboxes
1. Leave user permissions as default but feel free to return and add more as your use-case requires
1. Choose **Any account** under **Where can this GitHub App be installed?**
1. Click **Create GitHub App**
1. You should see a "Registration successful. You must generate a private key in order to install your GitHub App." message. Follow the link to do so
1. Go to the Client Secrets section and click **Generate a new client secret**. Save the value as you won't see it again


### Set up AgentCore GitHub outbound identity

1. Sign in to your AWS account and go to the Amazon Bedrock AgentCore page
1. From the console left navigation pane, click **Identity**
1. Select **Add Outbound Auth** > **Add OAuth client**
1. Change the name to something you'll remember or make a note of the autogenerated one
1. Choose **Included provider** and then select **GitHub** from the drop-down
1. Enter the client ID of the GitHub App we created [above](#setting-up-github)
1. Similarly, enter the client secret you saved in [step 9](#setting-up-github) above
1. Click **Save**
1. Copy the outbound identity's callback URL and return to the GitHub OAuth app
1. Click **Add Callback URL** and add the copied value. Hit **Save**

### Create the AgentCore Gateway
Certain features of AgentCore Gateway can only be enabled during creation. These include the MCP protocol version, encryption settings, debug mode, amongst others. Perhaps the most important is  [semantic search](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html#:~:text=Semantic%20Tool%20Selection), which routes tool calls to the right target when similar tool names exist across multiple MCP servers.

1. Go to the Amazon Bedrock AgentCore page
1. From the console left navigation pane, click **Gateways**
1. Select **Create Gateway** and name your gateway
1. Open the **Additional configurations - optional** drop down
1. Select **Enable Semantic Search**
1. Select **Enable response streaming**
1. Choose `2025-11-25` under supported versions and click **Next**



> **Note:** `exception level` is enabled by default but not recommended for production, so be sure to disable it if you're creating your production gateway.

### Set up the Gateway IdP configs

1. Select **Use existing identity provider configurations**
1. Enter the `.well-known/openid-configuration` URL from the [authorization server](#set-up-an-authorization-server) section above in the **Discovery URL** field
1. Under **JWT Authorization Configuration** enter the client ID from the [Okta client](#set-up-an-okta-client) section above
1. Leave the rest of the settings as default and hit **Next**

### Add the GitHub MCP Server as an AgentCore Gateway Target
When using the UI to create the gateway, AWS requires you to set up at least one MCP target. In our case, this will be the GitHub MCP. 
1. Add 'github' to the autogenerated target name for easier identification
1. Under MCP endpoint, enter [https://api.githubcopilot.com/mcp/](https://api.githubcopilot.com/mcp/)
1. Select **OAuth client** under **Outbound Auth configurations** and choose the outbound identity created in the [outbound identity](#set-up-agentcore-github-outbound-identity) section above
1. Open the **Additional configurations - optional** drop down and select **Authorization code grant (3LO)**
1. Under **Return URL**, enter the proxy session binding URL, `https://<your-proxy-domain>/sessionbinding/callback`
1. Under **scopes**, add 3 scopes for `user`, `repo`, and `workflow`
1. Click **Next**, then **Create Gateway**. After the gateway is created, you'll be taken to its details page
1. You should also see a yellow banner that prompts you to authorize the GitHub MCP target. Click **Authorize** to do so. 
1. Wait for the authorization flow to complete. It can take anywhere from seconds to a few minutes
1. On completion, when you scroll down to the target list, the GitHub MCP target status should show  **Ready** and the **Authorization status** pane should say **No authorization required**


Authorizing here is an admin-level step that verifies your GitHub OAuth app is correctly configured. Each end user will still complete their own GitHub authorization the first time they invoke a tool.



## Connect your MCP client
To test the Gateway, you'll need to use a client that supports CIMD. That [rules out](https://github.com/modelcontextprotocol/inspector/issues/1150) the MCP Inspector. Fortunately, both VS Code and Claude Code do, hosting their CIMDs [here](https://vscode.dev/oauth/client-metadata.json) and [here](https://claude.ai/oauth/claude-code-client-metadata) respectively. Let's use VS Code.

You might want to use a different GitHub account from the one with which you completed the admin authorization. The reason is, as we alluded to earlier, if we make a tool call and the Gateway already has a saved token for the gateway/user pair, we might not see the full initial setup, including the elicitation. So use a different GitHub profile and accompanying Okta account to complete the steps below:

1. Create an `mcp.json` at `.vscode/mcp.json` in an active VS Code workspace 
1. Set it up as in the [example](#mcp-server-setup) shown earlier, replacing the url with your proxy's url
1. Click **Start** and complete the OAuth flow
1. Once VS Code completes initialization and caches the tools advertised by AgentCore Gateway, make a tool call. A good candidate would be `get_my_user_profile`
1. You should see the elicitation response pop up. Follow the prompts to grant consent
1. Once consent is completed, make the tool call again
1. Profit

## Where to go from here

You now have a single MCP gateway endpoint protected by Okta and your users can use it to call downstream MCP servers like GitHub's. From here, adding other MCP server targets would be a natural next step. As you do this, consider whether your organization might benefit from coupling AgentCore Gateway with [AgentCore Agent Registry](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html) to provide your end users with a one stop discovery shop for all things AI - MCPs, skills, and even Agents. 

Or you might want to stay on the security train and invest in some [hardening](https://builder.aws.com/content/3AEiRsxX7l9ZLq0FeC0TZwR82LR/zero-trust-ai-tool-access-how-claude-code-authenticates-to-agentcore-mcp-servers-with-okta#:~:text=Recommended%20policy%20rules) with Okta Authentication Policies or [AgentCore Policies](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html#:~:text=With%20Policy%20in%20AgentCore%2C%20developers,engine%20before%20allowing%20tool%20access.). Whatever you do, remember the field moves fast so make sure you're keeping up with new releases. Who knows, maybe sometime soon, we won't need a proxy anymore and AgentCore Gateway will ship with a full-on CIMD compatible authorization server.