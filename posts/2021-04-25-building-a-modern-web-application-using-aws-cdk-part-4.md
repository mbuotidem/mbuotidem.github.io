---
aliases:
- /2021/04/25/building-a-modern-web-application-using-aws-cdk-part-4
author: Isaac Mbuotidem
date: '2021-04-25'
description: Series on building a web application with the AWS CDK continued
keywords: aws, cdk, aws-cdk, devops, pipeline, infrastructure-as-code, projen
layout: post
title: Part 4 - Guichet - Building the transcription capability

---

In our last [post](https://mbuotidem.github.io/blog/2021/04/24/building-a-modern-web-application-using-aws-cdk-part-3.html) we built out the s3 bucket, DynamoDB table and lambda function resources for our application. In this post, we will modify the placeholder lambda function that we created. At the end of the post, we should be able to upload a sound file into our bucket and have our lambda invoke the Amazon Transcribe service with it. 

### Working with Amazon Transcribe
Creating an S3 bucket resource is simple with the AWS CDK. The same general pattern applies regardless of the construct. All you need do is import the module that contains said construct, and then make use of it. In this case, we need the s3 construct which we can find in the npm module  `@aws-cdk/aws-s3`. Our code below does just that in addition to setting some bucket properties such as the bucket's removal policy and the access permissions. You can learn more about these bucket property options [here](https://docs.aws.amazon.com/cdk/api/latest/docs/@aws-cdk_aws-s3.Bucket.html). Finally, we use the `CfnOutput` construct to surface the name of the created bucket upon completion. 

```
import * as cdk from '@aws-cdk/core';
import * as s3 from '@aws-cdk/aws-s3';

//s3 audio bucket
const audioBucket = new s3.Bucket(this, 'AudioBucket', {
    removalPolicy: cdk.RemovalPolicy.DESTROY,
    publicReadAccess: true,
    accessControl: s3.BucketAccessControl.PUBLIC_READ,
});

new cdk.CfnOutput(this, 'audioBucket', { value: audioBucket.bucketName });
```

***
Liking the series? In our next [post](https://mbuotidem.github.io/blog/2021/04/26/building-a-modern-web-application-using-aws-cdk-part-5.html), we will continue building out our lambda function, adding the ability to store the transcription results in a DynamoDB table. You can find the previous post [here](https://mbuotidem.github.io/blog/2021/04/24/building-a-modern-web-application-using-aws-cdk-part-4.html) And if you'd like to dive into the code, here is a [link](https://github.com/mbuotidem/guichet) to the project on GitHub.
