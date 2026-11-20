
#!/bin/sh
# ============================================================
# BACUSP 7.7 - Independent Repository Engine
# ============================================================
# Priorities:
#   1. Official system repositories (future native adapters)
#   2. Community repositories
#   3. External distribution repositories
#
# Current supported index:
#   name version architecture os sha256 filename url dependencies
#
# Native package managers are never executed.
# ============================================================

set -eu
umask 077

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
REPOS_FILE="$BACUSP_HOME/repos.list"
INDEX_DIR="$BACUSP_HOME/repositories"

mkdir -p "$BACUSP_HOME" "$INDEX_DIR"
chmod 700 "$BACUSP_HOME" "$INDEX_DIR" 2>/dev/null || :

usage() {
    cat <<'EOF'
BACUSP Repository Engine 7.7

Usage:
  bacusp repo add URL [community|external]
  bacusp repo remove URL
  bacusp repo list
  bacusp repo sync
  bacusp repo candidates PACKAGE

Default tier: community

Index:
  URL/index.tsv

TSV fields:
  name version architecture os sha256 filename url dependencies

Example:
  btop<TAB>1.4.5<TAB>x86_64<TAB>linux<TAB>SHA256<TAB>btop.bp<TAB>https://example.org/btop.bp<TAB>-

Rules:
  - HTTPS required.
  - SHA-256 must contain exactly 64 hexadecimal characters.
  - Official repositories are reserved for native system adapters.
  - Existing legacy URL-only entries are treated as community.
EOF
}

error() {
    printf 'BACUSP repo: ERROR: %s\n' "$*" >&2
}

info() {
    printf 'BACUSP repo: %s\n' "$*"
}

valid_url() {
    case "$1" in
        https://*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_tier() {
    case "$1" in
        community|external) return 0 ;;
        *) return 1 ;;
    esac
}

repo_id() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

read_repo_line() {
    LINE_URL=
    LINE_TIER=

    case "$1" in
        *'|'*)
            LINE_URL=${1%%|*}
            LINE_TIER=${1#*|}
            ;;
        *)
            LINE_URL=$1
            LINE_TIER=community
            ;;
    esac

    [ -n "$LINE_URL" ] || return 1
    valid_url "$LINE_URL" || return 1
    valid_tier "$LINE_TIER" || return 1
}

repo_add() {
    URL=${1:-}
    TIER=${2:-community}

    [ -n "$URL" ] || {
        error "falta la URL."
        exit 2
    }

    valid_url "$URL" || {
        error "HTTPS es obligatorio."
        exit 2
    }

    valid_tier "$TIER" || {
        error "prioridad inválida. Usá community o external."
        exit 2
    }

    touch "$REPOS_FILE"

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        [ -n "$LINE" ] || continue

        if read_repo_line "$LINE"; then
            if [ "$LINE_URL" = "$URL" ]; then
                error "el repositorio ya está configurado."
                exit 1
            fi
        fi
    done < "$REPOS_FILE"

    printf '%s|%s\n' "$URL" "$TIER" >> "$REPOS_FILE"

    info "repositorio agregado: $URL"
    info "prioridad: $TIER"
}

repo_remove() {
    URL=${1:-}

    [ -n "$URL" ] || {
        error "falta la URL."
        exit 2
    }

    [ -f "$REPOS_FILE" ] || {
        error "no hay repositorios configurados."
        exit 1
    }

    TMP="$BACUSP_HOME/repos.remove.tmp"
    FOUND=0

    : > "$TMP"

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        [ -n "$LINE" ] || continue

        if read_repo_line "$LINE"; then
            if [ "$LINE_URL" = "$URL" ]; then
                FOUND=1
                continue
            fi
        fi

        printf '%s\n' "$LINE" >> "$TMP"
    done < "$REPOS_FILE"

    mv "$TMP" "$REPOS_FILE"

    if [ "$FOUND" -eq 0 ]; then
        error "el repositorio no estaba registrado."
        exit 1
    fi

    # Remove only the index belonging to this repository.
    ID=$(repo_id "$URL")
    rm -f "$INDEX_DIR/community-$ID.tsv"
    rm -f "$INDEX_DIR/external-$ID.tsv"

    info "repositorio eliminado."
}

repo_list() {
    [ -s "$REPOS_FILE" ] || {
        info "no hay repositorios comunitarios o externos."
        return 0
    }

    printf '%s\n' "Repositorios configurados:"

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        [ -n "$LINE" ] || continue

        if read_repo_line "$LINE"; then
            printf '  [%s] %s\n' "$LINE_TIER" "$LINE_URL"
        else
            printf '  [inválido] %s\n' "$LINE"
        fi
    done < "$REPOS_FILE"
}

