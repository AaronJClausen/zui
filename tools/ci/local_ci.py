# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Runs `.github/workflows/ci.yml` on this machine, for the jobs a change affects.

    uv run --script tools/ci/local_ci.py                   # HEAD against its upstream
    uv run --script tools/ci/local_ci.py --base origin/main --head HEAD~2
    uv run --script tools/ci/local_ci.py --all --only 'raylib|web'
    uv run --script tools/ci/local_ci.py --list

Linux legs run in an Ubuntu container built from `tools/ci/Dockerfile`,
with the packages the workflow installs. A Windows or macOS leg becomes a
cross-check: `zig build check -Dtarget=<its target>` with the leg's other
`-D` flags, run here, since neither runs here.
"""

import argparse
import concurrent.futures
import dataclasses
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time

import yaml

WORKFLOW = pathlib.Path(".github/workflows/ci.yml")
DOCKERFILE = pathlib.Path(__file__).resolve().parent / "Dockerfile"
CROSS_TARGETS = {"windows-latest": ("Windows", "x86_64-windows"), "macos-latest": ("macOS", "aarch64-macos")}
ACTIONS_WITHOUT_LOCAL_MEANING = ("actions/checkout@", "mlugg/setup-zig@", "actions/upload-artifact@")
PACKAGE_INSTALL = re.compile(r"apt-get install([^\n&|;]*)")
ONLY_INSTALLS_PACKAGES = re.compile(r"^\s*sudo apt-get update && sudo apt-get install [^\n&|;]*$")
# The container cannot change the host's ASLR entropy; the kernel's own setting stands.
HOST_SYSCTL = re.compile(r"sudo sysctl \S+ && ")
CROSS_CHECKS_NEEDING_AN_SDK = {
    ("renderers/sokol", "aarch64-macos"): "sokol compiles Objective-C against Metal and AppKit, whose headers only macOS's SDK has",
}
FAILED_LOG_LINES = 40
RUNS_KEPT = 5


def git(*arguments, cwd=None):
    return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True, cwd=cwd).stdout.strip()


class Expression:
    """A GitHub Actions `${{ }}` expression, evaluated against a context:

    ```python
    Expression("needs.changes.outputs.core == 'true' || matrix.os != 'macos-latest'").evaluate(context)
    ```
    """

    TOKEN = re.compile(r"\s*(?:(?P<string>'(?:[^']|'')*')|(?P<number>\d+(?:\.\d+)?)|(?P<operator>==|!=|&&|\|\||!|\(|\)|,)|(?P<name>[A-Za-z_][\w.-]*))")

    def __init__(self, source):
        self.tokens = []
        position = 0
        source = source.strip()
        while position < len(source):
            match = self.TOKEN.match(source, position)
            if not match:
                raise ValueError(f"cannot read the expression {source!r} at {position}")
            self.tokens.append((match.lastgroup, match.group(match.lastgroup)))
            position = match.end()
        self.next = 0

    def evaluate(self, context):
        self.context, self.next = context, 0
        value = self.either()
        if self.next != len(self.tokens):
            raise ValueError(f"unexpected {self.tokens[self.next][1]!r}")
        return value

    def peek(self):
        return self.tokens[self.next][1] if self.next < len(self.tokens) else None

    def take(self):
        self.next += 1
        return self.tokens[self.next - 1]

    def either(self):
        value = self.both()
        while self.peek() == "||":
            self.take()
            right = self.both()
            value = value or right
        return value

    def both(self):
        value = self.comparison()
        while self.peek() == "&&":
            self.take()
            right = self.comparison()
            value = value and right
        return value

    def comparison(self):
        value = self.unary()
        while self.peek() in ("==", "!="):
            operator = self.take()[1]
            right = self.unary()
            value = (as_text(value) == as_text(right)) == (operator == "==")
        return value

    def unary(self):
        if self.peek() == "!":
            self.take()
            return not self.unary()
        return self.primary()

    def primary(self):
        kind, text = self.take()
        if text == "(":
            value = self.either()
            self.take()
            return value
        if kind == "string":
            return text[1:-1].replace("''", "'")
        if kind == "number":
            return float(text)
        if text in ("true", "false"):
            return text == "true"
        if self.peek() == "(":
            self.take()
            arguments = []
            while self.peek() != ")":
                arguments.append(self.either())
                if self.peek() == ",":
                    self.take()
            self.take()
            return self.call(text, arguments)
        value = self.context
        for part in text.split("."):
            value = value.get(part, "") if isinstance(value, dict) else ""
        return value

    @staticmethod
    def call(function, arguments):
        if function == "fromJSON":
            return json.loads(arguments[0])
        if function in ("success", "always"):
            return True
        if function in ("failure", "cancelled"):
            return False
        raise ValueError(f"the expression calls {function}(), which local CI does not know")


def as_text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    return str(value)


def substitute(text, context):
    return re.sub(r"\$\{\{(.*?)\}\}", lambda match: as_text(Expression(match.group(1)).evaluate(context)), str(text))


def condition_holds(condition, context):
    if condition is None:
        return True
    if isinstance(condition, bool):
        return condition
    source = str(condition).strip()
    if source.startswith("${{") and source.endswith("}}"):
        source = source[3:-2]
    return bool(Expression(source).evaluate(context))


def matrix_combinations(strategy, context):
    """GitHub's expansion: the product of the listed values, each `include`
    extending every combination it matches, or added when it matches none."""
    matrix = dict((strategy or {}).get("matrix") or {})
    includes = matrix.pop("include", [])
    matrix.pop("exclude", None)
    combinations = [{}]
    for key, values in matrix.items():
        if isinstance(values, str):
            values = Expression(values.strip()[3:-2]).evaluate(context)
        combinations = [{**combination, key: value} for combination in combinations for value in values]
    if combinations == [{}] and includes:
        combinations = []
    for include in includes:
        matched = False
        for combination in combinations:
            if matrix and all(combination[key] == value for key, value in include.items() if key in matrix):
                matched = True
                for key, value in include.items():
                    combination.setdefault(key, value)
        if not matched:
            combinations.append(dict(include))
    return combinations


@dataclasses.dataclass
class Step:
    name: str
    script: str
    working_directory: str
    shell: str
    env: dict


@dataclasses.dataclass
class Leg:
    name: str
    steps: list
    in_container: bool
    env: dict
    timeout_seconds: int
    skipped_because: str | None = None

    def slug(self):
        return re.sub(r"[^A-Za-z0-9]+", "-", self.name).strip("-").lower()[:100]


def shell_command(shell):
    if shell == "bash":
        return "bash --noprofile --norc -eo pipefail"
    return "bash -e"


def steps_of(job, context, defaults_directory, repository):
    for step in job.get("steps", []):
        if not condition_holds(step.get("if"), context):
            continue
        uses = step.get("uses", "")
        if uses.startswith(ACTIONS_WITHOUT_LOCAL_MEANING):
            continue
        if uses.startswith("./"):
            action = yaml.safe_load((repository / uses / "action.yml").read_text())
            yield from steps_of(action["runs"], context, defaults_directory, repository)
            continue
        if uses:
            raise ValueError(f"local CI does not know the action {uses}")
        script = substitute(step["run"], context)
        if ONLY_INSTALLS_PACKAGES.match(script):
            continue
        yield Step(
            name=substitute(step.get("name") or script.splitlines()[0], context),
            script=HOST_SYSCTL.sub("", script),
            working_directory=substitute(step.get("working-directory", defaults_directory), context),
            shell=step.get("shell", "bash -e"),
            env={key: substitute(value, context) for key, value in (step.get("env") or {}).items()},
        )


def zig_build_flags(script):
    """The `-D` options of each `zig build` in a script, other than the target and optimize mode."""
    for command in re.findall(r"zig build ([^\n&|;]*)", script):
        arguments = command.split(" -- ")[0].split()
        yield tuple(sorted(argument for argument in arguments if argument.startswith("-D") and not argument.startswith(("-Dtarget=", "-Doptimize="))))


def legs_of(workflow, outputs_of_changes, repository):
    legs, cross_checks = [], {}
    for job_id, job in workflow["jobs"].items():
        if job_id == "changes":
            continue
        base_context = {"env": workflow.get("env", {}), "needs": {"changes": {"outputs": outputs_of_changes}}, "github": {"event_name": "push"}}
        if not condition_holds(job.get("if"), {**base_context, "runner": {"os": "Linux"}}):
            continue
        defaults_directory = ((job.get("defaults") or {}).get("run") or {}).get("working-directory", ".")
        timeout_seconds = 60 * int(job.get("timeout-minutes", 10))
        for matrix in matrix_combinations(job.get("strategy"), base_context):
            context = {**base_context, "matrix": matrix}
            runs_on = substitute(job["runs-on"], context)
            runner_os, cross_target = CROSS_TARGETS.get(runs_on, ("Linux", None))
            context["runner"] = {"os": runner_os, "temp": "$RUNNER_TEMP"}
            context["env"] = {**context["env"], **{key: substitute(value, context) for key, value in (job.get("env") or {}).items()}}
            steps = list(steps_of(job, context, defaults_directory, repository))
            if cross_target is None:
                legs.append(Leg(substitute(job.get("name", job_id), context), steps, True, context["env"], timeout_seconds))
                continue
            for step in steps:
                directory = os.path.normpath(step.working_directory)
                for flags in zig_build_flags(step.script):
                    cross_checks.setdefault((directory, cross_target, flags), set()).add(runs_on)
    for (directory, target, flags), runners in sorted(cross_checks.items()):
        command = shlex.join(["zig", "build", "check", f"-Dtarget={target}", *flags])
        name = f"{directory if directory != '.' else 'root'}: check {target}{''.join(' ' + flag for flag in flags)} (for {', '.join(sorted(runners))})"
        skipped_because = CROSS_CHECKS_NEEDING_AN_SDK.get((directory, target))
        legs.append(Leg(name, [Step(command, command, directory, "bash -e", {})], False, {}, 600, skipped_because))
    return legs


def ignored_by_workflow(workflow, changed_files):
    triggers = workflow.get("on", workflow.get(True, {}))
    patterns = ((triggers or {}).get("push") or {}).get("paths-ignore", [])

    def as_regex(pattern):
        return "^" + re.escape(pattern).replace(r"\*\*", ".*").replace(r"\*", "[^/]*") + "$"

    return bool(changed_files) and all(any(re.match(as_regex(pattern), path) for pattern in patterns) for path in changed_files)


def outputs_of_changes(workflow, worktree, base):
    """Runs the `changes` job's steps here, with the base this run was given."""
    job = workflow["jobs"]["changes"]
    outputs_file = worktree.parent / "changes-outputs"
    steps_outputs = {"base": {"outputs": {"base": base}}}
    for step in job["steps"]:
        if step.get("uses") or step.get("id") == "base":
            continue
        outputs_file.write_text("")
        context = {"steps": steps_outputs, "env": workflow.get("env", {})}
        env = {**os.environ, "GITHUB_OUTPUT": str(outputs_file), **{key: substitute(value, context) for key, value in (step.get("env") or {}).items()}}
        subprocess.run(["bash", "-e", "-c", substitute(step["run"], context)], cwd=worktree, env=env, check=True, stdout=subprocess.DEVNULL)
        values = dict(line.split("=", 1) for line in outputs_file.read_text().splitlines() if "=" in line)
        steps_outputs[step["id"]] = {"outputs": values}
    return {name: substitute(value, {"steps": steps_outputs}) for name, value in job.get("outputs", {}).items()}


