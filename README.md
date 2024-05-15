#### d

d is for organization of source files. It organizes things like this `~/src/github.com/[owner]/[repo]` and allows easy naviagtion and cloning (coming soon) in this format.

```
➜  d                                                                                                             
usage:
 d cd [desired] [optional_flags]
   -v verbose output

➜  d cd -v breakdown                                                                                                
desired: breakdown

top:
2 /Users/cameronmorgan/src/github.com/cameron-p-m/breakdown
2 /Users/cameronmorgan/src/github.com/cameron-p-m/breakdown-two
24 /Users/cameronmorgan/src/github.com/cameron-p-m/breakdown-three
command:
 cd /Users/cameronmorgan/src/github.com/cameron-p-m/breakdown

```

#### install

Only works for zsh for now because that's what I use. Requires HOME env variable.

```
./scripts/install.sh

source ~/.zshrc <- reload shell
```
