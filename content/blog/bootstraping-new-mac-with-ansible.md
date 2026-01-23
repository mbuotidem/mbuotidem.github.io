+++
title = 'Bootstraping my mac with ansible'
slug= "bootstraping-new-mac-with-ansible"
description = "How to have a repeatable mac bootstrapping process"
date = "2025-02-12"
[taxonomies] 
tags = ["IaC", "Ansible"]
+++

I recently purchased a Macbook and decided to finally take the time to setup a repeatable bootstrap process. 

I initially considered writing my own ansible playbook, but ultimately settled on the amazing [mac-dev-playbook](https://github.com/geerlingguy/mac-dev-playbook) from Jeff Geerling. Here are the steps I took to get this going. 

### Pre-requisites
1. Open a terminal window and follow prompts to install the command line tools. 
    ```
    xcode-select --install
    ```

1. Install Ansible 
    - Add Python 3 to your $PATH:
    ```
    export PATH="$HOME/Library/Python/3.9/bin:/opt/homebrew/bin:$PATH"
    ```
    - Upgrade Pip: 
    ```
    sudo pip3 install --upgrade pip
    ```
    - Install Ansible: 
    ```
    pip3 install ansible
    ```

1. Clone repo with
    ```
    git clone https://github.com/geerlingguy/mac-dev-playbook.git
    ```

1. Install required Ansible roles. 
    ```
    cd mac-dev-playbook && ansible-galaxy install -r requirements.yml`
    ```

### Customization

Jeff Geerling provides a sample [config](https://github.com/geerlingguy/mac-dev-playbook/blob/master/default.config.yml) file, but I don't need everything there so I modified it to suit my current needs. My config file looks like this:

```text
homebrew_taps:
  - common-fate/granted
  - hashicorp/tap

homebrew_installed_packages:
  - git
  - go
  - mise
  - zsh-history-substring-search
  - terraform
  - granted
  - gh
  - zola
  - awscli

homebrew_cask_appdir: /Applications
homebrew_cask_apps:
  - firefox@nightly
  - visual-studio-code
  - google-chrome
  - orbstack
  - rectangle
  - alt-tab

mas_installed_apps:
  - { id: 497799835, name: "Xcode" }

configure_dock: true
dockitems_remove:
  - Launchpad
  - News
  - Keynote
  - Numbers
  - Pages
  - "App Store"
  - Freeform
  - Reminders
  - Notes
dockitems_persist:
  - name: "Code"
    path: "/Applications/Visual Studio Code.app"
    pos: 15

```

As I need other tools, I will simply add them to the relevant section, but for now, this is enough to get started with. You may notice I'm not using ansible/brew to install `rbenv`, `npm`, `pyenv` or `java`. That's because imho [mise](https://mise.jdx.dev/) is the best tool for managing these. If you're unfamiliar with mise, see the [getting-started](https://mise.jdx.dev/getting-started.html), [tasks](https://mise.jdx.dev/tasks/), and [cookbooks](https://mise.jdx.dev/mise-cookbook/) sections for a sense of how mise can make your life easier. 

### Deployment
Run the command below and enter you macOS account password when prompted for the 'BECOME' password.
  ```
  ansible-playbook main.yml --ask-become-pass
  ```