def expanding(value):
    """Quoted for the shell, which still expands variables: `${{ runner.temp }}` becomes `$RUNNER_TEMP`."""
    return '"' + re.sub(r'(["\\`])', r"\\\1", str(value)) + '"'


def driver_script(leg, leg_directory, worktree):
    """One shell script that runs a leg's steps in order, as a runner would,
    carrying what each step appends to `$GITHUB_ENV` into the next."""
    lines = [
        "#!/bin/bash",
        "set -u",
        f"export RUNNER_TEMP=${{RUNNER_TEMP:-{shlex.quote(str(leg_directory / 'temp'))}}}",
        f"export GITHUB_ENV={shlex.quote(str(leg_directory / 'github-env'))}",
        f"export GITHUB_OUTPUT={shlex.quote(str(leg_directory / 'github-output'))}",
        f"export GITHUB_STEP_SUMMARY={shlex.quote(str(leg_directory / 'step-summary.md'))}",
        "mkdir -p \"$RUNNER_TEMP\" && : > \"$GITHUB_ENV\"",
        *(f"export {key}={expanding(value)}" for key, value in leg.env.items()),
    ]
    for index, step in enumerate(leg.steps):
        step_file = leg_directory / f"step-{index:02}.sh"
        step_file.write_text(step.script + "\n")
        exports = " ".join(f"{key}={expanding(value)}" for key, value in step.env.items())
        lines += [
            f"printf '\\n::: %s\\n' {shlex.quote(step.name)}",
            "while IFS= read -r line; do [ -n \"$line\" ] && export \"$line\"; done < \"$GITHUB_ENV\"",
            f"(cd {shlex.quote(str(worktree / step.working_directory))} && env {exports} {shell_command(step.shell)} {shlex.quote(str(step_file))}) || exit $?",
        ]
    driver = leg_directory / "run.sh"
    driver.write_text("\n".join(lines) + "\n")
    return driver


