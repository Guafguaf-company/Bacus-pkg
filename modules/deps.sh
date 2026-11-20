
#!/bin/sh
# BACUSP 7.6 - Independent Dependency Resolver
# Resolves packages from BACUSP repository indexes.
# Never invokes native package managers.

set -eu
umask 077

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
INDEX_DIR="$BACUSP_HOME/repositories"

usage() {
    cat <<'EOF'
BACUSP Dependency Resolver

Usage:
  bacusp deps resolve PACKAGE

Output:
  A topologically ordered installation plan.
  Dependencies appear before the requested package.

Supported constraints:
  libfoo
  libfoo>=1.2.0
  libfoo=2.0.0
  libfoo<3.0.0
EOF
}

ACTION=${1:-}
PACKAGE=${2:-}

case "$ACTION" in
    resolve)
        [ -n "$PACKAGE" ] || {
            echo "Error: falta el paquete." >&2
            exit 2
        }
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

case "$PACKAGE" in
    *[!A-Za-z0-9._+-]*|"")
        echo "Error: nombre de paquete inválido." >&2
        exit 2
        ;;
esac

[ -d "$INDEX_DIR" ] || {
    echo "Error: no hay índices de repositorios. Ejecutá bacusp repo sync." >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "Error: se necesita Python 3." >&2
    exit 1
}

exec python3 - "$INDEX_DIR" "$PACKAGE" <<'PY'
import sys
import os
import re
import glob
import platform

index_dir, root_package = sys.argv[1:3]

def fail(message):
    print("BACUSP deps: " + message, file=sys.stderr)
    raise SystemExit(1)

def version_key(value):
    # Numeric dot-separated versions, with a lexical suffix.
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)*)(?:[-+]([A-Za-z0-9.-]+))?", value)
    if not match:
        fail("versión no válida en un índice: " + value)

    numbers = tuple(int(part) for part in match.group(1).split("."))
    suffix = match.group(2)

    return numbers, suffix is None, suffix or ""

def compare_versions(left, right):
    a, b = version_key(left), version_key(right)

    max_length = max(len(a[0]), len(b[0]))
    av = a[0] + (0,) * (max_length - len(a[0]))
    bv = b[0] + (0,) * (max_length - len(b[0]))

    if av != bv:
        return (av > bv) - (av < bv)

    if a[1] != b[1]:
        return (a[1] > b[1]) - (a[1] < b[1])

    return (a[2] > b[2]) - (a[2] < b[2])

def parse_dependency(raw):
    match = re.fullmatch(
        r"([A-Za-z0-9._+-]+)(?:(>=|<=|=|>|<)([A-Za-z0-9.+-]+))?",
        raw.strip()
    )

    if not match:
        fail("dependencia mal formada: " + raw)

    name, operator, version = match.groups()

    if version:
        version_key(version)

    return name, operator, version

def satisfies(version, constraints):
    for operator, required in constraints:
        result = compare_versions(version, required)

        if operator == ">=" and result < 0:
            return False
        if operator == "<=" and result > 0:
            return False
        if operator == ">" and result <= 0:
            return False
        if operator == "<" and result >= 0:
            return False
        if operator == "=" and result != 0:
            return False

    return True

def compatible_arch(arch):
    machine = platform.machine().lower()

    aliases = {
        "x86_64": {"x86_64", "amd64", "any"},
        "amd64": {"x86_64", "amd64", "any"},
        "i386": {"i386", "i486", "i586", "i686", "x86", "any"},
        "i686": {"i386", "i486", "i586", "i686", "x86", "any"},
        "aarch64": {"aarch64", "arm64", "any"},
        "arm64": {"aarch64", "arm64", "any"},
        "armv7l": {"arm", "armhf", "armv7l", "any"},
        "armv6l": {"arm", "armv6", "any"},
        "riscv64": {"riscv64", "any"},
    }

    accepted = aliases.get(machine, {machine, "any"})
    return arch.lower() in accepted

