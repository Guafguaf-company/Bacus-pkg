
#!/bin/sh
# BACUSP 7.6 - Independent Repository Engine
# Native package managers are never used.

set -eu
umask 077

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
REPOS_FILE="$BACUSP_HOME/repos.list"
INDEX_DIR="$BACUSP_HOME/repositories"

mkdir -p "$BACUSP_HOME" "$INDEX_DIR"
chmod 700 "$BACUSP_HOME" "$INDEX_DIR" 2>/dev/null || :

usage() {
    cat <<'EOF'
BACUSP Repository Engine

Usage:
  bacusp repo add URL
  bacusp repo remove URL
  bacusp repo list
  bacusp repo sync
  bacusp repo candidates PACKAGE

Repository format:
  URL/index.tsv

Index format: one package per line, tab-separated:
  name version architecture os sha256 filename url dependencies

Example:
  btop 1.4.5 x86_64 linux HASH btop.bp packages/btop.bp -

The index must be hosted over HTTPS.
EOF
}

valid_url() {
    case "$1" in
        https://*) return 0 ;;
        *) return 1 ;;
    esac
}

repo_add() {
    URL=${1:-}
    [ -n "$URL" ] || {
        echo "Error: falta la URL."
        exit 2
    }

    valid_url "$URL" || {
        echo "Error: BACUSP requiere HTTPS."
        exit 2
    }

    touch "$REPOS_FILE"

    if grep -Fqx "$URL" "$REPOS_FILE"; then
        echo "El repositorio ya existe."
        exit 0
    fi

    printf '%s\n' "$URL" >> "$REPOS_FILE"
    echo "Repositorio agregado: $URL"
}

repo_remove() {
    URL=${1:-}
    [ -n "$URL" ] || {
        echo "Error: falta la URL."
        exit 2
    }

    [ -f "$REPOS_FILE" ] || exit 0

    TMP="$BACUSP_HOME/repos.tmp"
    grep -Fvx "$URL" "$REPOS_FILE" > "$TMP" || :
    mv "$TMP" "$REPOS_FILE"

    echo "Repositorio eliminado."
}

repo_list() {
    if [ ! -s "$REPOS_FILE" ]; then
        echo "No hay repositorios configurados."
        return
    fi

    echo "Repositorios BACUSP:"
    cat "$REPOS_FILE"
}

repo_sync() {
    command -v curl >/dev/null 2>&1 || {
        echo "Error: se necesita curl para descargar índices."
        exit 1
    }

    [ -s "$REPOS_FILE" ] || {
        echo "No hay repositorios configurados."
        exit 1
    }

    number=0

    while IFS= read -r URL; do
        [ -n "$URL" ] || continue

        case "$URL" in
            https://*) ;;
            *)
                echo "Repositorio rechazado: HTTPS obligatorio."
                continue
                ;;
        esac

        number=$((number + 1))
        DEST="$INDEX_DIR/$number.tsv"
        TEMP="$DEST.tmp"

        echo "Sincronizando: $URL"

        if curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --proto '=https' \
            --tlsv1.2 \
            --max-time 60 \
            "$URL/index.tsv" \
            -o "$TEMP"
        then
            if awk -F '\t' '
                NF != 8 { exit 1 }
                $1 !~ /^[A-Za-z0-9._+-]+$/ { exit 1 }
                $2 !~ /^[A-Za-z0-9._+-]+$/ { exit 1 }
                $3 !~ /^[A-Za-z0-9._+-]+$/ { exit 1 }
                $4 !~ /^[A-Za-z0-9._+-]+$/ { exit 1 }
                $5 !~ /^[0-9a-fA-F]+$/ { exit 1 }
                $6 !~ /^[A-Za-z0-9._+-]+$/ { exit 1 }
                $7 !~ /^https:\/\// { exit 1 }
                END { if (NR == 0) exit 1 }
            ' "$TEMP"
            then
                mv "$TEMP" "$DEST"
                echo "Índice descargado: $DEST"
            else
                rm -f "$TEMP"
                echo "Índice inválido; se conserva el anterior."
            fi
        else
            rm -f "$TEMP"
            echo "No se pudo actualizar: $URL"
        fi
    done < "$REPOS_FILE"
}

repo_candidates() {
    PACKAGE=${1:-}

    [ -n "$PACKAGE" ] || {
        echo "Error: falta el nombre del paquete."
        exit 2
    }

    FOUND=0

    for INDEX in "$INDEX_DIR"/*.tsv; do
        [ -f "$INDEX" ] || continue

        awk -F '\t' -v package="$PACKAGE" '
            $1 == package {
                print
                found=1
            }
            END {
                if (!found) exit 1
            }
        ' "$INDEX" || :
    done
}

ACTION=${1:-}
PARAM=${2:-}

case "$ACTION" in
    add|agregar)
        repo_add "$PARAM"
        ;;
    remove|eliminar)
        repo_remove "$PARAM"
        ;;
    list|listar)
        repo_list
        ;;
    sync|update)
        repo_sync
        ;;
    candidates|buscar)
        repo_candidates "$PARAM"
        ;;
    *)
        usage
        exit 2
        ;;
esac