class Docker:
    def __init__(self, state):
        self.state = state
        self.through_group = self.needs_group_shell()
        self.running_containers = set()

    @staticmethod
    def in_docker_group(command):
        """`command` run with the docker group, which a session started
        before joining it lacks until the next login. `newgrp` reads the
        command from its standard input."""
        return ["sh", "-c", 'printf "%s\\n" "$0" | newgrp docker', shlex.join(command)]

    @classmethod
    def needs_group_shell(cls):
        if shutil.which("docker") is None:
            sys.exit("local CI: needs Docker for the Linux legs (https://docs.docker.com/engine/install/)")
        if subprocess.run(["docker", "info"], capture_output=True).returncode == 0:
            return False
        if shutil.which("newgrp") and subprocess.run(cls.in_docker_group(["docker", "info"]), capture_output=True).returncode == 0:
            return True
        sys.exit("local CI: cannot reach Docker; join its group (`sudo usermod -aG docker $USER`) and start it (`sudo systemctl enable --now docker.socket`)")

    def command(self, *arguments):
        command = ["docker", *arguments]
        return self.in_docker_group(command) if self.through_group else command

    def kill(self, container):
        subprocess.run(self.command("kill", container), capture_output=True)

    def image(self, workflow):
        """The image for the workflow in the current directory, built when its packages first appear."""
        packages = set()
        sources = [WORKFLOW.read_text(), *(path.read_text() for path in pathlib.Path(".github/actions").glob("*/action.yml"))]
        for source in sources:
            for match in PACKAGE_INSTALL.finditer(source):
                packages.update(word for word in match.group(1).split() if not word.startswith("-"))
        build_arguments = {"ZIG_VERSION": workflow["env"]["ZIG_VERSION"], "APT_PACKAGES": " ".join(sorted(packages))}
        fingerprint = hashlib.sha256((DOCKERFILE.read_text() + json.dumps(build_arguments, sort_keys=True)).encode()).hexdigest()[:16]
        tag = f"zui-local-ci:{fingerprint}"
        if subprocess.run(self.command("image", "inspect", tag), capture_output=True).returncode != 0:
            log = self.state / "image-build.log"
            print(f"local CI: building the container image {tag}, once for these packages; its log is {log}", flush=True)
            with log.open("w") as output:
                arguments = [argument for key, value in build_arguments.items() for argument in ("--build-arg", f"{key}={value}")]
                if subprocess.run(self.command("build", "-t", tag, *arguments, "-f", str(DOCKERFILE), str(DOCKERFILE.parent)), stdout=output, stderr=subprocess.STDOUT).returncode != 0:
                    sys.exit(f"local CI: building the container image failed; see {log}")
        return tag

    def run_arguments(self, image, driver, container, runner_temp):
        cache = self.state / "container-cache"
        (cache / "home").mkdir(parents=True, exist_ok=True)
        runner_temp.mkdir(parents=True, exist_ok=True)
        # The worktree lives in the git directory, which its own `.git` names by absolute path.
        mounted = str(self.state.parent)
        return self.command(
            "run", "--rm", "--init", "--name", container, "--user", f"{os.getuid()}:{os.getgid()}",
            # Chromium's sandbox needs user namespaces, which Docker's default seccomp profile refuses.
            "--security-opt", "seccomp=unconfined", "--shm-size=2g",
            "-v", f"{mounted}:{mounted}", "-v", f"{cache}:/cache",
            # A Unix socket's path, such as Weston's under $XDG_RUNTIME_DIR, fits in 108 bytes.
            "-v", f"{runner_temp}:/runner-temp", "-e", "RUNNER_TEMP=/runner-temp",
            # As setup-zig does: one cache, apart from the one this machine's builds use in the worktree.
            "-e", "ZIG_GLOBAL_CACHE_DIR=/cache/zig", "-e", "ZIG_LOCAL_CACHE_DIR=/cache/zig",
            "-e", "HOME=/cache/home", "-e", "GIT_TERMINAL_PROMPT=0", "-e", "CI=true",
            "-w", mounted, image, "bash", str(driver),
        )


