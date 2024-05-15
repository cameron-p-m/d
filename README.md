#### d

d is for organization of source files. It organizes things like this `~/src/github/[owner]/[repo]` and allows easy naviagtion and cloning (coming soon) in this format.

```
➜  d                                                                                                             
usage:
 d [desired_path]
   -v verbose

➜  d -v breakdown                                                                                                
desired: breakdown

top:
2 /Users/cameronmorgan/src/github/cameron-p-m/breakdown
2 /Users/cameronmorgan/src/github/cameron-p-m/breakdown-server
24 /Users/cameronmorgan/src/github/cameron-p-m/BreakdownOld
24 /Users/cameronmorgan/src/github/cameron-p-m/BreakdownSwiftData
command:
 cd /Users/cameronmorgan/src/github/cameron-p-m/breakdown

```

#### install

Only works for zsh for now because that's what I use. Requires HOME env variable.

```
./install
```