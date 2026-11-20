
#!/bin/sh
#
# BACUSP 7.6 - Independent Package Installer
# Project: Bacus-Pkg
#
# BP v1 installer + independent repository resolver.
# No APT, DNF, Pacman, APK, dpkg, rpm or external package managers.
#

set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

VERIFY="$SCRIPT_DIR/verify.sh"
REPO="$SCRIPT_DIR/repo.sh"
DEPS="$SCRIPT_DIR/deps.sh"

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
APP_ROOT="$BACUSP_HOME/apps"
CACHE_ROOT="$BACUSP_HOME/cache"
DB_FILE="$BACUSP_HOME/installed.db"

CHUNK_SIZE=1048576

usage() {
    cat <<'EOF'
BACUSP 7.6 - Independent Package Installer

Usage:
  bacusp install PACKAGE
  bacusp install FILE.bp

Examples:
  bacusp install btop
  bacusp install ./btop.bp

Independent engine:
  - Repository index synchronization
  - Automatic dependency resolution
  - Direct HTTPS downloads
  - SHA-256 verification
  - BP package verification
  - Version and dependency registration

Supported installation format:
  BP v1

Native package formats are not delegated to system package managers.
EOF
}

error() {
    printf 'BACUSP install: ERROR: %s\n' "$*" >&2
}

info() {
    printf 'BACUSP install: %s\n' "$*"
}

valid_name() {
    case "$1" in
        ""|.|..|*[!A-Za-z0-9._+-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        error "falta la herramienta requerida: $1"
        exit 1
    }
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

INPUT=$1

case "$INPUT" in
    ""|-*)
        error "nombre o ruta inválidos"
        exit 2
        ;;
esac

require_command python3

mkdir -p "$BACUSP_HOME" "$APP_ROOT" "$CACHE_ROOT"
chmod 700 "$BACUSP_HOME" "$CACHE_ROOT" 2>/dev/null || :

[ -f "$VERIFY" ] || {
    error "falta modules/verify.sh"
    exit 1
}

