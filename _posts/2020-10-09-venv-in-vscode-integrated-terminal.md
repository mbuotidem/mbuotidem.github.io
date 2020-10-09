---
layout: post
author: Isaac
---
When you choose to use a python venv virtual environment in vscode, you might run into the error below :

`The file C:\yourpath\.env\Scripts\Activate.ps1 is not digitally signed. You cannot run this script on the current system.`

![Vscode integrated terminal displaying powershell error](/assets/blog_images/10_9_0.PNG){:class="img-responsive"}


A quick solution is to add this to your [vscode settings.json](https://vscode.readthedocs.io/en/latest/getstarted/settings/){:class="lnk"}  file :

```
{
    "terminal.integrated.shellArgs.windows": [
        "-ExecutionPolicy",
        "Bypass"
    ],

}
```


Credit : [https://stackoverflow.com/a/56199112](https://stackoverflow.com/a/56199112){:class="lnk"}