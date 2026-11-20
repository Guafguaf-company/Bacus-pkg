
#!/bin/sh
# ============================================================
# BACUSP 7.6 - BP v1 Package Verifier
# Independent package structure and integrity validation
# ============================================================
#
# Validates:
# - BP v1 binary header
# - Manifest syntax and required metadata
# - Package identity and version
# - Dependency and conflict declarations
# - Safe paths and entrypoint
# - File table and payload boundaries
# - SHA-256 for every payload file
#
# SHA-256 verifies integrity, NOT publisher authenticity.
# ============================================================

set -eu
umask 077

if [ "$#" -ne 1 ]; then
    printf '%s\n' \
        "Uso: bacusp verify PAQUETE.bp" \
        "Usage: bacusp verify PACKAGE.bp" >&2
    exit 2
fi

PACKAGE=$1

if [ ! -f "$PACKAGE" ] || [ -L "$PACKAGE" ]; then
    echo "ERROR: se requiere un archivo regular, no un enlace." >&2
    exit 2
fi

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: Python 3 es obligatorio." >&2
    exit 2
}

exec python3 - "$PACKAGE" <<'PY'
import os
import sys
import re
import struct
import hashlib

MAGIC = b"BACUSBP1"
HEADER = struct.Struct("<8sIIIQQQ")
ENTRY = struct.Struct("<IB3sQQQ32s")

VERSION = 0x00010000
CHUNK = 1024 * 1024

MAX_MANIFEST = int(
    os.environ.get(
        "BACUSP_MAX_MANIFEST_BYTES",
        str(16 * 1024 * 1024)
    )
)

MAX_ENTRIES = int(
    os.environ.get(
        "BACUSP_MAX_ENTRIES",
        "1000000"
    )
)

PACKAGE_NAME_RE = re.compile(
    r"^[A-Za-z0-9._+-]+$"
)

VERSION_RE = re.compile(
    r"^([0-9]+(?:\.[0-9]+)*)(?:-([A-Za-z0-9.-]+))?(?:\+([A-Za-z0-9.-]+))?$"
)

DEPENDENCY_RE = re.compile(
    r"^([A-Za-z0-9._+-]+)(?:(>=|<=|=|>|<)([A-Za-z0-9.+-]+))?$"
)

def fail(message):
    print("ERROR:", message, file=sys.stderr)
    raise SystemExit(2)

def exact(stream, size, label):
    data = stream.read(size)

    if len(data) != size:
        fail("datos incompletos: " + label)

    return data

# ------------------------------------------------------------
# Manifest decoding
# ------------------------------------------------------------

def decode_value(value, label):
    result = bytearray()
    index = 0

    while index < len(value):
        char = value[index]

        if char == "%":
            if index + 2 >= len(value):
                fail("escape porcentual incompleto: " + label)

            pair = value[index + 1:index + 3]

            if not re.fullmatch(r"[0-9A-Fa-f]{2}", pair):
                fail("escape porcentual inválido: " + label)

            result.append(int(pair, 16))
            index += 3
            continue

        code = ord(char)

        if code > 127 or char in "\r\n":
            fail("carácter no permitido: " + label)

        result.append(code)
        index += 1

    try:
        return result.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        fail("valor UTF-8 inválido: " + label)

def safe_path(path):
    if not path:
        return False

    if "\x00" in path or "\\" in path:
        return False

    if path.startswith("/"):
        return False

    if re.match(r"^[A-Za-z]:", path):
        return False

    parts = path.split("/")

    if any(part in ("", ".", "..") for part in parts):
        return False

    return True

# ------------------------------------------------------------
# Metadata validation
# ------------------------------------------------------------

def validate_version(version):
    if not VERSION_RE.fullmatch(version):
        fail("versión de paquete inválida: " + version)

def validate_package_name(name):
    if not PACKAGE_NAME_RE.fullmatch(name):
        fail("nombre de paquete inválido: " + name)