install_bp() {
    PACKAGE_FILE=$1
    EXPECTED_NAME=${2:-}
    EXPECTED_VERSION=${3:-}

    [ -f "$PACKAGE_FILE" ] && [ ! -L "$PACKAGE_FILE" ] || {
        error "el archivo BP no es regular o no existe"
        return 1
    }

    info "verificando estructura e integridad BP..."

    if ! sh "$VERIFY" "$PACKAGE_FILE"; then
        error "el paquete no superó verify.sh"
        return 1
    fi

    python3 - \
        "$PACKAGE_FILE" \
        "$APP_ROOT" \
        "$DB_FILE" \
        "$EXPECTED_NAME" \
        "$EXPECTED_VERSION" <<'PY'
import os
import sys
import re
import struct
import hashlib
import tempfile
import shutil
import platform
from urllib.parse import unquote_to_bytes

package = os.path.abspath(sys.argv[1])
app_root = os.path.realpath(sys.argv[2])
db_file = os.path.abspath(sys.argv[3])
expected_name = sys.argv[4]
expected_version = sys.argv[5]

HEADER = struct.Struct("<8sIIIQQQ")
ENTRY = struct.Struct("<IB3sQQQ32s")

MAGIC = b"BACUSBP1"
FORMAT_VERSION = 0x00010000
CHUNK = 1024 * 1024

def fail(message):
    raise SystemExit("BACUSP install: ERROR: " + message)

def exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        fail("paquete truncado")
    return data

def safe_component(value, label):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", value):
        fail(label + " contiene caracteres no permitidos")
    if value in (".", ".."):
        fail(label + " inválido")
    return value

def safe_path(raw):
    try:
        path = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("ruta no válida en UTF-8")

    if (
        not path
        or path.startswith("/")
        or "\\" in path
        or "\x00" in path
        or re.match(r"^[A-Za-z]:", path)
    ):
        fail("ruta insegura")

    parts = path.split("/")

    if any(part in ("", ".", "..") for part in parts):
        fail("ruta insegura: " + path)

    return path

def parse_manifest(data):
    if not data.endswith(b"\n") or b"\r" in data or b"\x00" in data:
        fail("formato de manifiesto inválido")

    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        fail("manifiesto no válido en UTF-8")

    result = {}

    for line in lines:
        if not line or "=" not in line:
            fail("línea de manifiesto inválida")

        key, value = line.split("=", 1)

        if not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            fail("clave de manifiesto inválida")

        if key in result:
            fail("clave duplicada: " + key)

        if re.search(r"%(?![0-9A-Fa-f]{2})", value):
            fail("escape porcentual inválido")

        try:
            decoded = unquote_to_bytes(value).decode("utf-8")
        except (UnicodeDecodeError, ValueError):
            fail("valor de manifiesto inválido")

        result[key] = decoded

    required = (
        "package_name",
        "version",
        "description",
        "target_os",
        "target_arch",
        "payload_format",
        "entrypoint",
        "file_count",
    )

    for key in required:
        if key not in result:
            fail("falta el campo " + key)

    if result["payload_format"] != "raw-v1":
        fail("formato de payload no compatible")

    try:
        count = int(result["file_count"], 10)
    except ValueError:
        fail("file_count inválido")

    if count < 0 or count > 1000000:
        fail("cantidad de archivos inválida")

    return result, count

def check_target(manifest):
    target_os = manifest["target_os"].lower()
    target_arch = manifest["target_arch"].lower()

    system = platform.system().lower()
    machine = platform.machine().lower()

    allowed_os = {
        "any",
        "unix",
        "linux",
        "debian",
        "chiquios",
        "macos",
        "freebsd",
        "openbsd",
        "netbsd",
    }

    if target_os not in allowed_os:
        fail("sistema objetivo no admitido: " + target_os)

    if target_os == "unix":
        if system not in ("linux", "darwin", "freebsd", "openbsd", "netbsd"):
            fail("el paquete requiere un sistema Unix")

    elif target_os == "linux" and system != "linux":
        fail("el paquete requiere Linux")

    elif target_os == "macos" and system != "darwin":
        fail("el paquete requiere macOS")

    elif target_os == "freebsd" and system != "freebsd":
        fail("el paquete requiere FreeBSD")

    elif target_os == "openbsd" and system != "openbsd":
        fail("el paquete requiere OpenBSD")

    elif target_os == "netbsd" and system != "netbsd":
        fail("el paquete requiere NetBSD")

    elif target_os == "debian":
        if system != "linux" or not os.path.exists("/etc/debian_version"):
            fail("el paquete requiere Debian o derivado compatible")

    aliases = {
        "any": {"any"},
        "amd64": {"x86_64", "amd64"},
        "x86_64": {"x86_64", "amd64"},
        "i386": {"i386", "i486", "i586", "i686", "x86"},
        "i486": {"i386", "i486", "i586", "i686", "x86"},
        "i586": {"i386", "i486", "i586", "i686", "x86"},
        "i686": {"i386", "i486", "i586", "i686", "x86"},
        "x86": {"i386", "i486", "i586", "i686", "x86"},
        "arm64": {"aarch64", "arm64"},
        "aarch64": {"aarch64", "arm64"},
        "armhf": {"armv7l", "armhf"},
        "armv7l": {"armv7l", "armhf"},
        "armv6": {"armv6l", "arm"},
        "arm": {"armv6l", "armv7l", "arm"},
        "riscv64": {"riscv64"},
        "ppc64el": {"ppc64le", "ppc64el"},
        "ppc64le": {"ppc64le", "ppc64el"},
    }

    if target_arch != "any":
        accepted = aliases.get(target_arch, {target_arch})
        if machine not in accepted:
            fail(
                "arquitectura incompatible: paquete "
                + target_arch + ", sistema " + machine
            )

def get_variant():
    system = platform.system().lower()
    machine = platform.machine().lower()

    os_aliases = {
        "windows": "win",
        "linux": "linux",
        "darwin": "macos",
        "freebsd": "freebsd",
        "openbsd": "openbsd",
        "netbsd": "netbsd",
        "haiku": "haiku",
    }

    arch_aliases = {
        "x86_64": "x64",
        "amd64": "x64",
        "i386": "x32",
        "i486": "x32",
        "i586": "x32",
        "i686": "x32",
        "x86": "x32",
        "aarch64": "arm64",
        "arm64": "arm64",
        "armv7l": "arm",
        "armv6l": "arm",
        "arm": "arm",
        "riscv64": "riscv64",
    }

    os_name = os_aliases.get(system)
    arch_name = arch_aliases.get(machine)

    if not os_name or not arch_name:
        fail("no se pudo identificar la variante del sistema")

    return os_name + arch_name

def select_variant(manifest, records):
    variants = {
        item
        for item in manifest.get("variants", "").split(",")
        if item
    }

    if not variants:
        return records

    selected = get_variant()

    if selected not in variants:
        fail("el paquete no contiene la variante compatible: " + selected)

    filtered = []

    for path, kind, offset, stored, digest in records:
        first, separator, remainder = path.partition("/")

        if first == selected and separator:
            filtered.append(
                (remainder, kind, offset, stored, digest)
            )
        elif first == "shared" and separator:
            filtered.append(
                (path, kind, offset, stored, digest)
            )

    if not filtered:
        fail("la variante seleccionada no contiene archivos")

    print("Variante seleccionada:", selected)
    return filtered

def update_database(name, version, destination, dependencies, digest):
    os.makedirs(os.path.dirname(db_file), exist_ok=True)

    old_lines = []

    if os.path.isfile(db_file) and not os.path.islink(db_file):
        with open(db_file, "r", encoding="utf-8") as stream:
            old_lines = [
                line.rstrip("\n")
                for line in stream
                if line.strip()
            ]

    # Keep the legacy first two columns:
    # package_name|installation_path|version|dependencies|sha256
    new_lines = []

    for line in old_lines:
        fields = line.split("|")

        if fields[0] == name:
            continue

        new_lines.append(line)

    dependency_text = ",".join(dependencies) if dependencies else "-"

    new_lines.append(
        "|".join([
            name,
            destination,
            version,
            dependency_text,
            digest,
        ])
    )

    directory = os.path.dirname(db_file)
    fd, temporary = tempfile.mkstemp(
        prefix=".installed-",
        dir=directory
    )

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            for line in new_lines:
                stream.write(line + "\n")
            stream.flush()
            os.fsync(stream.fileno())

        os.replace(temporary, db_file)
        os.chmod(db_file, 0o600)

    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def main():
    if not os.path.isfile(package) or os.path.islink(package):
        fail("archivo BP inválido")

    stage = None

    with open(package, "rb") as stream:
        header = exact(stream, HEADER.size)

        magic, hsize, fmt, flags, msize, tsize, psize = HEADER.unpack(header)

        if magic != MAGIC or hsize != HEADER.size:
            fail("cabecera BP inválida")

        if fmt != FORMAT_VERSION or flags != 0:
            fail("versión BP no compatible")

        total = os.fstat(stream.fileno()).st_size

        if HEADER.size + msize + tsize + psize != total:
            fail("tamaños de sección incorrectos")

        if msize > 16 * 1024 * 1024:
            fail("manifiesto demasiado grande")

        manifest, count = parse_manifest(exact(stream, msize))

        name = safe_component(manifest["package_name"], "package_name")
        version = safe_component(manifest["version"], "version")

        if expected_name and name != expected_name:
            fail(
                "el nombre del paquete no coincide con el índice: "
                + name
            )

        if expected_version and version != expected_version:
            fail(
                "la versión del paquete no coincide con el índice: "
                + version
            )

        check_target(manifest)

        destination = os.path.join(app_root, name, version)

        if os.path.lexists(destination):
            fail("esta versión ya está instalada: " + version)

        records = []
        table_used = 0
        previous = None
        next_offset = 0
        seen = set()

        if count > tsize // (ENTRY.size + 1):
            fail("cantidad de entradas inválida")

        for _ in range(count):
            raw_entry = exact(stream, ENTRY.size)
            table_used += ENTRY.size

            plen, kind, reserved, offset, stored, original, digest = ENTRY.unpack(raw_entry)

            if plen == 0 or reserved != bytes(3) or kind not in (0, 1):
                fail("entrada inválida en la tabla")

            if plen > tsize - table_used:
                fail("longitud de ruta fuera de la tabla")

            raw_path = exact(stream, plen)
            table_used += plen

            path = safe_path(raw_path)

            if raw_path in seen:
                fail("ruta duplicada: " + path)

            if previous is not None and raw_path <= previous:
                fail("rutas desordenadas")

            seen.add(raw_path)
            previous = raw_path

            if kind == 1:
                if offset or stored or original or digest != bytes(32):
                    fail("metadatos de directorio inválidos")

            else:
                if offset != next_offset or stored != original:
                    fail("offset o tamaño inválido: " + path)

                if stored > psize - next_offset:
                    fail("archivo fuera del payload: " + path)

                next_offset += stored

            records.append((path, kind, offset, stored, digest))

        if table_used != tsize or next_offset != psize:
            fail("tabla o payload inconsistente")

        records = select_variant(manifest, records)

        kinds = {
            path: kind
            for path, kind, *_ in records
        }

        for path, kind, *_ in records:
            parts = path.split("/")

            for index in range(1, len(parts)):
                parent = "/".join(parts[:index])

                if kinds.get(parent) == 0:
                    fail("un archivo no puede ser directorio padre: " + parent)

        entrypoint = manifest["entrypoint"]

        if entrypoint:
            safe_path(entrypoint.encode("utf-8"))

            if kinds.get(entrypoint) != 0:
                fail("entrypoint no apunta a un archivo")

        dependencies = []

        raw_dependencies = manifest.get("depends", "")

        if raw_dependencies:
            for dependency in raw_dependencies.split(","):
                dependency = dependency.strip()

                if not re.fullmatch(
                    r"[A-Za-z0-9._+-]+(?:(?:>=|<=|=|>|<)[A-Za-z0-9.+-]+)?",
                    dependency
                ):
                    fail("dependencia inválida en el manifiesto: " + dependency)

                dependencies.append(dependency)

        payload_start = HEADER.size + msize + tsize

        stage = tempfile.mkdtemp(
            prefix=".bp-stage-",
            dir=app_root
        )

        for path, kind, offset, stored, expected_digest in records:
            target = os.path.abspath(
                os.path.join(stage, *path.split("/"))
            )

            if os.path.commonpath((stage, target)) != stage:
                fail("ruta fuera del directorio temporal")

            if kind == 1:
                os.makedirs(target, mode=0o755, exist_ok=True)
                continue

            os.makedirs(
                os.path.dirname(target),
                mode=0o755,
                exist_ok=True
            )

            stream.seek(payload_start + offset)
            remaining = stored
            digest = hashlib.sha256()

            with open(target, "xb") as output:
                while remaining:
                    block = stream.read(min(CHUNK, remaining))

                    if not block:
                        fail("payload truncado: " + path)

                    digest.update(block)
                    output.write(block)
                    remaining -= len(block)

                output.flush()
                os.fsync(output.fileno())

            if digest.digest() != expected_digest:
                fail("SHA-256 incorrecto: " + path)

            os.chmod(
                target,
                0o755 if entrypoint == path else 0o644
            )

        os.makedirs(
            os.path.dirname(destination),
            mode=0o755,
            exist_ok=True
        )

        # Atomic publication of the extracted version.
        os.rename(stage, destination)
        stage = None

        package_digest = hashlib.sha256()

        with open(package, "rb") as stream:
            for block in iter(lambda: stream.read(CHUNK), b""):
                package_digest.update(block)

        update_database(
            name,
            version,
            destination,
            dependencies,
            package_digest.hexdigest()
        )

        print("Instalación completada.")
        print("Paquete:", name)
        print("Versión:", version)
        print("Dependencias declaradas:", len(dependencies))
        print("Directorio:", destination)

    if stage and os.path.isdir(stage):
        shutil.rmtree(stage, ignore_errors=True)

try:
    main()
except (OSError, OverflowError, struct.error, ValueError) as exc:
    fail(str(exc))
PY
}

