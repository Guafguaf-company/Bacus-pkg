
```sh
#!/bin/sh
# ============================================================
# BACUSP 7.8 - Independent Dependency Resolution Engine
# Project: Bacus-Pkg
#
# Features:
# - Direct and transitive dependency resolution
# - Version constraints
# - Backtracking candidate selection
# - Architecture and OS compatibility
# - Repository priority:
#     0. Official
#     1. Community
#     2. External distributions
# - Shared dependency handling
# - Circular dependency detection
# - Topological installation plan
#
# Native package managers are never executed.
#
# Current index format:
# name version architecture os sha256 filename url dependencies
# ============================================================

set -eu
umask 077

BACUSP_HOME=${BACUSP_HOME:-"${HOME:-/tmp}/.bacusp"}
INDEX_DIR="$BACUSP_HOME/repositories"

usage() {
    cat <<'EOF'
BACUSP 7.8 - Dependency Engine

Usage:
  bacusp deps resolve PACKAGE
  bacusp deps check PACKAGE

Examples:
  bacusp deps resolve btop
  bacusp deps check firefox

Dependency syntax:
  libfoo
  libfoo>=1.2.0
  libfoo<=2.0.0
  libfoo=1.5.0
  libfoo>1.0.0
  libfoo<3.0.0

Multiple dependencies:
  libfoo>=1.0.0,libbar>=2.0.0

Repository priority:
  0 = official
  1 = community
  2 = external
  3 = legacy/unknown (treated as community)

Index format:
  name<TAB>version<TAB>architecture<TAB>os<TAB>sha256<TAB>filename<TAB>url<TAB>dependencies

Output:
  resolve: topologically ordered TSV installation plan.
  check: human-readable dependency tree.
EOF
}

ACTION=${1:-}
PACKAGE=${2:-}

case "$ACTION" in
    resolve|check)
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [ -z "$PACKAGE" ]; then
    echo "BACUSP deps: falta el nombre del paquete." >&2
    exit 2
fi

case "$PACKAGE" in
    *[!A-Za-z0-9._+-]*)
        echo "BACUSP deps: nombre de paquete inválido." >&2
        exit 2
        ;;
esac

if [ ! -d "$INDEX_DIR" ]; then
    echo "BACUSP deps: no existen índices de repositorios." >&2
    echo "Ejecutá primero: bacusp repo sync" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "BACUSP deps: Python 3 es obligatorio." >&2
    exit 1
fi

exec python3 - "$INDEX_DIR" "$PACKAGE" "$ACTION" <<'PY'
import sys
import os
import re
import glob
import platform

INDEX_DIR = sys.argv[1]
ROOT_PACKAGE = sys.argv[2]
ACTION = sys.argv[3]

MAX_PACKAGES = 10000
MAX_DEPTH = 200
MAX_SEARCH_STEPS = 100000

search_steps = 0


def fail(message):
    print("BACUSP deps: " + message, file=sys.stderr)
    raise SystemExit(1)


# ------------------------------------------------------------
# Version handling
# ------------------------------------------------------------

VERSION_PATTERN = re.compile(
    r"^([0-9]+(?:\.[0-9]+)*)(?:-([A-Za-z0-9.-]+))?(?:\+([A-Za-z0-9.-]+))?$"
)


def version_parts(version):
    match = VERSION_PATTERN.fullmatch(version)

    if not match:
        fail("versión no compatible con el formato actual: " + version)

    numbers = tuple(int(x) for x in match.group(1).split("."))
    prerelease = match.group(2)
    build = match.group(3)

    return numbers, prerelease, build


def compare_versions(left, right):
    left_numbers, left_pre, _ = version_parts(left)
    right_numbers, right_pre, _ = version_parts(right)

    length = max(len(left_numbers), len(right_numbers))

    a = left_numbers + (0,) * (length - len(left_numbers))
    b = right_numbers + (0,) * (length - len(right_numbers))

    if a != b:
        return (a > b) - (a < b)

    if left_pre is None and right_pre is not None:
        return 1

    if left_pre is not None and right_pre is None:
        return -1

    if left_pre != right_pre:
        return (left_pre > right_pre) - (left_pre < right_pre)

    return 0


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


# ------------------------------------------------------------
# Dependency syntax
# ------------------------------------------------------------

DEPENDENCY_PATTERN = re.compile(
    r"^([A-Za-z0-9._+-]+)(?:(>=|<=|=|>|<)([A-Za-z0-9.+-]+))?$"
)


def parse_dependency(raw):
    raw = raw.strip()

    match = DEPENDENCY_PATTERN.fullmatch(raw)

    if not match:
        fail("dependencia mal formada: " + raw)

    name, operator, version = match.groups()

    if version is not None:
        version_parts(version)

    return name, operator, version


def parse_dependencies(value):
    if value in ("", "-"):
        return []

    result = []

    for item in value.split(","):
        if not item.strip():
            fail("dependencia vacía en un índice")

        result.append(parse_dependency(item))

    return result


# ------------------------------------------------------------
# Repository priority
# ------------------------------------------------------------

def repository_priority(index_path):
    filename = os.path.basename(index_path).lower()

    if filename.startswith("official-"):
        return 0

    if filename.startswith("community-"):
        return 1

    if filename.startswith("external-"):
        return 2

    # Legacy index files remain usable.
    return 1


# ------------------------------------------------------------
# Platform compatibility
# ------------------------------------------------------------

def compatible_architecture(package_arch):
    machine = platform.machine().lower()
    package_arch = package_arch.lower()

    aliases = {
        "x86_64": {
            "x86_64", "amd64", "any"
        },
        "amd64": {
            "x86_64", "amd64", "any"
        },
        "i386": {
            "i386", "i486", "i586", "i686", "x86", "any"
        },
        "i486": {
            "i386", "i486", "i586", "i686", "x86", "any"
        },
        "i586": {
            "i386", "i486", "i586", "i686", "x86", "any"
        },
        "i686": {
            "i386", "i486", "i586", "i686", "x86", "any"
        },
        "aarch64": {
            "aarch64", "arm64", "any"
        },
        "arm64": {
            "aarch64", "arm64", "any"
        },
        "armv7l": {
            "arm", "armhf", "armv7l", "any"
        },
        "armv6l": {
            "arm", "armv6", "any"
        },
        "riscv64": {
            "riscv64", "any"
        },
    }

    accepted = aliases.get(machine, {machine, "any"})

    return package_arch in accepted


def compatible_os(package_os):
    system = platform.system().lower()
    package_os = package_os.lower()

    if package_os == "any":
        return True

    if package_os == "unix":
        return system in (
            "linux",
            "darwin",
            "freebsd",
            "openbsd",
            "netbsd"
        )

    if package_os == "linux":
        return system == "linux"

    if package_os in ("macos", "mac"):
        return system == "darwin"

    if package_os == "windows":
        return system == "windows"

    return package_os == system


# ------------------------------------------------------------
# Index validation and loading
# ------------------------------------------------------------

def load_indexes():
    packages = {}

    index_files = sorted(
        glob.glob(os.path.join(INDEX_DIR, "*.tsv"))
    )

    if not index_files:
        fail("no se encontraron índices sincronizados")

    total_packages = 0

    for index_path in index_files:
        if os.path.islink(index_path):
            continue

        if not os.path.isfile(index_path):
            continue

        tier = repository_priority(index_path)
        index_name = os.path.basename(index_path)

        try:
            with open(
                index_path,
                "r",
                encoding="utf-8"
            ) as stream:

                for line_number, line in enumerate(stream, 1):
                    line = line.rstrip("\r\n")

                    if not line:
                        continue

                    fields = line.split("\t")

                    if len(fields) != 8:
                        fail(
                            "índice inválido: "
                            + index_path
                            + ":"
                            + str(line_number)
                        )

                    (
                        name,
                        version,
                        architecture,
                        os_name,
                        digest,
                        filename,
                        url,
                        dependency_text
                    ) = fields

                    if not re.fullmatch(
                        r"[A-Za-z0-9._+-]+",
                        name
                    ):
                        fail("nombre de paquete inválido: " + name)

                    if not re.fullmatch(
                        r"[A-Za-z0-9._+-]+",
                        architecture
                    ):
                        fail("arquitectura inválida: " + architecture)

                    if not re.fullmatch(
                        r"[A-Za-z0-9._+-]+",
                        os_name
                    ):
                        fail("sistema operativo inválido: " + os_name)

                    if not re.fullmatch(
                        r"[0-9a-fA-F]{64}",
                        digest
                    ):
                        fail("SHA-256 inválido: " + name)

                    if not re.fullmatch(
                        r"[A-Za-z0-9._+-]+",
                        filename
                    ):
                        fail("nombre de archivo inválido: " + filename)

                    if not url.startswith("https://"):
                        fail("URL HTTPS obligatoria: " + name)

                    if any(char in url for char in "\r\n\t"):
                        fail("URL inválida: " + name)

                    version_parts(version)

                    dependencies = parse_dependencies(
                        dependency_text
                    )

                    if not compatible_architecture(architecture):
                        continue

                    if not compatible_os(os_name):
                        continue

                    package = {
                        "name": name,
                        "version": version,
                        "architecture": architecture,
                        "os": os_name,
                        "sha256": digest.lower(),
                        "filename": filename,
                        "url": url,
                        "dependencies": dependencies,
                        "tier": tier,
                        "repository": index_name,
                    }

                    packages.setdefault(name, []).append(package)

                    total_packages += 1

                    if total_packages > MAX_PACKAGES:
                        fail(
                            "se superó el límite de "
                            + str(MAX_PACKAGES)
                            + " paquetes"
                        )

        except UnicodeError:
            fail("índice con codificación inválida: " + index_path)

        except OSError as exc:
            fail(
                "no se pudo leer "
                + index_path
                + ": "
                + str(exc)
            )

    # Deduplicate identical packages without losing source priority.
    for name, candidates in packages.items():
        unique = {}

        for candidate in candidates:
            key = (
                candidate["version"],
                candidate["sha256"],
                candidate["url"],
                candidate["tier"]
            )

            unique[key] = candidate

        packages[name] = list(unique.values())

        # Stable ordering:
        # First version, then repository priority.
        packages[name].sort(
            key=lambda item: version_parts(item["version"]),
            reverse=True
        )

        packages[name].sort(
            key=lambda item: item["tier"]
        )

    return packages


PACKAGES = load_indexes()


# ------------------------------------------------------------
# Candidate selection
# ------------------------------------------------------------

def candidates_for(name, constraints):
    result = []

    for candidate in PACKAGES.get(name, []):
        if satisfies(candidate["version"], constraints):
            result.append(candidate)

    # Official repositories always have priority over community.
    # Community always has priority over external distributions.
    result.sort(
        key=lambda item: version_parts(item["version"]),
        reverse=True
    )

    result.sort(
        key=lambda item: item["tier"]
    )

    return result


# ------------------------------------------------------------
# Dependency graph
# ------------------------------------------------------------

def topological_order(selected, root):
    visited = set()
    active = set()
    order = []

    def visit(name, depth):
        if depth > MAX_DEPTH:
            fail("se superó la profundidad máxima de dependencias")

        if name in active:
            return False

        if name in visited:
            return True

        if name not in selected:
            return False

        active.add(name)

        for dependency in selected[name]["dependencies"]:
            dep_name = dependency[0]

            if not visit(dep_name, depth + 1):
                return False

        active.remove(name)
        visited.add(name)
        order.append(name)

        return True

    if not visit(root, 0):
        return None

    if len(visited) != len(selected):
        return None

    return order


# ------------------------------------------------------------
# Independent backtracking resolver
# ------------------------------------------------------------

def resolve(constraints, selected, depth=0):
    global search_steps

    search_steps += 1

    if search_steps > MAX_SEARCH_STEPS:
        fail("se superó el límite de búsqueda del resolvedor")

    if depth > MAX_DEPTH:
        return None

    # Validate all constraints against selected packages.
    for name, requirements in constraints.items():
        if name in selected:
            if not satisfies(
                selected[name]["version"],
                requirements
            ):
                return None

    unresolved = [
        name for name in constraints
        if name not in selected
    ]

    # All dependencies have a selected candidate.
    if not unresolved:
        return selected

    choices = []

    for name in unresolved:
        candidates = candidates_for(
            name,
            constraints[name]
        )

        if not candidates:
            return None

        choices.append((
            len(candidates),
            name,
            candidates
        ))

    # Resolve the package with the fewest candidates first.
    _, name, candidates = min(
        choices,
        key=lambda item: item[0]
    )

    for candidate in candidates:
        next_selected = dict(selected)
        next_selected[name] = candidate

        next_constraints = {
            key: list(value)
            for key, value in constraints.items()
        }

        invalid = False

        # Expand direct and transitive dependencies.
        for dep_name, operator, dep_version in candidate["dependencies"]:
            next_constraints.setdefault(dep_name, [])

            if operator is not None:
                next_constraints[dep_name].append(
                    (operator, dep_version)
                )

            if dep_name in next_selected:
                if not satisfies(
                    next_selected[dep_name]["version"],
                    next_constraints[dep_name]
                ):
                    invalid = True
                    break

        if invalid:
            continue

        result = resolve(
            next_constraints,
            next_selected,
            depth + 1
        )

        if result is None:
            continue

        # Reject circular dependency graphs.
        if topological_order(result, ROOT_PACKAGE) is None:
            continue

        return result

    return None


# ------------------------------------------------------------
# Resolve requested package
# ------------------------------------------------------------

if ROOT_PACKAGE not in PACKAGES:
    fail(
        "paquete no encontrado o incompatible: "
        + ROOT_PACKAGE
    )

print(
    "BACUSP deps: resolviendo " + ROOT_PACKAGE,
    file=sys.stderr
)

selected = resolve(
    {ROOT_PACKAGE: []},
    {}
)

if selected is None:
    fail(
        "no existe una solución completa. "
        "Revisá dependencias, versiones y ciclos."
    )

order = topological_order(
    selected,
    ROOT_PACKAGE
)

if order is None:
    fail("se detectó un ciclo de dependencias")


# ------------------------------------------------------------
# Human-readable check mode
# ------------------------------------------------------------

if ACTION == "check":
    print("Árbol de dependencias válido:")
    print("")

    for name in order:
        package = selected[name]

        tiers = {
            0: "oficial",
            1: "comunidad",
            2: "externo",
            3: "desconocido"
        }

        print(
            "  "
            + package["name"]
            + " "
            + package["version"]
            + " ["
            + tiers[package["tier"]]
            + "]"
        )

    print("")
    print("Paquetes:", len(order))
    print("Pasos de resolución:", search_steps)

    raise SystemExit(0)


# ------------------------------------------------------------
# Machine-readable installation plan
# ------------------------------------------------------------

for name in order:
    package = selected[name]

    dependencies = ",".join(
        dep[0] for dep in package["dependencies"]
    ) or "-"

    fields = [
        package["name"],
        package["version"],
        package["architecture"],
        package["os"],
        package["sha256"],
        package["filename"],
        package["url"],
        dependencies
    ]

    print("\t".join(fields))

PY
```
