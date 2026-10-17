"""Read the test() definitions of a meson.build tree without meson.

dav1d's test data suite (dav1d-test-data) is a meson subdir: its meson.build
files define every test as test(name, program, suite:, args:) — the decoded
md5 of each stream, film grain / operating point / layer variants, the
oss-fuzz regression inputs. Upstream runs them with `meson test` in the build
tree; here the programs are installed and run on the target host (Windows
.exe natively), so run_dep_tests.py evaluates the same definitions with this
small interpreter for the subset of the meson language they use: assignments,
lists, dicts, if / foreach, files(), subdir(), get_option(), is_variable(),
string and list methods. Anything else raises MesonError, so a change in the
test data that needs more than this fails loudly instead of losing tests.

The files are evaluated, never executed as Python.
"""
import os
import re


class MesonError(Exception):
    def __init__(self, msg, located=False):
        super().__init__(msg)
        self.located = located      # message already names file:line


class _SubdirDone(Exception):
    pass


class _Break(Exception):
    pass


class _Continue(Exception):
    pass


class Program:
    """A build target used as a test program (resolved by the caller)."""
    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return f"Program({self.name})"


class File(str):
    """files() result: an absolute path."""


_TOKEN = re.compile(r"""
    (?P<ws>[ \t\r\f]+|\\\n)
  | (?P<comment>\#[^\n]*)
  | (?P<nl>\n)
  | (?P<mstr>'''.*?''')
  | (?P<str>'(?:[^'\\\n]|\\.)*')
  | (?P<num>0x[0-9a-fA-F]+|\d+)
  | (?P<id>[A-Za-z_][A-Za-z_0-9]*)
  | (?P<op>\+=|==|!=|<=|>=|[-+*/%()\[\]{},:.=<>?])
""", re.X | re.S)

_ESCAPES = {"\\": "\\", "'": "'", "n": "\n", "t": "\t", "r": "\r", "0": "\0"}


def _unescape(s):
    return re.sub(r"\\(.)", lambda m: _ESCAPES.get(m.group(1), "\\" + m.group(1)), s)


def _tokenize(text, path):
    """[(kind, value, line)]; newlines inside brackets are dropped."""
    tokens, depth, pos, line = [], 0, 0, 1
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise MesonError(f"{path}:{line}: unexpected character {text[pos]!r}", True)
        kind, value = m.lastgroup, m.group()
        if kind == "nl":
            if depth == 0:
                tokens.append(("nl", value, line))
        elif kind == "str":
            tokens.append(("str", _unescape(value[1:-1]), line))
        elif kind == "mstr":
            tokens.append(("str", value[3:-3], line))
        elif kind == "num":
            tokens.append(("num", int(value, 0), line))
        elif kind in ("id", "op"):
            if value in "([{":
                depth += 1
            elif value in ")]}":
                depth -= 1
            tokens.append((kind, value, line))
        line += value.count("\n")
        pos = m.end()
    tokens.append(("nl", "\n", line))
    tokens.append(("eof", None, line))
    return tokens