def compatible_os(target):
    system = platform.system().lower()
    target = target.lower()

    if target == "any":
        return True
    if target == "unix":
        return system in ("linux", "darwin", "freebsd", "openbsd", "netbsd")
    if target == "linux":
        return system == "linux"
    if target == "macos":
        return system == "darwin"
    if target == "freebsd":
        return system == "freebsd"

    return target == system

def load_indexes():
    packages = {}

    for path in sorted(glob.glob(os.path.join(index_dir, "*.tsv"))):
        if not os.path.isfile(path) or os.path.islink(path):
            continue

        with open(path, "r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                line = line.rstrip("\n")

                if not line:
                    continue

                fields = line.split("\t")

                if len(fields) != 8:
                    fail(f"índice inválido: {path}:{line_number}")

                name, version, arch, os_name, digest, filename, url, depends = fields

                if not re.fullmatch(r"[A-Za-z0-9._+-]+", name):
                    fail("nombre inválido en índice: " + name)

                if not re.fullmatch(r"[A-Za-z0-9._+-]+", filename):
                    fail("nombre de archivo inválido: " + filename)

                if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
                    fail("SHA-256 inválido para " + name)

                if not url.startswith("https://"):
                    fail("URL insegura para " + name)

                version_key(version)

                if not compatible_arch(arch) or not compatible_os(os_name):
                    continue

                dependencies = []
                if depends not in ("", "-"):
                    dependencies = [
                        parse_dependency(item)
                        for item in depends.split(",")
                    ]

                entry = {
                    "name": name,
                    "version": version,
                    "arch": arch,
                    "os": os_name,
                    "sha256": digest.lower(),
                    "filename": filename,
                    "url": url,
                    "dependencies": dependencies,
                }

                packages.setdefault(name, []).append(entry)

    for name in packages:
        packages[name].sort(
            key=lambda item: version_key(item["version"]),
            reverse=True
        )

    return packages

packages = load_indexes()

if root_package not in packages:
    fail("no se encontró el paquete compatible: " + root_package)

def resolve(constraints, selected, visiting, order):
    # Pick the unresolved package with the fewest viable candidates.
    unresolved = [
        name for name in constraints
        if name not in selected
    ]

    if not unresolved:
        return selected, order

    choices = []

    for name in unresolved:
        candidates = [
            item for item in packages.get(name, [])
            if satisfies(
                item["version"],
                constraints.get(name, [])
            )
        ]

        if not candidates:
            return None

        choices.append((len(candidates), name, candidates))

    _, name, candidates = min(choices, key=lambda item: item[0])

    for candidate in candidates:
        new_selected = dict(selected)
        new_selected[name] = candidate

        new_constraints = {
            key: list(value)
            for key, value in constraints.items()
        }

        new_visiting = set(visiting)
        new_visiting.add(name)

        cycle = False

        for dep_name, operator, dep_version in candidate["dependencies"]:
            if dep_name in new_visiting:
                cycle = True
                break

            if dep_name not in packages:
                cycle = True
                break

            new_constraints.setdefault(dep_name, [])

            if operator:
                new_constraints[dep_name].append(
                    (operator, dep_version)
                )

            if dep_name in new_selected and not satisfies(
                new_selected[dep_name]["version"],
                new_constraints[dep_name]
            ):
                cycle = True
                break

        if cycle:
            continue

        result = resolve(
            new_constraints,
            new_selected,
            new_visiting,
            order
        )

        if result is not None:
            final_selected, final_order = result

            if name not in final_order:
                final_order = final_order + [name]

            return final_selected, final_order

    return None

result = resolve(
    {root_package: []},
    {},
    set(),
    []
)

if result is None:
    fail(
        "no se pudo resolver el árbol completo. "
        "Puede haber dependencias ausentes, conflictos de versiones "
        "o ciclos."
    )

selected, order = result

# Dependencies must be printed before the packages that require them.
# The recursive search order is used to build a stable topological plan.
for name in order:
    item = selected[name]
    print("\t".join([
        item["name"],
        item["version"],
        item["arch"],
        item["os"],
        item["sha256"],
        item["filename"],
        item["url"],
        ",".join(dep[0] for dep in item["dependencies"]) or "-"
    ]))
PY