def validate_dependency_list(value, field):
    if value == "":
        return []

    result = []

    for raw in value.split(","):
        if not raw:
            fail("dependencia vacía en " + field)

        match = DEPENDENCY_RE.fullmatch(raw.strip())

        if not match:
            fail(
                "declaración inválida en "
                + field
                + ": "
                + raw
            )

        name, operator, version = match.groups()

        validate_package_name(name)

        if version is not None:
            validate_version(version)

        result.append((name, operator, version))

    names = [item[0] for item in result]

    if len(names) != len(set(names)):
        fail("paquete repetido en " + field)

    return result

def validate_manifest(manifest):
    required = (
        "package_name",
        "version",
        "description",
        "target_os",
        "target_arch",
        "payload_format",
        "entrypoint",
        "file_count"
    )

    for field in required:
        if field not in manifest:
            fail("falta el campo: " + field)

    validate_package_name(manifest["package_name"])
    validate_version(manifest["version"])

    if not manifest["description"]:
        fail("description no puede estar vacío")

    for field in ("target_os", "target_arch"):
        value = manifest[field]

        if not re.fullmatch(r"[A-Za-z0-9._+-]+", value):
            fail(field + " inválido")

    if manifest["payload_format"] != "raw-v1":
        fail("payload_format no compatible")

    try:
        count = int(manifest["file_count"], 10)
    except ValueError:
        fail("file_count inválido")

    if count < 0 or count > MAX_ENTRIES:
        fail("file_count fuera de los límites permitidos")

    # Optional dependency metadata.
    for field in ("depends", "conflicts", "provides", "replaces"):
        if field in manifest:
            validate_dependency_list(manifest[field], field)

    # Optional package variant metadata.
    if "package_kind" in manifest:
        if manifest["package_kind"] not in (
            "single-variant",
            "multiplatform"
        ):
            fail("package_kind no compatible")

    if "variants" in manifest:
        variants = manifest["variants"].split(",")

        if any(
            not re.fullmatch(r"[A-Za-z0-9._+-]+", item)
            for item in variants
        ):
            fail("variants contiene valores inválidos")

        if len(variants) != len(set(variants)):
            fail("variants contiene duplicados")

    if "variant_layout" in manifest:
        if manifest["variant_layout"] != "directory-v1":
            fail("variant_layout no compatible")

    return count

# ------------------------------------------------------------
# Binary package validation
# ------------------------------------------------------------

