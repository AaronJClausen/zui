"""Which packages a change since <base> can affect, as GitHub Actions outputs:

    python3 .github/scripts/affected_packages.py <base> \
        --matrix pure_packages=text/glyphs,themes

prints `renderers-raylib=true`, `root-build=false`, ... and
`pure_packages=["themes"]`. An empty or unknown base affects everything.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

CHANGES_TO_EVERY_JOB = (".github/workflows/ci.yml", ".github/actions/", ".github/scripts/")
ROOT_BUILD_FILES = ("build.zig", "build.zig.zon", "tests")
PATH_DEPENDENCY = re.compile(r'\.path\s*=\s*"([^"]+)"')


def git(*arguments):
    return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True).stdout


def package_directories():
    manifests = git("ls-files", "*/build.zig.zon").split()
    return sorted(str(pathlib.PurePosixPath(manifest).parent) for manifest in manifests)


def path_dependencies(package):
    manifest = pathlib.Path(package, "build.zig.zon").read_text()
    resolved = (pathlib.Path(package, relative).resolve() for relative in PATH_DEPENDENCY.findall(manifest))
    root = pathlib.Path.cwd().resolve()
    return {str(directory.relative_to(root)) for directory in resolved}


def dependency_closure(package, dependencies_of):
    reached, waiting = set(), [package]
    while waiting:
        current = waiting.pop()
        if current in reached:
            continue
        reached.add(current)
        waiting.extend(dependencies_of.get(current, ()))
    return reached


def changed_files(base):
    if not base or set(base) == {"0"}:
        return None
    try:
        git("cat-file", "-e", f"{base}^{{commit}}")
    except subprocess.CalledProcessError:
        return None
    return git("diff", "--name-only", base, "HEAD").split()


def is_under(path, directory):
    return path == directory or path.startswith(directory + "/")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base", nargs="?", default="")
    parser.add_argument("--matrix", action="append", default=[], metavar="NAME=PACKAGE,...")
    arguments = parser.parse_args()

    packages = package_directories()
    dependencies_of = {package: path_dependencies(package) for package in packages}
    changed = changed_files(arguments.base)
    changes_everything = changed is None or any(path.startswith(CHANGES_TO_EVERY_JOB) for path in changed)

    affected = {}
    for package in packages:
        closure = dependency_closure(package, dependencies_of)
        affected[package] = changes_everything or any(is_under(path, directory) for path in changed for directory in closure)

    outputs = {package.replace("/", "-"): affected[package] for package in packages}
    outputs["root-build"] = changes_everything or any(is_under(path, file) for path in changed for file in ROOT_BUILD_FILES)
    for line in (f"{name}={'true' if value else 'false'}" for name, value in outputs.items()):
        print(line)
    for matrix in arguments.matrix:
        name, _, listed = matrix.partition("=")
        unknown = [package for package in listed.split(",") if package not in affected]
        if unknown:
            sys.exit(f"--matrix {name} names {', '.join(unknown)}, which no build.zig.zon below the root makes a package")
        print(f"{name}={json.dumps([package for package in listed.split(',') if affected[package]])}")


if __name__ == "__main__":
    main()
