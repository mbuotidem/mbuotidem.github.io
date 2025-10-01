+++
title = "Make your Slack AI app faster"
slug = "make-your-slack-ai-apps-faster"
description = "Tricks to make you Slack AI app feel faster for your users"
date = "2025-09-30"
[taxonomies] 
tags = ["aws", "terraform", "slack", "gen-ai", "iac", "bedrock", "llms", "ai", "generative-ai", "chatops"]
+++

## Introduction

In [part 1](https://misaac.me/blog/ai-apps-in-slack-bedrock/), when we setup our Slack AI app, we observed that while [true streaming responses](https://github.com/slack-samples/bolt-js-assistant-template/issues/27#issuecomment-2755641964) are not currently possible via the Slack SDK, a workaround involving continuously calling `chat.update` exists. In this post, we'll update our Slack AI app to use this workaround. 