class _Parser:
    """Recursive descent parser: statements -> nested tuples (AST)."""
    def __init__(self, tokens, path):
        self.t, self.i, self.path = tokens, 0, path

    def peek(self, k=0):
        return self.t[self.i + k]

    def error(self, msg):
        raise MesonError(f"{self.path}:{self.peek()[2]}: {msg}", True)

    def accept(self, value):
        if self.peek()[1] == value and self.peek()[0] in ("op", "id"):
            self.i += 1
            return True
        return False

    def expect(self, value):
        if not self.accept(value):
            self.error(f"expected {value!r}, got {self.peek()[1]!r}")

    def skip_nl(self):
        while self.peek()[0] == "nl":
            self.i += 1

    def block(self, *end):
        body = []
        while True:
            self.skip_nl()
            tok = self.peek()
            if tok[0] == "eof":
                if end:
                    self.error(f"missing {end[0]}")
                return body
            if tok[0] == "id" and tok[1] in end:
                return body
            body.append(self.statement())

    def statement(self):
        kind, value, line = self.peek()
        if kind == "id" and value == "if":
            self.i += 1
            branches = [(self.expr(), self.block("elif", "else", "endif"))]
            orelse = []
            while True:
                if self.accept("elif"):
                    branches.append((self.expr(), self.block("elif", "else", "endif")))
                elif self.accept("else"):
                    orelse = self.block("endif")
                else:
                    self.expect("endif")
                    return ("if", branches, orelse, line)
        if kind == "id" and value == "foreach":
            self.i += 1
            names = [self.ident()]
            while self.accept(","):
                names.append(self.ident())
            self.expect(":")
            items = self.expr()
            body = self.block("endforeach")
            self.expect("endforeach")
            return ("foreach", names, items, body, line)
        if kind == "id" and value in ("break", "continue"):
            self.i += 1
            return (value, line)
        if kind == "id" and self.peek(1)[1] in ("=", "+=") and self.peek(1)[0] == "op":
            self.i += 2
            return ("assign", value, self.peek(-1)[1], self.expr(), line)
        return ("expr", self.expr(), line)

    def ident(self):
        kind, value, _ = self.peek()
        if kind != "id":
            self.error(f"expected a name, got {value!r}")
        self.i += 1
        return value

    def expr(self):
        cond = self.or_expr()
        if self.accept("?"):
            a = self.expr()
            self.expect(":")
            return ("cond", cond, a, self.expr())
        return cond

    def or_expr(self):
        a = self.and_expr()
        while self.accept("or"):
            a = ("or", a, self.and_expr())
        return a

    def and_expr(self):
        a = self.not_expr()
        while self.accept("and"):
            a = ("and", a, self.not_expr())
        return a

    def not_expr(self):
        if self.accept("not"):
            return ("not", self.not_expr())
        return self.cmp_expr()

    def cmp_expr(self):
        a = self.add_expr()
        while True:
            tok = self.peek()
            if tok[0] == "op" and tok[1] in ("==", "!=", "<", ">", "<=", ">="):
                self.i += 1
                a = ("bin", tok[1], a, self.add_expr())
            elif tok[1] == "in" and tok[0] == "id":
                self.i += 1
                a = ("bin", "in", a, self.add_expr())
            elif tok[1] == "not" and self.peek(1)[1] == "in":
                self.i += 2
                a = ("not", ("bin", "in", a, self.add_expr()))
            else:
                return a

    def add_expr(self):
        a = self.mul_expr()
        while self.peek()[0] == "op" and self.peek()[1] in "+-":
            op = self.peek()[1]
            self.i += 1
            a = ("bin", op, a, self.mul_expr())
        return a

    def mul_expr(self):
        a = self.unary()
        while self.peek()[0] == "op" and self.peek()[1] in ("*", "/", "%"):
            op = self.peek()[1]
            self.i += 1
            a = ("bin", op, a, self.unary())
        return a

    def unary(self):
        if self.accept("-"):
            return ("neg", self.unary())
        return self.postfix()

    def postfix(self):
        a = self.primary()
        while True:
            if self.accept("."):
                name = self.ident()
                self.expect("(")
                args, kwargs = self.arguments()
                a = ("method", a, name, args, kwargs)
            elif self.accept("["):
                idx = self.expr()
                self.expect("]")
                a = ("index", a, idx)
            else:
                return a

    def arguments(self):
        args, kwargs = [], {}
        while not self.accept(")"):
            if self.peek()[0] == "id" and self.peek(1)[1] == ":" and self.peek(1)[0] == "op":
                name = self.ident()
                self.i += 1
                kwargs[name] = self.expr()
            else:
                args.append(self.expr())
            if not self.accept(","):
                self.expect(")")
                break
        return args, kwargs

    def primary(self):
        kind, value, _ = self.peek()
        self.i += 1
        if kind in ("str", "num"):
            return ("lit", value)
        if kind == "id":
            if value in ("true", "false"):
                return ("lit", value == "true")
            if self.accept("("):
                args, kwargs = self.arguments()
                return ("call", value, args, kwargs)
            return ("id", value)
        if value == "(":
            e = self.expr()
            self.expect(")")
            return e
        if value == "[":
            items = []
            while not self.accept("]"):
                items.append(self.expr())
                if not self.accept(","):
                    self.expect("]")
                    break
            return ("list", items)
        if value == "{":
            items = []
            while not self.accept("}"):
                k = self.expr()
                self.expect(":")
                items.append((k, self.expr()))
                if not self.accept(","):
                    self.expect("}")
                    break
            return ("dict", items)
        self.i -= 1
        self.error(f"unexpected {value!r}")


def _flatten(values):
    out = []
    for v in values:
        if isinstance(v, list):
            out += _flatten(v)
        else:
            out.append(v)
    return out