# --------------------------------------------------
# 1. Local BP package
# --------------------------------------------------

case "$INPUT" in
    *.bp)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "archivo BP local inválido"
            exit 1
        }

        install_bp "$INPUT"
        exit $?
        ;;
esac

# --------------------------------------------------
# 2. Independent repository installation
# --------------------------------------------------

case "$INPUT" in
    */*|*://*|*.deb|*.rpm|*.apk|*.pkg.tar.*)
        error "ruta o formato no admitido"
        exit 2
        ;;
esac

valid_name "$INPUT" || {
    error "nombre de paquete inválido"
    exit 2
}

[ -f "$REPO" ] || {
    error "falta modules/repo.sh"
    exit 1
}

[ -f "$DEPS" ] || {
    error "falta modules/deps.sh"
    exit 1
}

require_command curl

TMP_DIR=$(mktemp -d "$BACUSP_HOME/install.XXXXXX") || {
    error "no se pudo crear el directorio temporal"
    exit 1
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

PLAN="$TMP_DIR/plan.tsv"

info "sincronizando índices BACUSP..."

if ! sh "$REPO" sync; then
    error "no se pudieron sincronizar los repositorios"
    exit 1
fi

info "resolviendo dependencias de $INPUT..."

if ! sh "$DEPS" resolve "$INPUT" > "$PLAN"; then
    error "no se pudo resolver el árbol completo"
    exit 1
fi

[ -s "$PLAN" ] || {
    error "el resolvedor no generó un plan"
    exit 1
}

# --------------------------------------------------
# 3. Download and verify every package first
# --------------------------------------------------

TAB=$(printf '\t')
COUNT=0

while IFS="$TAB" read -r NAME VERSION ARCH OS_NAME SHA256 FILENAME URL DEPENDENCIES
do
    [ -n "$NAME" ] || continue

    valid_name "$NAME" || {
        error "nombre inválido en el plan"
        exit 1
    }

    valid_name "$VERSION" || {
        error "versión inválida en el plan"
        exit 1
    }

    case "$FILENAME" in
        *.bp) ;;
        *)
            error "BACUSP 7.6 solo instala BP: $FILENAME"
            exit 1
            ;;
    esac

    case "$SHA256" in
        *[!0-9a-fA-F]*|"")
            error "hash SHA-256 inválido para $NAME"
            exit 1
            ;;
    esac

    [ "${#SHA256}" -eq 64 ] || {
        error "longitud SHA-256 inválida para $NAME"
        exit 1
    }

    case "$URL" in
        https://*) ;;
        *)
            error "URL de descarga insegura para $NAME"
            exit 1
            ;;
    esac

    PACKAGE_FILE="$TMP_DIR/$COUNT.bp"

    info "descargando $NAME $VERSION..."

    if ! curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --max-time 180 \
        "$URL" \
        -o "$PACKAGE_FILE"
    then
        error "falló la descarga de $NAME"
        exit 1
    fi

    if ! python3 - "$PACKAGE_FILE" "$SHA256" <<'PY'
import sys
import hashlib

path, expected = sys.argv[1:3]
digest = hashlib.sha256()

with open(path, "rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)

if digest.hexdigest().lower() != expected.lower():
    print("Error: SHA-256 incorrecto.", file=sys.stderr)
    raise SystemExit(1)
PY
    then
        error "integridad incorrecta para $NAME"
        exit 1
    fi

    info "verificando formato BP de $NAME..."

    if ! sh "$VERIFY" "$PACKAGE_FILE"; then
        error "el paquete $NAME no pasó verify.sh"
        exit 1
    fi

    COUNT=$((COUNT + 1))
done < "$PLAN"

[ "$COUNT" -gt 0 ] || {
    error "el plan no contiene paquetes"
    exit 1
}

# --------------------------------------------------
# 4. Install in dependency order
# --------------------------------------------------

info "todos los paquetes fueron descargados y verificados"
info "comenzando instalación en orden de dependencias"

INDEX=0

while IFS="$TAB" read -r NAME VERSION ARCH OS_NAME SHA256 FILENAME URL DEPENDENCIES
do
    [ -n "$NAME" ] || continue

    PACKAGE_FILE="$TMP_DIR/$INDEX.bp"

    info "instalando $NAME $VERSION..."

    if ! install_bp "$PACKAGE_FILE" "$NAME" "$VERSION"; then
        error "no se pudo instalar $NAME"
        error "la instalación de paquetes anteriores no se revierte automáticamente"
        exit 1
    fi

    INDEX=$((INDEX + 1))
done < "$PLAN"

printf '\n'
info "instalación finalizada correctamente"
info "paquetes procesados: $COUNT"
info "motor: BACUSP independiente"
info "registro: $DB_FILE"

exit 0

