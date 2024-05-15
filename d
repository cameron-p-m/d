binary_dir="$HOME/.d/bin/dd"

d() {
    output="$($binary_dir ${@})"
    eval "${output}"
}

