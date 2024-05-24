#### d

d is for organization of source files. It organizes things like this `~/src/github.com/[owner]/[repo]` and allows easy naviagtion and cloning in this format.

```
➜  d                                                                                                             
usage:
  d <command> [options]
commands:
  cd <target>      navigate
  clone <target>   clone repo
  open pr          open pr on github
options:
  -v      verbose output
```

#### install

Only works for zsh for now because that's what I use. Requires HOME env variable.

```
./scripts/install.sh

source ~/.zshrc <- reload shell
```

#### contribute

If you want to contribute, this project used zig 0.12.0. You can build from source too with `zig build`