validate_index() {
    FILE=$1

    awk -F '\t' '
        BEGIN {
            valid = 1
        }

        {
            if (NF != 8) {
                valid = 0
                exit
            }

            if ($1 !~ /^[A-Za-z0-9._+-]+$/) {
                valid = 0
                exit
            }

            if ($2 !~ /^[A-Za-z0-9._+-]+$/) {
                valid = 0
                exit
            }

            if ($3 !~ /^[A-Za-z0-9._+-]+$/) {
                valid = 0
                exit
            }

            if ($4 !~ /^[A-Za-z0-9._+-]+$/) {
                valid = 0
                exit
            }

            if ($5 !~ /^[0-9a-fA-F]+$/ || length($5) != 64) {
                valid = 0
                exit
            }

            if ($6 !~ /^[A-Za-z0-9._+-]+$/) {
                valid = 0
                exit
            }

            if ($7 !~ /^https:\/\//) {
                valid = 0
                exit
            }

            if ($8 ~ /[\t\r\n]/) {
                valid = 0
                exit
            }
        }

        END {
            if (NR == 0 || !valid) {
                exit 1
            }
        }
    ' "$FILE"
}

repo_sync() {
    command -v curl >/dev/null 2>&1 || {
        error "curl es necesario para descargar índices."
        exit 1
    }

    command -v sha256sum >/dev/null 2>&1 || {
        error "sha256sum es necesario."
        exit 1
    }

    [ -s "$REPOS_FILE" ] || {
        error "no hay repositorios configurados."
        exit 1
    }

    SUCCESS=0
    FAILED=0

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        [ -n "$LINE" ] || continue

        if ! read_repo_line "$LINE"; then
            error "entrada inválida en repos.list: $LINE"
            FAILED=$((FAILED + 1))
            continue
        fi

        URL=$LINE_URL
        TIER=$LINE_TIER
        ID=$(repo_id "$URL")

        DEST="$INDEX_DIR/$TIER-$ID.tsv"
        TEMP="$INDEX_DIR/.$TIER-$ID.tmp"

        info "sincronizando [$TIER] $URL"

        rm -f "$TEMP"

        if curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --proto '=https' \
            --proto-redir '=https' \
            --tlsv1.2 \
            --connect-timeout 15 \
            --max-time 120 \
            --max-filesize 104857600 \
            "$URL/index.tsv" \
            -o "$TEMP"
        then
            if validate_index "$TEMP"; then
                chmod 600 "$TEMP"
                mv -f "$TEMP" "$DEST"
                info "índice actualizado: $DEST"
                SUCCESS=$((SUCCESS + 1))
            else
                rm -f "$TEMP"
                error "índice inválido. Se conserva el anterior."
                FAILED=$((FAILED + 1))
            fi
        else
            rm -f "$TEMP"
            error "falló la descarga. Se conserva el índice anterior."
            FAILED=$((FAILED + 1))
        fi
    done < "$REPOS_FILE"

    printf '\n'
    info "sincronización terminada."
    info "correctos: $SUCCESS"
    info "fallidos: $FAILED"

    [ "$SUCCESS" -gt 0 ] || return 1
}

repo_candidates() {
    PACKAGE=${1:-}

    [ -n "$PACKAGE" ] || {
        error "falta el nombre del paquete."
        exit 2
    }

    case "$PACKAGE" in
        *[!A-Za-z0-9._+-]*)
            error "nombre de paquete inválido."
            exit 2
            ;;
    esac

    FOUND=0

    # Community candidates have priority over external candidates.
    for TIER in community external; do
        for INDEX in "$INDEX_DIR/$TIER-"*.tsv; do
            [ -f "$INDEX" ] || continue
            [ ! -L "$INDEX" ] || continue

            if awk -F '\t' -v package="$PACKAGE" '
                $1 == package {
                    print
                    found = 1
                }

                END {
                    if (!found) exit 1
                }
            ' "$INDEX"; then
                FOUND=1
            fi
        done
    done

    if [ "$FOUND" -eq 0 ]; then
        info "no se encontraron candidatos para $PACKAGE."
        return 1
    fi
}

ACTION=${1:-}
PARAM=${2:-}
EXTRA=${3:-}

case "$ACTION" in
    add|agregar)
        [ "$#" -le 3 ] || {
            usage
            exit 2
        }
        repo_add "$PARAM" "$EXTRA"
        ;;

    remove|eliminar)
        [ "$#" -eq 2 ] || {
            usage
            exit 2
        }
        repo_remove "$PARAM"
        ;;

    list|listar)
        [ "$#" -eq 1 ] || {
            usage
            exit 2
        }
        repo_list
        ;;

    sync|update)
        [ "$#" -eq 1 ] || {
            usage
            exit 2
        }
        repo_sync
        ;;

    candidates|buscar)
        [ "$#" -eq 2 ] || {
            usage
            exit 2
        }
        repo_candidates "$PARAM"
        ;;

    *)
        usage
        exit 2
        ;;
esac
