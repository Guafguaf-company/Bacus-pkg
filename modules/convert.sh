
#!/bin/sh
# BACUSP - Multiplatform BP Converter
# Creates BP v1 packages with directory-based platform variants.
# Does not translate executable code.

set -eu
umask 077

err() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Uso:
  bacusp convert [--portable] [--target PLATAFORMA] ORIGEN [DESTINO.bp]

Ejemplos:
  bacusp convert programa.exe
  bacusp convert --target linuxarm64 programa
  bacusp convert --portable carpeta-multiplataforma/ paquete.bp
EOF
}

PORTABLE=0
TARGET=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --portable|-portable)
            PORTABLE=1
            shift
            ;;
        --target)
            [ "$#" -ge 2 ] || err "Falta el destino."
            TARGET=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            err "Opción desconocida: $1"
            ;;
        *)
            break
            ;;
    esac
done

SOURCE=${1:-}
[ -n "$SOURCE" ] || { usage >&2; exit 2; }
shift

DESTINATION=${1:-}
shift || true
[ "$#" -eq 0 ] || err "Demasiados argumentos."

[ -e "$SOURCE" ] || err "El origen no existe."
[ ! -L "$SOURCE" ] || err "No se admiten enlaces simbólicos."
command -v python3 >/dev/null 2>&1 || err "Se necesita Python 3."

exec python3 - "$SOURCE" "$DESTINATION" "$PORTABLE" "$TARGET" <<'PY'
import os
import sys
import re
import stat
import hashlib
import struct
import tempfile
import shutil
from pathlib import Path

source = Path(sys.argv[1]).absolute()
destination_arg = sys.argv[2]
portable = sys.argv[3] == "1"
requested_target = sys.argv[4].lower()

MAGIC = b"BACUSBP1"
VERSION = 0x00010000
HEADER = struct.Struct("<8sIIIQQQ")
ENTRY = struct.Struct("<IB3sQQQ32s")
CHUNK = 1024 * 1024

VARIANTS = {
    "winx64": ("windows", "x86_64"),
    "winx32": ("windows", "x86"),
    "winarm64": ("windows", "aarch64"),
    "winarm": ("windows", "arm"),
    "linuxx64": ("linux", "x86_64"),
    "linuxx32": ("linux", "x86"),
    "linuxarm64": ("linux", "aarch64"),
    "linuxarm": ("linux", "arm"),
    "linuxriscv64": ("linux", "riscv64"),
    "macosx64": ("macos", "x86_64"),
    "macosarm64": ("macos", "aarch64"),
    "freebsdx64": ("freebsd", "x86_64"),
    "freebsdx32": ("freebsd", "x86"),
    "freebsdarm64": ("freebsd", "aarch64"),
    "openbsdx64": ("openbsd", "x86_64"),
    "openbsdarm64": ("openbsd", "aarch64"),
    "netbsdx64": ("netbsd", "x86_64"),
    "netbsdx32": ("netbsd", "x86"),
    "freedosx86": ("freedos", "x86"),
    "freertos": ("freertos", "any"),
    "haikux64": ("haiku", "x86_64"),
    "haikuarm64": ("haiku", "aarch64"),
    "kolibriosx86": ("kolibrios", "x86"),
}

def fail(message):
    raise SystemExit("ERROR: " + message)

def safe_name(value):
    value = re.sub(r"[^A-Za-z0-9._+-]", "-", value)
    return value.strip(".-+") or "imported-package"

def encode_value(value):
    allowed = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-/"
    result = []
    for byte in value.encode("utf-8"):
        if byte in allowed:
            result.append(chr(byte))
        else:
            result.append("%%%02X" % byte)
    return "".join(result)

def detect_target(path):
    with path.open("rb") as stream:
        data = stream.read(4096)

    # Windows PE executable
    if data.startswith(b"MZ") and len(data) >= 64:
        offset = struct.unpack_from("<I", data, 60)[0]
        if offset + 6 <= len(data) and data[offset:offset+4] == b"PE\0\0":
            machine = struct.unpack_from("<H", data, offset+4)[0]
            return {
                0x8664: "winx64",
                0x014c: "winx32",
                0xAA64: "winarm64",
                0x01c4: "winarm",
            }.get(machine)

    # ELF executable: Linux is the default assumption.
    if data.startswith(b"\x7fELF") and len(data) >= 20:
        elf_class = data[4]
        machine = struct.unpack_from("<H", data, 18)[0]
        if machine == 3:
            return "linuxx32" if elf_class == 1 else "linuxx64"
        if machine == 40:
            return "linuxarm"
        if machine == 183:
            return "linuxarm64"
        if machine == 243:
            return "linuxriscv64"

    return None

def collect(root, prefix=""):
    result = []

    for item in sorted(root.iterdir(), key=lambda p: p.name.encode("utf-8")):
        if item.is_symlink():
            fail("No se admiten enlaces simbólicos: " + str(item))

        if item.name in ("", ".", "..") or "\\" in item.name:
            fail("Nombre de archivo inválido: " + item.name)

        relative = (prefix + "/" + item.name).lstrip("/")
        mode = item.stat(follow_symlinks=False).st_mode

        if stat.S_ISDIR(mode):
            result.append((relative, 1, item))
            result.extend(collect(item, relative))
        elif stat.S_ISREG(mode):
            result.append((relative, 0, item))
        else:
            fail("Tipo de archivo no admitido: " + str(item))

    return result

