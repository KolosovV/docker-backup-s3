# bash completion for docker-backup and docker-restore
# Installation:
#   sudo cp docker-backup-completion.bash /etc/bash_completion.d/docker-backup
# or for the current user:
#   source /opt/docker-backup/docker-backup-completion.bash

_docker_backup() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="-c --config -n --dry-run -p --project -l --list -h --help"

    case "$prev" in
        -c|--config)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
    fi
}

_docker_restore() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="-c --config -p --project -t --timestamp -d --dir -y --yes -l --list --no-start --from --from-secondary --contents --extract-to --only-volume -h --help"

    case "$prev" in
        -c|--config|-d|--dir|--extract-to)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        --only-volume)
            COMPREPLY=( $(compgen -W "$(docker volume ls -q 2>/dev/null)" -- "$cur") )
            return 0
            ;;
        --from)
            COMPREPLY=( $(compgen -W "primary secondary tertiary" -- "$cur") )
            return 0
            ;;
        -p|--project)
            # Try to pull the project list from S3 (needs a configured config)
            local script_dir
            for cmd in "${COMP_WORDS[0]}" "/opt/docker-backup/docker-restore.sh"; do
                if [[ -x "$cmd" ]]; then
                    script_dir="$(cd "$(dirname "$cmd")" && pwd)"
                    break
                fi
            done
            if [[ -n "$script_dir" && -f "$script_dir/backup.conf" ]]; then
                local projects
                projects=$(
                    # shellcheck disable=SC1090
                    source "$script_dir/backup.conf" 2>/dev/null
                    # The primary storage; an old backup.conf called it plain S3_*
                    AWS_ACCESS_KEY_ID="${PRIMARY_S3_ACCESS_KEY:-$S3_ACCESS_KEY}" \
                    AWS_SECRET_ACCESS_KEY="${PRIMARY_S3_SECRET_KEY:-$S3_SECRET_KEY}" \
                    AWS_DEFAULT_REGION="${PRIMARY_S3_REGION:-$S3_REGION}" \
                    aws --endpoint-url "${PRIMARY_S3_ENDPOINT:-$S3_ENDPOINT}" ${PRIMARY_S3_OPTS_EXTRA:-$S3_OPTS_EXTRA} \
                        s3api list-objects-v2 \
                        --bucket "${PRIMARY_S3_BUCKET:-$S3_BUCKET}" \
                        --prefix "${BACKUP_PREFIX}/" \
                        --delimiter "/" \
                        --query 'CommonPrefixes[].Prefix' \
                        --output text 2>/dev/null \
                    | tr '\t' '\n' \
                    | sed "s|^${BACKUP_PREFIX}/||; s|/$||" \
                    | grep -v '^$'
                )
                COMPREPLY=( $(compgen -W "$projects" -- "$cur") )
            fi
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
    fi
}

complete -F _docker_backup docker-backup.sh
complete -F _docker_restore docker-restore.sh

# Also if installed in /usr/local/bin or similar:
complete -F _docker_backup /opt/docker-backup/docker-backup.sh
complete -F _docker_restore /opt/docker-backup/docker-restore.sh

# The docker-backup command (menu.sh): the first word is a subcommand, the rest go to its script
_docker_backup_cmd() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "backup restore status sync verify validate diagnose logs schedule drop update uninstall menu help -c" -- "$cur") )
        return 0
    fi
    case "${COMP_WORDS[1]}" in
        backup)  COMP_WORDS=(docker-backup.sh "${COMP_WORDS[@]:2}"); COMP_CWORD=$((COMP_CWORD - 1)); _docker_backup ;;
        restore) COMP_WORDS=(docker-restore.sh "${COMP_WORDS[@]:2}"); COMP_CWORD=$((COMP_CWORD - 1)); _docker_restore ;;
    esac
}
complete -F _docker_backup_cmd docker-backup
