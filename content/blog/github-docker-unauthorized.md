+++
title = 'GitHub - Resolving Error response from daemon: Head : unauthorized'
slug= "github-docker-unauthorized"
description = "Shows how to successfully pull an image from GitHub Package Registry"
date = "2024-10-03"
[taxonomies] 
tags = ["docker", "GitHub", "GitHub CLI"]
+++

# Problem Statement

**You get an unathorized error when trying to pull an image from GitHub.**

This generally happens because you either don't have a GitHub token set up, or your token doesn't have the right permissions.

## Install and setup the GitHub CLI

While you can setup a GitHub token manually by going to https://github.com/settings/tokens?type=beta, I prefer to just use the `gh auth token` feature of the [GitHub CLI](https://cli.github.com/). 


### Setup GitHub CLI

1. Install the [GitHub CLI](https://cli.github.com/) using the instructions [here](https://cli.github.com/). 
1. Login using `github auth login` and follow the instructions in your terminal to authenticate in your browser using the one-time code that will appear
	```bash
	gh auth login
	```
1. Verify you're successfully logged in with `gh auth status`. You should see something like: 
	```bash
	gh auth status
	```
	<pre><code style="line-height: 20%;">
	➜ gh auth status

	github.com
	
	✓ Logged in to github.com account mbuotidem (keyring)

	\- Active account: true

	\- Git operations protocol: ssh

	\- Token: gho_************************************

	\- Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo'

	</code></pre>


### Grant yourself the packages read scope

1. Run `gh auth refresh` passing in the desired scope. Follow the instructions in your terminal to authenticate in your browser using the one-time code that will appear
	```bash
	gh auth refresh --scopes read:packages
	```

### Docker login and try to pull again

1. Pipe the auth token into the docker login command - make sure to replace `mbuotidem` with your GitHub username
	```bash
	gh auth token | docker login ghcr.io -u mbuotidem --password-stdin
	```
1. You can now pull the image
	```bash
	docker pull ghcr.io/mbuotidem/mbuotidem.github.io:main  
	```


If you need to grant yourself other scopes, learn more about available scopes [here](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-with-a-personal-access-token-classic)
To learn more about available GitHub CLI commands, go [here](https://cli.github.com/manual/gh)