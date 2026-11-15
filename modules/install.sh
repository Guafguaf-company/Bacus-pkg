
#!/bin/sh
#
# BACUSP - Universal Package Installer
# BP v1 + multiplatform directory variants
# POSIX shell / Python 3
#

set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY="$SCRIPT_DIR/verify.sh"

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
APP_ROOT="$BACUSP_HOME/apps"

usage() {
    cat <<'EOF'
Bacus-Pkg - Instalador universal

Uso:
  bacusp install ARCHIVO.bp
  bacusp install ARCHIVO.deb
  bacusp install ARCHIVO.rpm
  bacusp install ARCHIVO.apk
  bacusp install ARCHIVO.pkg.tar.zst
  bacusp install NOMBRE

Los paquetes BP multiplataforma instalan solamente la variante
compatible con el sistema y la arquitectura actuales.
EOF
}

error() {
    printf 'Error: %s\n' "$*" >&2
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

is_root() {
    [ "$(id -u)" -eq 0 ]
}

run_native() {
    if is_root; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        error "se necesitan permisos de administrador"
        exit 1
    fi
}

# --------------------------------------------------
# 1. BP package installation
# --------------------------------------------------

case "$INPUT" in
    *.bp)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "se requiere un archivo BP regular"
            exit 1
        }

        [ -f "$VERIFY" ] || {
            error "falta modules/verify.sh"
            exit 1
        }

        command -v python3 >/dev/null 2>&1 || {
            error "se necesita Python 3"
            exit 1
        }

        # Verify before extracting.
        if ! sh "$VERIFY" "$INPUT"; then
            error "el paquete BP no pasó la verificación"
            exit 1
        fi

        mkdir -p "$APP_ROOT"
        chmod 700 "$BACUSP_HOME" "$APP_ROOT" 2>/dev/null || :

        exec python3 - "$INPUT" "$APP_ROOT" <<'PY'
import os
import sys
import re
import struct
import hashlib
import tempfile
import shutil
import platform
from urllib.parse import unquote_to_bytes

HEADER = struct.Struct("<8sIIIQQQ")
ENTRY = struct.Struct("<IB3sQQQ32s")
MAGIC = b"BACUSBP1"
FORMAT_VERSION = 0x00010000
CHUNK = 1024 * 1024

def fail(message):
    raise SystemExit("Error: " + message)

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

    if any(part in ("", ".", "..") for part in path.split("/")):
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
        "package_name", "version", "description",
        "target_os", "target_arch", "payload_format",
        "entrypoint", "file_count"
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

    if count < 0:
        fail("file_count negativo")

    return result, count

def check_target(manifest):
    target_os = manifest["target_os"].lower()
    target_arch = manifest["target_arch"].lower()
    current_os = sys.platform.lower()
    machine = platform.machine().lower()

    allowed_os = ("any", "unix", "linux", "debian", "chiquios")

    if target_os not in allowed_os:
        fail("sistema objetivo no compatible: " + target_os)

    if target_os == "linux" and not current_os.startswith("linux"):
        fail("este paquete requiere Linux")

    if target_os == "debian" and not (
        current_os.startswith("linux")
        and os.path.exists("/etc/debian_version")
    ):
        fail("este paquete requiere Debian o derivado compatible")

    aliases = {
        "any": ("any",),
        "amd64": ("x86_64", "amd64"),
        "x86_64": ("x86_64", "amd64"),
        "i386": ("i386", "i486", "i586", "i686", "x86"),
        "i486": ("i386", "i486", "i586", "i686", "x86"),
        "i586": ("i386", "i486", "i586", "i686", "x86"),
        "i686": ("i386", "i486", "i586", "i686", "x86"),
        "x86": ("i386", "i486", "i586", "i686", "x86"),
        "arm64": ("aarch64", "arm64"),
        "aarch64": ("aarch64", "arm64"),
        "armhf": ("armv7l", "armhf"),
        "armv7l": ("armv7l", "armhf"),
        "riscv64": ("riscv64",),
        "ppc64el": ("ppc64le", "ppc64el"),
        "ppc64le": ("ppc64le", "ppc64el"),
    }

    if target_arch != "any":
        compatible = aliases.get(target_arch, (target_arch,))
        if machine not in compatible:
            fail(
                "arquitectura incompatible: paquete "
                + target_arch + ", sistema " + (machine or "desconocido")
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
        fail("no se pudo identificar el sistema y la arquitectura")

    return os_name + arch_name

def select_variant(manifest, records):
    variants = {
        item for item in manifest.get("variants", "").split(",")
        if item
    }

    if not variants:
        # Legacy BP 1.0 package: keep its original layout.
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

def main():
    package = os.path.abspath(sys.argv[1])
    app_root = os.path.realpath(sys.argv[2])

    if not os.path.isfile(package) or os.path.islink(package):
        fail("archivo de paquete inválido")

    stage = None

    try:
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

            check_target(manifest)

            destination = os.path.join(app_root, name, version)

            if os.path.lexists(destination):
                fail("el paquete o la versión ya existen: " + destination)

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

            # Select platform-specific files before extraction.
            records = select_variant(manifest, records)

            # Reject file/directory conflicts.
            kinds = {path: kind for path, kind, *_ in records}

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

            payload_start = HEADER.size + msize + tsize

            stage = tempfile.mkdtemp(prefix=".bp-stage-", dir=app_root)

            for path, kind, offset, stored, expected_digest in records:
                target = os.path.abspath(
                    os.path.join(stage, *path.split("/"))
                )

                if os.path.commonpath((stage, target)) != stage:
                    fail("ruta fuera del directorio temporal")

                if kind == 1:
                    os.makedirs(target, mode=0o755, exist_ok=True)
                    continue

                os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)

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

                if digest.digest() != expected_digest:
                    fail("SHA-256 incorrecto: " + path)

                os.chmod(target, 0o755 if entrypoint == path else 0o644)

            os.makedirs(os.path.dirname(destination), mode=0o755, exist_ok=True)
            os.rename(stage, destination)
            stage = None

            print("Instalación BP completada.")
            print("Paquete:", name)
            print("Versión:", version)
            print("Entradas instaladas:", len(records))
            print("Directorio:", destination)
            print("Aviso: SHA-256 verifica integridad, no autenticidad.")

    finally:
        if stage and os.path.isdir(stage):
            shutil.rmtree(stage, ignore_errors=True)