if source.is_symlink() or not source.exists():
    fail("Origen inválido.")

name = safe_name(source.stem if source.is_file() else source.name)

if destination_arg:
    destination = Path(destination_arg).absolute()
else:
    destination = source.with_name(name + ".bp")

if destination.suffix.lower() != ".bp":
    fail("El destino debe terminar en .bp.")
if destination == source:
    fail("Origen y destino no pueden ser iguales.")
if destination.exists() or destination.is_symlink():
    fail("El destino ya existe.")
if not destination.parent.is_dir():
    fail("La carpeta de destino no existe.")

records = []
found = []

if source.is_file():
    if source.suffix.lower() in (".deb", ".rpm", ".msi", ".apk"):
        fail("Este formato necesita un adaptador específico de extracción.")

    target = requested_target or detect_target(source)

    if target not in VARIANTS:
        fail("No se pudo detectar la plataforma. Usá --target.")

    found = [target]
    records.append((target, 1, None))
    records.append((target + "/" + source.name, 0, source))

elif source.is_dir():
    if not portable:
        fail("Para convertir carpetas utilizá --portable.")

    if requested_target:
        fail("--target se utiliza solamente con archivos individuales.")

    names = {item.name for item in source.iterdir()}
    unknown = names - set(VARIANTS) - {"shared"}

    if unknown:
        fail("Carpeta no reconocida: " + ", ".join(sorted(unknown)))

    found = sorted(names & set(VARIANTS))

    if not found:
        fail("No se encontraron variantes reconocidas.")

    for variant in found:
        folder = source / variant

        if folder.is_symlink() or not folder.is_dir():
            fail("Variante inválida: " + variant)

        records.append((variant, 1, None))
        for path, kind, item in collect(folder):
            records.append((variant + "/" + path, kind, item))

    if "shared" in names:
        folder = source / "shared"
        if folder.is_symlink() or not folder.is_dir():
            fail("shared debe ser una carpeta real.")

        records.append(("shared", 1, None))
        records.extend(collect(folder, "shared"))

else:
    fail("El origen debe ser un archivo o directorio.")

records.sort(key=lambda item: item[0].encode("utf-8"))

seen = set()
for path, kind, item in records:
    if path in seen or path.casefold() in {x.casefold() for x in seen}:
        fail("Ruta duplicada: " + path)
    seen.add(path)

    if len(path.encode("utf-8")) > 4096:
        fail("Ruta demasiado larga: " + path)

manifest_fields = [
    ("package_name", name),
    ("version", "1.0.0"),
    ("description", "Multiplatform package created by Bacus-Pkg"),
    ("target_os", "any"),
    ("target_arch", "any"),
    ("payload_format", "raw-v1"),
    ("entrypoint", ""),
    ("file_count", str(len(records))),
    ("variant_layout", "directory-v1"),
    ("variants", ",".join(found)),
    ("package_kind", "multiplatform" if portable else "single-variant"),
]

manifest = "".join(
    key + "=" + encode_value(value) + "\n"
    for key, value in manifest_fields
).encode("utf-8")

table_parts = []
payload = tempfile.TemporaryFile(mode="w+b")
payload_offset = 0
payload_size = 0

for path, kind, item in records:
    path_bytes = path.encode("utf-8")

    if kind == 1:
        table_parts.append(
            ENTRY.pack(len(path_bytes), 1, bytes(3), 0, 0, 0, bytes(32))
            + path_bytes
        )
        continue

    digest = hashlib.sha256()
    size = 0

    with item.open("rb") as stream:
        while True:
            block = stream.read(CHUNK)
            if not block:
                break
            payload.write(block)
            digest.update(block)
            size += len(block)

    table_parts.append(
        ENTRY.pack(
            len(path_bytes), 0, bytes(3),
            payload_offset, size, size, digest.digest()
        ) + path_bytes
    )

    payload_offset += size
    payload_size += size

table = b"".join(table_parts)
temporary = None

try:
    fd, temp_name = tempfile.mkstemp(
        prefix=".bacusp-",
        suffix=".tmp",
        dir=str(destination.parent)
    )
    temporary = Path(temp_name)

    with os.fdopen(fd, "wb") as output:
        output.write(HEADER.pack(
            MAGIC, HEADER.size, VERSION, 0,
            len(manifest), len(table), payload_size
        ))
        output.write(manifest)
        output.write(table)

        payload.seek(0)
        while True:
            block = payload.read(CHUNK)
            if not block:
                break
            output.write(block)

        output.flush()
        os.fsync(output.fileno())

    os.link(temporary, destination)
    temporary.unlink()
    temporary = None

    print("Bacus-Pkg: paquete creado.")
    print("Archivo:", destination)
    print("Variantes:", ", ".join(found))
    print("Entradas:", len(records))
    print("Payload:", payload_size, "bytes")
    print("Formato: BP 1.0 + directory-v1")
    print("Aviso: empaquetar no significa traducir el programa.")

finally:
    payload.close()
    if temporary is not None:
        try:
            temporary.unlink()
        except OSError:
            pass
PY
