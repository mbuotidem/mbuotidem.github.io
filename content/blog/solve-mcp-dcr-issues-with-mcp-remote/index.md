+++
title = "Solve Claude Code MCP Dynamic Client Registration (DCR) issues with mcp-remote"
date = 2026-02-08
description = "Error: Incompatible auth server: does not support dynamic client registration - a possible fix if your MCP server lets you generate OAuth credentials"

[taxonomies]
tags = ["ai", "mcp", "agentic-ai"]

[extra]
toc = false
+++

The early false starts in the MCP Auth spec has led to fragmented implementations. Some remote MCP servers fully support the spec and others don't. The same goes for clients, some like VS Code have made [concerted efforts](https://github.com/microsoft/vscode/issues?q=is%3Aissue%20state%3Aclosed%20mcp%20auth) to be fully spec compliant, while others like Claude Code haven't prioritized full spec compliance. 

You can see this play out in [a](https://github.com/github/github-mcp-server/issues/549) [host](https://github.com/anthropics/claude-code/issues/3273) [of](https://github.com/anthropics/claude-code/issues/5826) [issues](https://github.com/anthropics/claude-code/issues/3433) on the Claude Code repo. The main culprit is that Claude Code currently seems to expect all MCP servers support Dynamic Client Registration and doesn't fallback when that proves not to be the case. 

That's unfortunate because the [2025-11-25 spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#client-registration-approaches) treats Client ID Metadata Documents and Pre-registration as strongly recommended (SHOULD), whereas DCR is merely optional (MAY). In other words, Claude Code is requiring the one thing the spec says is optional, while ignoring the approaches the spec says clients should support. See also [note](https://modelcontextprotocol.io/docs/tutorials/security/authorization) below from the docs reiterating that MCP clients provide a way for end users to manually enter their OAuth client information if DCR is unavailable.

[![alt text](admonish.png)](https://modelcontextprotocol.io/docs/tutorials/security/authorization#:~:text=In%20case%20an,client%20information%20manually.)

So what does Claude Code's implementation choice lead to?


## Error: Incompatible auth server: does not support dynamic client registration 
![alt text](claude.png)
That's the error most Claude Code users encounter when they try to setup the GitHub MCP following the instructions on Claude Code's [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp#example-connect-to-github-for-code-reviews) page. 

Enter mcp-remote. mcp-remote works as a proxy connecting your desired remote mcp server to your MCP client via stdio. One of its neat features is the [`static-oauth-client-information`](https://github.com/geelen/mcp-remote?tab=readme-ov-file#static-oauth-client-information) flag. This lets you pass in OAuth credentials for use with the remote mcp you are connecting to. I should note that mcp-remote is `experimental` - use at your own risk!

1. [Create](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app) a GitHub OAuth App

1. Add the GitHub mcp to Claude via mcp-remote. 

    ```bash
    claude mcp add --transport stdio github -- \
        npx mcp-remote https://api.github.com/mcp \
        --static-oauth-client-info '{
            "client_id": "your_client_id",
            "client_secret": "your_client_secret"
        }'
    ```

    Replace `your_client_id` and `your_client_secret` with the values from your GitHub OAuth App.

1. Profit
![alt text](connected.png)
Although GitHub is our focus here, this trick will likely work for any MCP server that supports pre-registered clients, which is often the case with MCP's that don't support DCR. GitHub is also [working](https://github.com/github/github-mcp-server/pull/1836) on a stdio oauth solution. However it only works in MCP cients that support elicitation which Claude Code doesn't yet. Keep an eye on these [two](https://github.com/anthropics/claude-code/issues/2799) [issues](https://github.com/github/github-mcp-server/issues/132) for updates.