class Interpreter:
    """Evaluates a meson.build tree and collects its test() calls.

    variables: predefined variables (Program objects for the build targets,
               e.g. dav1d_bitdepths); options: get_option() values.
    tests: [{"name", "program", "args", "suites", "timeout", "should_fail", "where"}]
    """
    def __init__(self, variables, options):
        self.vars = dict(variables)
        self.options = dict(options)
        self.tests = []
        self.dir = None

    # ── entry ──────────────────────────────────────────────────────────────
    def run_file(self, directory):
        path = os.path.join(directory, "meson.build")
        with open(path, encoding="utf-8") as f:
            text = f.read()
        tree = _Parser(_tokenize(text, path), path).block()
        saved, self.dir = self.dir, directory
        try:
            self.exec_block(tree)
        except _SubdirDone:
            pass
        finally:
            self.dir = saved

    # ── statements ─────────────────────────────────────────────────────────
    def exec_block(self, body):
        for stmt in body:
            self.exec_stmt(stmt)

    def exec_stmt(self, stmt):
        kind = stmt[0]
        try:
            if kind == "expr":
                self.evaluate(stmt[1])
            elif kind == "assign":
                _, name, op, e, _ = stmt
                value = self.evaluate(e)
                if op == "+=":
                    value = self.add(self.lookup(name), value)
                self.vars[name] = value
            elif kind == "if":
                for cond, body in stmt[1]:
                    if self.truth(self.evaluate(cond)):
                        self.exec_block(body)
                        break
                else:
                    self.exec_block(stmt[2])
            elif kind == "foreach":
                _, names, items_e, body, _ = stmt
                items = self.evaluate(items_e)
                seq = items.items() if isinstance(items, dict) else items
                for item in list(seq):
                    if len(names) == 1:
                        self.vars[names[0]] = item
                    else:
                        if not isinstance(item, tuple) or len(item) != len(names):
                            raise MesonError(f"foreach: cannot unpack {item!r}")
                        for n, v in zip(names, item):
                            self.vars[n] = v
                    try:
                        self.exec_block(body)
                    except _Continue:
                        continue
                    except _Break:
                        break
            elif kind == "break":
                raise _Break()
            elif kind == "continue":
                raise _Continue()
        except MesonError as e:
            if e.located:
                raise
            raise MesonError(f"{os.path.join(self.dir, 'meson.build')}:{stmt[-1]}: {e}", True) from None

    # ── expressions ────────────────────────────────────────────────────────
    def lookup(self, name):
        if name not in self.vars:
            raise MesonError(f"unknown variable {name!r}")
        return self.vars[name]

    @staticmethod
    def truth(v):
        if not isinstance(v, bool):
            raise MesonError(f"condition is not a boolean: {v!r}")
        return v

    @staticmethod
    def add(a, b):
        if isinstance(a, list):
            return a + (b if isinstance(b, list) else [b])
        if isinstance(a, dict) and isinstance(b, dict):
            return {**a, **b}
        if type(a) is type(b) or (isinstance(a, str) and isinstance(b, str)):
            return a + b
        raise MesonError(f"cannot add {a!r} and {b!r}")

    def evaluate(self, e):
        kind = e[0]
        if kind == "lit":
            return e[1]
        if kind == "id":
            return self.lookup(e[1])
        if kind == "list":
            return [self.evaluate(x) for x in e[1]]
        if kind == "dict":
            return {self.evaluate(k): self.evaluate(v) for k, v in e[1]}
        if kind == "cond":
            return self.evaluate(e[2]) if self.truth(self.evaluate(e[1])) else self.evaluate(e[3])
        if kind == "not":
            return not self.truth(self.evaluate(e[1]))
        if kind == "and":
            return self.truth(self.evaluate(e[1])) and self.truth(self.evaluate(e[2]))
        if kind == "or":
            return self.truth(self.evaluate(e[1])) or self.truth(self.evaluate(e[2]))
        if kind == "neg":
            return -self.evaluate(e[1])
        if kind == "index":
            obj, idx = self.evaluate(e[1]), self.evaluate(e[2])
            try:
                return obj[idx]
            except (IndexError, KeyError, TypeError):
                raise MesonError(f"bad index {idx!r} into {obj!r}") from None
        if kind == "bin":
            op, a, b = e[1], self.evaluate(e[2]), self.evaluate(e[3])
            if op == "+":
                return self.add(a, b)
            if op == "in":
                return a in b
            ops = {"-": lambda: a - b, "*": lambda: a * b, "/": lambda: self.div(a, b),
                   "%": lambda: a % b, "==": lambda: a == b, "!=": lambda: a != b,
                   "<": lambda: a < b, ">": lambda: a > b, "<=": lambda: a <= b,
                   ">=": lambda: a >= b}
            return ops[op]()
        if kind == "call":
            return self.call(e[1], [self.evaluate(a) for a in e[2]],
                             {k: self.evaluate(v) for k, v in e[3].items()})
        if kind == "method":
            return self.method(self.evaluate(e[1]), e[2], [self.evaluate(a) for a in e[3]],
                               {k: self.evaluate(v) for k, v in e[4].items()})
        raise MesonError(f"cannot evaluate {kind}")

    @staticmethod
    def div(a, b):
        if isinstance(a, str):          # path join operator
            return os.path.join(a, b)
        return a // b

    # ── functions ──────────────────────────────────────────────────────────
    def call(self, name, args, kwargs):
        if name == "files":
            return [File(os.path.normpath(os.path.join(self.dir, p))) for p in _flatten(args)]
        if name == "test":
            if len(args) != 2:
                raise MesonError("test() takes a name and a program")
            known = {"args", "suite", "timeout", "should_fail", "is_parallel", "workdir",
                     "env", "priority", "verbose", "protocol", "depends"}
            unknown = set(kwargs) - known
            if unknown:
                raise MesonError(f"test(): unsupported keyword(s) {sorted(unknown)}")
            if not isinstance(args[1], Program):
                raise MesonError(f"test(): {args[1]!r} is not a program")
            suites = kwargs.get("suite", [])
            self.tests.append({
                "name": args[0],
                "program": args[1].name,
                "args": [str(a) for a in _flatten([kwargs.get("args", [])])],
                "suites": suites if isinstance(suites, list) else [suites],
                "timeout": kwargs.get("timeout", 30),
                "should_fail": kwargs.get("should_fail", False),
                "where": os.path.join(self.dir, "meson.build"),
            })
            return None
        if name in ("benchmark", "add_test_setup", "message", "warning", "summary"):
            return None
        if name == "error":
            raise MesonError("error(): " + " ".join(map(str, args)))
        if name == "get_option":
            if args[0] not in self.options:
                raise MesonError(f"unknown option {args[0]!r}")
            return self.options[args[0]]
        if name == "is_variable":
            return args[0] in self.vars
        if name == "get_variable":
            return self.vars[args[0]] if args[0] in self.vars else args[1]
        if name == "set_variable":
            self.vars[args[0]] = args[1]
            return None
        if name == "join_paths":
            return os.path.join(*args)
        if name == "subdir":
            self.run_file(os.path.join(self.dir, args[0]))
            return None
        if name == "subdir_done":
            raise _SubdirDone()
        raise MesonError(f"unsupported function {name}()")

    def method(self, obj, name, args, kwargs):
        if isinstance(obj, list):
            if name == "contains":
                return args[0] in _flatten(obj)
            if name == "length":
                return len(obj)
            if name == "get":
                return obj[args[0]] if -len(obj) <= args[0] < len(obj) else args[1]
        elif isinstance(obj, dict):
            if name == "has_key":
                return args[0] in obj
            if name == "get":
                return obj[args[0]] if args[0] in obj else args[1]
            if name == "keys":
                return sorted(obj)
        elif isinstance(obj, str):
            simple = {"startswith": lambda: obj.startswith(args[0]),
                      "endswith": lambda: obj.endswith(args[0]),
                      "contains": lambda: args[0] in obj,
                      "to_lower": lambda: obj.lower(), "to_upper": lambda: obj.upper(),
                      "strip": lambda: obj.strip(), "split": lambda: obj.split(*args),
                      "to_int": lambda: int(obj)}
            if name in simple:
                return simple[name]()
            if name == "format":
                return re.sub(r"@(\d+)@", lambda m: str(args[int(m.group(1))]), obj)
            if name == "join":
                return obj.join(_flatten(args))
        raise MesonError(f"unsupported method {type(obj).__name__}.{name}()")


def load_tests(root, programs, options, variables=None):
    """Evaluate <root>/meson.build. programs: names of the build targets the
    tree may use (variables of type Program); options: get_option() values;
    variables: other variables the including project defines."""
    names = {name: Program(name) for name in programs}
    names.update(variables or {})
    interp = Interpreter(names, options)
    interp.run_file(os.path.abspath(root))
    return interp.tests
