---
aliases:
- /2021/01/09/how-to-hot-reload-auto-refresh-react-app-on-WSL
author: Isaac Mbuotidem
date: '2021-01-09'
layout: post
title: How To Hot Reload Auto Refresh React App On Wsl

---

If you're working on a React app on Windows using Windows Subsystem for Linux (WSL), you might find that your app does not reflect your changes on save. 

Your first step to fixing this is to ensure that your React files are located on the WSL filesystem and not the Windows filesystem. For example, if your files are saved at : 

`C:Users\yourusername\Documents\test-react-app`

Use the `cp` command to copy them over to your WSL filesystem like so:

`cp -r /mnt/c/Users/yourusername/Documents/test-react-app ~/test-react-app`. 

The above will copy the files to your WSL user account's home directory which you can always get to by typing `wsl ~` from `Command Prompt` or `Windows Terminal`. 

If that still does not work, try running your app in the terminal by prepending the commands below to `npm start` For example: 

`CHOKIDAR_USEPOLLING=true npm start` 

There is a chance that it still won't auto-reload. In that case, try running your app with:

`FAST_REFRESH=false npm start`. 

For whichever of these that works, you you might want to make it into a more permanent solution instead of having to type that in each time. To do that, you have two options. 

\
You can create a `.env` file in your project directory if you don't already have one and add

``` 
CHOKIDAR_USEPOLLING=true
FAST_REFRESH=false

``` 

to the `.env` file. 

\
Or you can edit your `package.json` file like so: 

```
{

  "scripts": {
    "start": "FAST_REFRESH=false react-scripts start",
    "build": "react-scripts build",
    "test": "react-scripts test",
    "eject": "react-scripts eject"
  },


}
````

\
Credit : [https://stackoverflow.com/a/56199112](https://stackoverflow.com/a/62942176/7179900){:class="lnk"}




