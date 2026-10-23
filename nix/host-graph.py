# host-graph.py <vendor dir> <cfg file>...: make build scripts and proc macros get the same
# dependencies on every build host.
#
# Cargo resolves the dependencies of build scripts and proc macros for the
# machine running the build, and every crate's metadata hash takes in theirs,
# so a platform condition that differs between build hosts changes the
# symbol names of every crate downstream. Each cfg file holds `rustc --print
# cfg` for one build host. A vendored manifest's platform condition that
# evaluates differently across them becomes cfg(any(dnix_host, ...)). The
# rustc wrapper adds dnix_host to the configuration Cargo reads for the host
# only, so build-time dependencies are the union on every build host while
# the targets' dependencies stay exactly as written.
import pathlib, re, sys, tomllib

def load(path):
    pairs, flags = set(), set()
    for line in pathlib.Path(path).read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            pairs.add((key, value.strip('"')))
        elif line:
            flags.add(line)
    return pathlib.Path(path).name, pairs, flags

hosts = [load(path) for path in sys.argv[2:]]

def holds(expression, host):
    triple, pairs, flags = host
    if not expression.startswith("cfg("):
        return expression == triple
    tokens = re.findall(r'[A-Za-z_][A-Za-z0-9_]*|"[^"]*"|[(),=]', expression[4:-1])
    position = 0
    def term():
        nonlocal position
        token = tokens[position]
        position += 1
        if token in ("all", "any", "not") and tokens[position] == "(":
            position += 1
            values = []
            while tokens[position] != ")":
                values.append(term())
                if tokens[position] == ",":
                    position += 1
            position += 1
            if token == "all":
                return all(values)
            if token == "any":
                return any(values)
            return not values[0]
        if position < len(tokens) and tokens[position] == "=":
            value = tokens[position + 1].strip('"')
            position += 2
            return (token, value) in pairs
        return token in flags
    return term()

def widened(expression):
    if expression.startswith("cfg("):
        inner = expression[4:-1]
    else:
        # A target triple: match it by the parts rustc reports for it.
        _, pairs, _ = next(host for host in hosts if host[0] == expression)
        parts = [f'{key} = "{value}"' for key, value in sorted(pairs)
                 if key in ("target_arch", "target_os", "target_env", "target_vendor", "target_abi")]
        inner = f"all({', '.join(parts)})"
    return f"cfg(any(dnix_host, {inner}))"

for manifest in sorted(pathlib.Path(sys.argv[1]).glob("*/Cargo.toml")):
    text = manifest.read_text()
    targets = tomllib.loads(text).get("target", {})
    changed = {key: widened(key) for key in targets
               if len({holds(key, host) for host in hosts}) > 1}
    if not changed:
        continue
    for old, new in changed.items():
        # The key as TOML may spell it: literal, basic with escapes, or bare.
        spellings = [f"'{old}'", '"' + old.replace("\\", "\\\\").replace('"', '\\"') + '"']
        if re.fullmatch(r"[A-Za-z0-9_-]+", old):
            spellings.append(old)
        for spelling in spellings:
            text = text.replace(f"[target.{spelling}.", f"[target.'{new}'.")
    expected = {changed.get(key, key): value for key, value in targets.items()}
    if any("'" in new for new in changed.values()) or tomllib.loads(text).get("target", {}) != expected:
        sys.exit(f"{manifest}: could not widen its host-dependent platform conditions")
    manifest.write_text(text)
    print(f"{manifest.parent.name}: {len(changed)} platform condition(s) widened for build scripts and proc macros")