try:
    main()
except (OSError, OverflowError, struct.error, ValueError) as exc:
    fail(str(exc))
PY
        ;;

esac

# --------------------------------------------------
# 2. Native package installation
# --------------------------------------------------

case "$INPUT" in
    *.deb)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "archivo .deb no encontrado o inválido"
            exit 1
        }

        printf 'Se instalará un paquete nativo. ¿Continuar? Escribí SI: '
        IFS= read -r ANSWER || exit 2
        case "$ANSWER" in SI|YES) ;; *) exit 0 ;; esac

        if command -v apt-get >/dev/null 2>&1; then
            run_native apt-get install -y "./$INPUT"
        elif command -v dpkg >/dev/null 2>&1; then
            run_native dpkg -i "$INPUT"
        else
            error "se necesita apt-get o dpkg"
            exit 1
        fi
        exit 0
        ;;

    *.rpm)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "archivo .rpm no encontrado o inválido"
            exit 1
        }

        printf 'Se instalará un paquete nativo. ¿Continuar? Escribí SI: '
        IFS= read -r ANSWER || exit 2
        case "$ANSWER" in SI|YES) ;; *) exit 0 ;; esac

        if command -v dnf >/dev/null 2>&1; then
            run_native dnf install -y "$INPUT"
        elif command -v zypper >/dev/null 2>&1; then
            run_native zypper --non-interactive install "$INPUT"
        elif command -v yum >/dev/null 2>&1; then
            run_native yum install -y "$INPUT"
        else
            error "se necesita dnf, zypper o yum"
            exit 1
        fi
        exit 0
        ;;

    *.apk)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "archivo .apk no encontrado o inválido"
            exit 1
        }

        printf 'Se instalará un paquete nativo. ¿Continuar? Escribí SI: '
        IFS= read -r ANSWER || exit 2
        case "$ANSWER" in SI|YES) ;; *) exit 0 ;; esac

        command -v apk >/dev/null 2>&1 || {
            error "se necesita apk"
            exit 1
        }

        run_native apk add -- "$INPUT"
        exit 0
        ;;

    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz)
        [ -f "$INPUT" ] && [ ! -L "$INPUT" ] || {
            error "paquete de Arch no encontrado o inválido"
            exit 1
        }

        printf 'Se instalará un paquete nativo. ¿Continuar? Escribí SI: '
        IFS= read -r ANSWER || exit 2
        case "$ANSWER" in SI|YES) ;; *) exit 0 ;; esac

        command -v pacman >/dev/null 2>&1 || {
            error "se necesita pacman"
            exit 1
        }

        run_native pacman -U -- "$INPUT"
        exit 0
        ;;
esac

# --------------------------------------------------
# 3. Install by package name using system manager
# --------------------------------------------------

case "$INPUT" in
    */*|*://*)
        error "indica un nombre de paquete o archivo local"
        exit 2
        ;;
esac

# Termux
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    exec "${PREFIX}/bin/pkg" install "$INPUT"
fi

if command -v apt-get >/dev/null 2>&1; then
    exec sh -c '
        if [ "$(id -u)" -eq 0 ]; then
            exec apt-get install -y -- "$1"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo apt-get install -y -- "$1"
        else
            echo "Error: se necesita root o sudo." >&2
            exit 1
        fi
    ' sh "$INPUT"
fi

if command -v dnf >/dev/null 2>&1; then
    exec sh -c '
        if [ "$(id -u)" -eq 0 ]; then
            exec dnf install -y "$1"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo dnf install -y "$1"
        else
            echo "Error: se necesita root o sudo." >&2
            exit 1
        fi
    ' sh "$INPUT"
fi

if command -v zypper >/dev/null 2>&1; then
    exec sh -c '
        if [ "$(id -u)" -eq 0 ]; then
            exec zypper install "$1"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo zypper install "$1"
        else
            echo "Error: se necesita root o sudo." >&2
            exit 1
        fi
    ' sh "$INPUT"
fi

if command -v apk >/dev/null 2>&1; then
    exec sh -c '
        if [ "$(id -u)" -eq 0 ]; then
            exec apk add "$1"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo apk add "$1"
        else
            echo "Error: se necesita root o sudo." >&2
            exit 1
        fi
    ' sh "$INPUT"
fi

if command -v pacman >/dev/null 2>&1; then
    exec sh -c '
        if [ "$(id -u)" -eq 0 ]; then
            exec pacman -S --needed "$1"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo pacman -S --needed "$1"
        else
            echo "Error: se necesita root o sudo." >&2
            exit 1
        fi
    ' sh "$INPUT"
fi

error "no se detectó un gestor de paquetes compatible"
printf '%s\n' \
    "Bacus-Pkg necesita un adaptador específico para este sistema."
exit 3
