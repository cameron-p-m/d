#### d

d is for organization of source files. It organizes things like this `~/src/github.com/[owner]/[repo]` and allows easy naviagtion and cloning in this format.

```
➜  d                                                                                                             
usage:
  d <command> [options]
commands:
  cd      navigate
  clone   clone repo
options:
  -v      verbose output
```

#### install

Only works for zsh for now because that's what I use. Requires HOME env variable. This builds from source.

```
./scripts/install.sh

source ~/.zshrc <- reload shell
```
