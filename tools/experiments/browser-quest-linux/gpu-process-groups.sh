# Own only the fresh setsid groups launched by this browser runtime.
# SPDX-License-Identifier: MIT
nf_gpu_groups=()
nf_gpu_register_group() {
    [[ $1 =~ ^[1-9][0-9]*$ && $1 -gt 1 && $1 != $$ && $1 != $BASHPID ]] || return 1
    nf_gpu_groups+=("$1")
}
nf_gpu_stop_groups() {
    local group
    for group in "${nf_gpu_groups[@]}"; do kill -TERM -- "-$group" 2>/dev/null || true; done
    if ((${#nf_gpu_groups[@]})); then
        sleep .15
        for group in "${nf_gpu_groups[@]}"; do kill -KILL -- "-$group" 2>/dev/null || true; done
    fi
    nf_gpu_groups=()
}