def main():
    filename = sys.argv[1]

    if MAX_MANIFEST < 1 or MAX_ENTRIES < 1:
        fail("límites de verificación inválidos")

    total_size = os.path.getsize(filename)

    with open(filename, "rb") as stream:

        # Header.
        header = exact(
            stream,
            HEADER.size,
            "cabecera"
        )

        (
            magic,
            header_size,
            version,
            flags,
            manifest_size,
            table_size,
            payload_size
        ) = HEADER.unpack(header)

        if magic != MAGIC:
            fail("no es un paquete BACUSP BP v1")

        if header_size != HEADER.size:
            fail("tamaño de cabecera incompatible")

        if version != VERSION:
            fail("versión de formato BP incompatible")

        if flags != 0:
            fail("flags no admitidos")

        if manifest_size > MAX_MANIFEST:
            fail("manifiesto demasiado grande")

        expected_total = (
            HEADER.size
            + manifest_size
            + table_size
            + payload_size
        )

        if expected_total != total_size:
            fail("el tamaño total no coincide con la cabecera")

        # Manifest.
        raw_manifest = exact(
            stream,
            manifest_size,
            "manifiesto"
        )

        if (
            not raw_manifest.endswith(b"\n")
            or b"\r" in raw_manifest
            or b"\x00" in raw_manifest
        ):
            fail("formato de manifiesto inválido")

        try:
            lines = raw_manifest.decode("utf-8").splitlines()
        except UnicodeDecodeError:
            fail("manifiesto no válido en UTF-8")

        manifest = {}

        for line in lines:
            if not line or "=" not in line:
                fail("línea de manifiesto inválida")

            key, value = line.split("=", 1)

            if not re.fullmatch(r"[a-z][a-z0-9_]*", key):
                fail("clave inválida: " + key)

            if key in manifest:
                fail("clave duplicada: " + key)

            manifest[key] = decode_value(value, key)

        file_count = validate_manifest(manifest)

        # File table.
        entries = []
        seen = set()
        previous = None

        table_remaining = table_size
        expected_offset = 0

        if file_count > table_size // (ENTRY.size + 1):
            fail("cantidad de entradas incompatible con la tabla")

        for _ in range(file_count):
            if table_remaining < ENTRY.size:
                fail("tabla truncada")

            fixed = exact(
                stream,
                ENTRY.size,
                "entrada de tabla"
            )

            table_remaining -= ENTRY.size

            (
                path_length,
                kind,
                reserved,
                offset,
                stored,
                original,
                digest
            ) = ENTRY.unpack(fixed)

            if path_length == 0 or path_length > table_remaining:
                fail("longitud de ruta inválida")

            raw_path = exact(
                stream,
                path_length,
                "ruta"
            )

            table_remaining -= path_length

            try:
                path = raw_path.decode("utf-8")
            except UnicodeDecodeError:
                fail("ruta no válida en UTF-8")

            if not safe_path(path):
                fail("ruta insegura: " + repr(path))

            if raw_path in seen:
                fail("ruta duplicada: " + path)

            if previous is not None and raw_path <= previous:
                fail("las rutas no están ordenadas por bytes")

            seen.add(raw_path)
            previous = raw_path

            if reserved != b"\x00\x00\x00":
                fail("bytes reservados inválidos: " + path)

            if kind not in (0, 1):
                fail("tipo de entrada desconocido: " + path)

            if kind == 1:
                if (
                    offset != 0
                    or stored != 0
                    or original != 0
                    or digest != bytes(32)
                ):
                    fail("metadatos inválidos para directorio: " + path)

            else:
                if stored != original:
                    fail("tamaño almacenado incompatible: " + path)

                if offset != expected_offset:
                    fail("offset incorrecto: " + path)

                if stored > payload_size - expected_offset:
                    fail("archivo fuera del payload: " + path)

                expected_offset += stored

            entries.append((
                path,
                kind,
                offset,
                stored,
                digest
            ))

        if table_remaining != 0:
            fail("sobran bytes en la tabla")

        if expected_offset != payload_size:
            fail("el payload contiene bytes no referenciados")

        # Prevent a file from being used as a parent directory.
        path_types = {
            path: kind
            for path, kind, *_ in entries
        }

        for path, kind, *_ in entries:
            parts = path.split("/")

            for index in range(1, len(parts)):
                parent = "/".join(parts[:index])

                if path_types.get(parent) == 0:
                    fail(
                        "un archivo aparece como directorio padre: "
                        + parent
                    )

        # Entrypoint.
        entrypoint = manifest["entrypoint"]

        if entrypoint:
            if not safe_path(entrypoint):
                fail("entrypoint inseguro")

            if path_types.get(entrypoint) != 0:
                fail("entrypoint no apunta a un archivo regular")

        # Payload hashes.
        payload_start = HEADER.size + manifest_size + table_size

        for path, kind, offset, stored, expected_digest in entries:
            if kind == 1:
                continue

            stream.seek(payload_start + offset)

            remaining = stored
            digest = hashlib.sha256()

            while remaining:
                block = stream.read(
                    min(CHUNK, remaining)
                )

                if not block:
                    fail("payload truncado: " + path)

                digest.update(block)
                remaining -= len(block)

            if digest.digest() != expected_digest:
                fail("SHA-256 incorrecto: " + path)

    # Success report.
    print("OK: paquete BP válido")
    print("Nombre:", manifest["package_name"])
    print("Versión:", manifest["version"])
    print("Sistema:", manifest["target_os"])
    print("Arquitectura:", manifest["target_arch"])
    print("Entradas:", len(entries))
    print("Payload:", payload_size, "bytes")
    print("Tamaño total:", total_size, "bytes")

    for field in ("depends", "conflicts", "provides", "replaces"):
        if field in manifest:
            print(field + ":", manifest[field] or "(ninguno)")

    print("Integridad SHA-256: verificada")
    print(
        "Autenticidad del editor: no verificada "
        "(requiere firma digital)."
    )

    return 0

try:
    sys.exit(main())

except (OSError, OverflowError, struct.error, ValueError) as exc:
    fail(str(exc))

PY