def prepare_worktree(state, head):
    """A worktree of this repository's own, kept between runs so its build caches stay warm."""
    worktree = state / "worktree"
    if not (worktree / ".git").exists():
        shutil.rmtree(worktree, ignore_errors=True)
        git("worktree", "prune")
        git("worktree", "add", "--detach", str(worktree), head)
    git("checkout", "--detach", "--force", head, cwd=worktree)
    git("clean", "-ffdxq", "-e", ".zig-cache", "-e", "zig-pkg", cwd=worktree)
    return worktree


def run_leg(leg, leg_directory, worktree, docker, image):
    leg_directory.mkdir(parents=True)
    driver = driver_script(leg, leg_directory, worktree)
    container = f"zui-local-ci-{os.getpid()}-{leg_directory.name}"
    command = docker.run_arguments(image, driver, container, leg_directory / "temp") if leg.in_container else ["bash", str(driver)]
    log = leg_directory.with_suffix(".log")
    started = time.monotonic()
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        if leg.in_container:
            docker.running_containers.add(container)
        try:
            passed = process.wait(timeout=leg.timeout_seconds) == 0
        except subprocess.TimeoutExpired:
            if leg.in_container:
                docker.kill(container)
            os.killpg(process.pid, 9)
            process.wait()
            output.write(f"\nlocal CI: over the job's limit of {leg.timeout_seconds} s\n")
            passed = False
        if leg.in_container:
            docker.running_containers.discard(container)
    return passed, time.monotonic() - started, log


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="what the change is compared with, as CI's push is; the upstream branch by default")
    parser.add_argument("--head", default="HEAD", help="the commit tested; its files, never the working tree's")
    parser.add_argument("--all", action="store_true", help="run every job, as for a change to the workflow")
    parser.add_argument("--only", help="run only the legs whose names this regular expression matches")
    parser.add_argument("--list", action="store_true", help="print the legs that would run, and run none")
    parser.add_argument("--jobs", "-j", type=int, default=max(2, (os.cpu_count() or 4) // 4), help="legs run at once")
    return parser.parse_args()


def default_base():
    try:
        return git("rev-parse", "--verify", "--quiet", "@{upstream}")
    except subprocess.CalledProcessError:
        return ""


def main():
    arguments = parse_arguments()
    os.chdir(git("rev-parse", "--show-toplevel"))
    state = pathlib.Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "local-ci"
    state.mkdir(exist_ok=True)
    lock = (state / "lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("local CI: waiting for another run, which uses the same worktree", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
    head = git("rev-parse", "--verify", f"{arguments.head}^{{commit}}")
    base = "" if arguments.all else git("rev-parse", "--verify", f"{arguments.base}^{{commit}}") if arguments.base else default_base()
    if base and subprocess.run(["git", "merge-base", "--is-ancestor", base, head]).returncode != 0:
        print(f"local CI: {base[:12]} is not an ancestor of {head[:12]}, so every job runs", flush=True)
        base = ""

    changed_files = git("diff", "--name-only", base, head).splitlines() if base else []
    worktree = prepare_worktree(state, head)
    os.chdir(worktree)
    workflow = yaml.safe_load(WORKFLOW.read_text())
    if base and (not changed_files or ignored_by_workflow(workflow, changed_files)):
        print("local CI: nothing CI would run changed", flush=True)
        return 0

    outputs = outputs_of_changes(workflow, worktree, base)
    legs = legs_of(workflow, outputs, worktree)
    if arguments.only:
        legs = [leg for leg in legs if re.search(arguments.only, leg.name)]
    if arguments.list:
        for leg in legs:
            where = "skipped" if leg.skipped_because else "container" if leg.in_container else "here"
            print(f"{where:9}  {leg.name}")
        return 0
    for leg in legs:
        if leg.skipped_because:
            print(f"local CI: skipping {leg.name}: {leg.skipped_because}; CI alone checks it", flush=True)
    legs = [leg for leg in legs if not leg.skipped_because]
    if not legs:
        print("local CI: no job is affected", flush=True)
        return 0

    docker = Docker(state) if any(leg.in_container for leg in legs) else None
    image = docker.image(workflow) if docker else None
    runs = state / "runs"
    for old_run in sorted(runs.glob("*"))[:-RUNS_KEPT] if runs.exists() else []:
        shutil.rmtree(old_run, ignore_errors=True)
    run_directory = runs / time.strftime("%Y%m%d-%H%M%S")
    print(f"local CI: {len(legs)} legs of {head[:12]} against {base[:12] or 'nothing (every job)'}, {arguments.jobs} at once; logs in {run_directory}", flush=True)

    print_lock, failures, started = threading.Lock(), [], time.monotonic()

    def run_and_report(index, leg):
        passed, seconds, log = run_leg(leg, run_directory / f"{index:02}-{leg.slug()}", worktree, docker, image)
        with print_lock:
            print(f"  {'pass' if passed else 'FAIL'} {seconds:6.1f} s  {leg.name}", flush=True)
            if not passed:
                failures.append((leg, log))

    pool = concurrent.futures.ThreadPoolExecutor(arguments.jobs)
    try:
        for future in [pool.submit(run_and_report, index, leg) for index, leg in enumerate(legs)]:
            future.result()
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)
        for container in list(docker.running_containers if docker else []):
            docker.kill(container)
        os._exit(130)
    pool.shutdown()
    git("worktree", "prune")

    for leg, log in failures:
        print(f"\n--- {leg.name}: the end of {log}")
        print("\n".join(log.read_text(errors="replace").splitlines()[-FAILED_LOG_LINES:]))
    print(f"\nlocal CI: {len(legs) - len(failures)} of {len(legs)} legs passed in {time.monotonic() - started:.0f} s", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
