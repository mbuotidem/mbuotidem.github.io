
+++
title = "Fix model access is denied not authorized to perform the required AWS Marketplace actions"
slug= "aws-bedrock-access-denied-marketplace-actions"
description = "Resolve AWS Bedrock  Model access is denied due to IAM user or service role is not authorized to perform the required AWS Marketplace actions (aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe) to enable access to this model. Refer to the Amazon Bedrock documentation for further details. Your AWS Marketplace subscription for this model cannot be completed at this time. If you recently fixed this issue, try again after 15 minutes."
date = "2025-11-22"
[taxonomies] 
tags = ["aws", "bedrock", "ai", "Claude", "haiku", "claude-haiku-4-5"]
+++

AWS recently made Claude 4.5 Haiku by Anthropic [available](https://aws.amazon.com/about-aws/whats-new/2025/10/claude-4-5-haiku-anthropic-amazon-bedrock/) in Amazon Bedrock. Haiku is an [excellent](https://www.anthropic.com/news/claude-haiku-4-5) model that balances speed with accuracy so I was eager to try it out. 

However when I would make api calls using the [Strands Agents SDK](https://strandsagents.com/latest/), I kept getting the error: 

`
AWS Bedrock  Model access is denied due to IAM user or service role is not authorized to perform the required AWS Marketplace actions (aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe) to enable access to this model. Refer to the Amazon Bedrock documentation for further details. Your AWS Marketplace subscription for this model cannot be completed at this time. If you recently fixed this issue, try again after 15 minutes.
`

I added these permissions to the role and yet the errors persisted. So I went into the AWS Console and visited the Bedrock model playground. Suprise, surprise - same error when I tried to use the model even though I had pretty close to admin permissions. And I had no SCP's blocking me. So what gives?

Turns out the issue has to do with recent AWS changes to how models are enabled in Bedrock.  With  [simplified model access in Amazon Bedrock](https://aws.amazon.com/blogs/security/simplified-amazon-bedrock-model-access/), model subscriptions are supposed to occur [on first invocation](https://aws.amazon.com/blogs/security/simplified-amazon-bedrock-model-access/#:~:text=Considerations%20for%20Amazon%20Bedrock%20serverless%20models%20offered%20via%20AWS%20Marketplace).

That said, I was too impatient to wait for 15 minutes to see if this works. So if you're like me and want to make doubly sure, here are the commands, sourced from [here](https://github.com/anthropics/claude-code/issues/9681). 

1. Find your model id, in my case, it was `anthropic.claude-haiku-4-5-20251001-v1:0`

1. Get the offer token with 

    ``` 
    aws bedrock list-foundation-model-agreement-offers --model-id anthropic.claude-haiku-4-5-20251001-v1:0        
    ```

1. Create the marketplace agreement with 

    ```
    aws bedrock create-foundation-model-agreement --model-id anthropic.claude-haiku-4-5-20251001-v1:0 --offer-token <value of offer token from last command>

    ```

I still had to wait 15 minutes, but after that, I was finally able to use Claude 4.5 Haiku. 

The good news is that if you use AWS organizations, enabling it from the management account will apply for all other accounts. If you use Terraform for automation, well, there's an open issue [here](https://github.com/hashicorp/terraform-provider-aws/issues/43835) - go make that PR!

Now if only they can get Claude 4.5 on the [latency optimized](https://docs.aws.amazon.com/bedrock/latest/userguide/latency-optimized-inference.html) list! 