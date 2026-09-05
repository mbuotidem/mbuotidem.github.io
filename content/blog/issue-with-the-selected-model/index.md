+++
title = "Fixing \"There's an issue with the selected model\" in Claude Code"
date = 2026-09-05
description = "Error: There's an issue with the selected model (claude-3-5-haiku-latest) - the likely cause is a retired model in ANTHROPIC_DEFAULT_HAIKU_MODEL or ANTHROPIC_SMALL_FAST_MODEL"
slug = "issue-with-the-selected-model"

[taxonomies]
tags = ["ai", "agentic-ai", "claude-code"]

[extra]
toc = false
+++

I recently encountered the error below when using the WebFetch tool in Claude Code:

```
Error: There's an issue with the selected model (claude-3-5-haiku-latest). 
It may not exist or you may not have access to it. Run /model to pick a different model.
```

If you encounter this error, the issue is likely that you set the value of either `ANTHROPIC_DEFAULT_HAIKU_MODEL` or `ANTHROPIC_SMALL_FAST_MODEL` to a now [retired model](https://platform.claude.com/docs/en/about-claude/model-deprecations). Claude Code uses the Haiku model for WebFetch and other [background functionality](https://code.claude.com/docs/en/costs#background-token-usage), which is why the rest of Claude Code kept working for me. Note also that `ANTHROPIC_SMALL_FAST_MODEL` is [itself deprecated](https://code.claude.com/docs/en/model-config#environment-variables) so when making the fix in [`settings.json`](https://code.claude.com/docs/en/settings#where-settings-live) for Claude, either you remove the key or you switch to `ANTHROPIC_DEFAULT_HAIKU_MODEL` and set it to a supported and available model.