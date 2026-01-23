+++
title = "Make your Slack AI app faster"
slug = "make-your-slack-ai-apps-faster"
description = "Tricks to make you Slack AI app feel faster for your users"
date = "2025-09-30"
[taxonomies] 
tags = ["aws", "terraform", "slack", "gen-ai", "iac", "bedrock", "llms", "ai", "generative-ai", "chatops"]
+++

> **Note:**
>Update (October 2025): Since this post was written, Slack Web API has released a [native streaming message](https://docs.slack.dev/changelog/2025/10/7/chat-streaming/) capability. 
>
>You can now use the methods `chat.startStream`, `chat.appendStream`, and `chat.stopStream` along with new Block Kit elements to provide a token-by-token streaming experience in Slack apps.
>If you’re building an AI agent in Slack today, you may want to swap out the manual “chat.update with chunks” workaround in the write-up for these new APIs.


## Introduction

In [part 1](https://misaac.me/blog/ai-apps-in-slack-bedrock/), when we setup our Slack AI app, we observed that while [true streaming responses](https://github.com/slack-samples/bolt-js-assistant-template/issues/27#issuecomment-2755641964) are not currently possible via the Slack SDK, a workaround involving continuously calling `chat.update` exists. In this post, we'll update our Slack AI app to use this workaround. We'll also briefly consider other tricks that might help with our lambda's responsiveness.

### Previous state
As a refresher, our previous function looked like this:

```python
def call_bedrock(
    messages_in_thread: List[Dict[str, str]],
    system_content: str = DEFAULT_SYSTEM_CONTENT,
):
    # Format messages for Bedrock API - content must be a list
    messages = [{"role": "assistant", "content": [{"text": system_content}]}]

    # Convert thread messages to Bedrock format
    for msg in messages_in_thread:
        formatted_msg = {"role": msg["role"], "content": [{"text": msg["content"]}]}
        messages.append(formatted_msg)

    model_id = BEDROCK_MODEL_ID

    response = bedrock_runtime_client.converse(
        messages=messages, modelId=model_id, performanceConfig={"latency": "optimized"}
    )

    # Process the response from the Bedrock AI model
    response_content = response["output"]["message"]["content"][0]["text"]
    return markdown_to_slack(response_content)

```
Here we call the Amazon Bedrock api sending in our messages, and then post the returned response to the user in slack using [`say`](https://docs.slack.dev/tools/bolt-python/reference/context/say/say.html). Notice that we're calling Bedrock with the `Converse` method. To incorporate 'streaming', we're going to switch to the `ConverseStream` method which returns the response in a stream. To learn more about both `Converse` and `ConverseStream`, see ["Carry out a conversation with the Converse API operations"](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html#conversation-inference-supported-models-features). 

### Switching to ConverseStream

Let's call our new function, `call_bedrock_stream`. It has a couple of new parameters,`slack_token`, `throttle_ms`, and `say`. Within it, we also have a helper function `call_slack_update` which uses these new parameters to call Slack and update the message using the Slack API's [`chat.update`](https://docs.slack.dev/reference/methods/chat.update/) method.

```python
def call_bedrock_stream(
    messages_in_thread: List[Dict[str, str]],
    system_content: str = DEFAULT_SYSTEM_CONTENT,
    slack_token=None,
    throttle_ms=500,
    say=None,
):
    import time

    # Convert thread messages to Bedrock format
    messages = []
    for msg in messages_in_thread:
        formatted_msg = {"role": msg["role"], "content": [{"text": msg["content"]}]}
        messages.append(formatted_msg)

    # System prompts for streaming API
    system_prompts = [{"text": system_content}]

    model_id = BEDROCK_MODEL_ID

    # Basic inference configuration
    inference_config = {"temperature": 0.7, "maxTokens": 8192}

    def call_slack_update(text, initial_message):
        """Helper to safely update the Slack message"""
        if initial_message:
            try:
                from slack_sdk import WebClient

                sync_client = WebClient(token=slack_token)
                sync_client.chat_update(
                    channel=initial_message["channel"],
                    ts=initial_message["ts"],
                    text=text,
                )
            except Exception as e:
                print(f"Error updating Slack message: {e}")

    try:
        response = bedrock_runtime_client.converse_stream(
            modelId=model_id,
            messages=messages,
            system=system_prompts,
            inferenceConfig=inference_config,
        )

        # Collect the streamed response
        complete_response = ""
        stream = response.get("stream")
        last_update_time = 0

        initial_message = None
        try:
            initial_message = say(" ")
        except Exception as e:
            print(f"Error creating initial Slack message: {e}")


        if stream:
            for event in stream:
                if "contentBlockDelta" in event:
                    delta_text = event["contentBlockDelta"]["delta"]["text"]
                    complete_response += delta_text

                    # Call Slack update with throttling if provided
                    current_time = time.time() * 1000  # Convert to milliseconds
                    if current_time - last_update_time >= throttle_ms:
                        call_slack_update(
                            markdown_to_slack(complete_response), initial_message
                        )
                        last_update_time = current_time

                if "messageStop" in event:
                    print(f"\nStop reason: {event['messageStop']['stopReason']}")

                if "metadata" in event:
                    metadata = event["metadata"]
                    if "usage" in metadata:
                        print(
                            f"\nToken usage - Input: {metadata['usage']['inputTokens']}, "
                            f"Output: {metadata['usage']['outputTokens']}, "
                            f"Total: {metadata['usage']['totalTokens']}"
                        )

        # Final update with complete response
        final_response = markdown_to_slack(complete_response)
        call_slack_update(final_response, initial_message)

        return final_response

    except Exception as e:
        print(f"Error in streaming call: {str(e)}")
        # Fallback to non-streaming call
        return call_bedrock(messages_in_thread, system_content)
```

Here's how the streaming flow works. 

1. **Setup**: Before calling `call_bedrock_stream`  we use the [`setStatus`](https://docs.slack.dev/reference/methods/assistant.threads.setStatus/) method to immediately show users that the bot is thinking. 

2. **Stream processing**:Inside `call_bedrock_stream`, we invoke Bedrock's converse_stream API to get response chunks. Immediately after making this call, we post an empty message to the Slack thread using say - this serves as a placeholder that we'll update with the actual response. 

    As each chunk arrives from Bedrock (the stream continues until we receive a `messageStop` event), we update the Slack message in place using our helper function. Here's a quick video to demonstrate the effect.



<video width="640" height="360" controls poster="slackaiapps.png">
  <source src="slackstreaming.mp4" type="video/mp4">
  Your browser does not support the video tag. Here is a <a href="slackstreaming.mp4">direct link to the video</a> and a brief description: "This video demonstrates how Slack messages are updated in real-time using streaming responses from Amazon Bedrock."
</video>

3. **Complete response**: Finally, we send the entire response. This final update ensures that even if the streaming updates fail partway through (network issues, rate limiting, etc.), the complete message reaches Slack.
