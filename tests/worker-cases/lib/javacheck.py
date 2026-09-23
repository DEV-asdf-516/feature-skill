"""worker regression 공용 assertion 헬퍼 — LLM 없이 Java source 구조를 결정론적으로 검사한다.

포맷(공백·줄바꿈·import 순서)에 영향받지 않도록 주석·문자열을 제거하고 공백을 정규화한 뒤 본다.
언어 문법 전체를 파싱하지 않는다 — 회귀 픽스처처럼 작은 클래스에서 메서드 집합·본문·호출 순서·분기 존재를 보는 용도다.

사용 (case 의 assert.py):
    from javacheck import Case
    c = Case(sys.argv[1], sys.argv[2])            # target repo, worker-result.json
    svc = c.java("src/ClientService.java")
    c.check(svc.methods() == {...}, "...")
    c.finish()                                    # 실패가 있으면 exit 1
"""
import json
import os
import re
import subprocess
import sys


def _strip_comments_and_strings(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i < n - 1 and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif ch == '"':
            # 문자열 리터럴은 자리표시자로 — 리터럴 안의 키워드·기호가 검사에 잡히지 않게 한다
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append('"S"')
        elif ch == "'":
            i += 1
            while i < n and src[i] != "'":
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append("'C'")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def normalize(src: str) -> str:
    """주석·문자열 제거 + 공백 정규화(연속 공백 → 한 칸, 괄호·기호 주변 공백 제거)."""
    s = _strip_comments_and_strings(src)
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"\s*([(){}\[\];,.<>=!+\-*/?:&|])\s*", r"\1", s)
    return s.strip()


_METHOD_RE = re.compile(
    r"(?:(?:public|private|protected|static|final|synchronized|abstract|default)\s+)*"
    r"(?:<[^>]+>\s*)?"
    r"([\w.]+(?:<[^>]*>)?(?:\[\])*)\s+"   # 반환 타입
    r"(\w+)\s*\(([^)]*)\)\s*(?:throws [\w., ]+)?\s*\{"
)
_TYPE_DECL_RE = re.compile(r"\b(class|interface|enum|record)\s+(\w+)")
_MODIFIERS = {"public", "private", "protected", "static", "final", "synchronized", "abstract", "default"}
_NOT_A_TYPE = _MODIFIERS | {"new", "return", "else", "throw", "case", "import", "package"}
_LOCAL_KEYWORDS = _NOT_A_TYPE | {"break", "continue", "goto", "instanceof"}


class JavaFile:
    def __init__(self, path: str, raw: str):
        self.path = path
        self.raw = raw
        self.clean = _strip_comments_and_strings(raw)
        self.norm = normalize(raw)

    # ----- 선언 -----
    def methods(self) -> set:
        """선언된 메서드 이름 집합 (생성자·제어문 제외)."""
        names = set()
        for m in _METHOD_RE.finditer(self.clean):
            rtype, name = m.group(1), m.group(2)
            # 생성자(`public Foo(` 는 type=public, name=Foo 로 잡힌다)·키워드·제어문은 메서드가 아니다
            if rtype in _NOT_A_TYPE or name in ("if", "for", "while", "switch", "catch", "synchronized"):
                continue
            names.add(name)
        return names

    def private_methods(self) -> set:
        names = set()
        for m in re.finditer(r"\bprivate\s+(?:static\s+)?(?:final\s+)?[\w.<>\[\]]+\s+(\w+)\s*\(", self.clean):
            names.add(m.group(1))
        return names

    def types(self) -> set:
        """선언된 class/interface/enum/record 이름 집합 (중첩 포함)."""
        return {m.group(2) for m in _TYPE_DECL_RE.finditer(self.clean)}

    def method_body(self, name: str) -> str:
        """메서드 본문(중괄호 안)을 정규화 문자열로. 없으면 None. 같은 이름이 여럿이면 첫 번째."""
        m = re.search(r"\b" + re.escape(name) + r"\s*\([^)]*\)\s*(?:throws [\w., ]+)?\s*\{", self.clean)
        if not m:
            return None
        i = m.end()
        depth = 1
        j = i
        while j < len(self.clean) and depth > 0:
            if self.clean[j] == "{":
                depth += 1
            elif self.clean[j] == "}":
                depth -= 1
            j += 1
        return normalize(self.clean[i:j - 1])

    def method_signature(self, name: str) -> str:
        m = re.search(r"((?:(?:public|private|protected|static|final)\s+)*[\w.<>\[\]]+\s+" + re.escape(name) + r"\s*\([^)]*\))\s*(?:throws [\w., ]+)?\s*\{", self.clean)
        return normalize(m.group(1)) if m else None

    # ----- 본문 질의 -----
    @staticmethod
    def count(body: str, needle: str) -> int:
        return body.count(normalize(needle)) if body is not None else 0

    @staticmethod
    def order(body: str, *needles: str):
        """needles 가 body 에 모두 있고 그 순서대로 처음 등장하면 True. 아니면 (False, 위치 목록)."""
        pos = [body.find(normalize(x)) for x in needles]
        return all(p >= 0 for p in pos) and pos == sorted(pos), pos

    @staticmethod
    def locals_declared(body: str) -> list:
        """본문의 지역 변수 선언 이름 목록 (`Type name=` / `Type name;` 형태, for-each 변수 포함)."""
        out = []
        # 정규화 뒤에는 `Map<String,X>changes=` 처럼 generic/배열 뒤 공백이 없다 — 그 경우만 공백 없이 이름을 허용한다
        for m in re.finditer(r"(?:^|[;{}(])\s*(?:final\s+)?([\w.]+)(?:(?:<[^>]*>|\[\])+\s*|\s+)(\w+)\s*(?=[=;:])", body):
            if m.group(1) in _LOCAL_KEYWORDS:   # `return x;` / `throw e;` 는 선언이 아니다
                continue
            out.append(m.group(2))
        return out

    @staticmethod
    def branches(body: str) -> dict:
        """분기·fallback 관련 토큰 수: if / ?: / try / catch / switch / null / for / while / stream."""
        return {
            "if": len(re.findall(r"\bif\(", body)),
            "ternary": body.count("?"),
            "try": len(re.findall(r"\btry\b", body)),
            "catch": len(re.findall(r"\bcatch\b", body)),
            "switch": len(re.findall(r"\bswitch\b", body)),
            "null": len(re.findall(r"\bnull\b", body)),
            "for": len(re.findall(r"\bfor\(", body)),
            "while": len(re.findall(r"\bwhile\(", body)),
            "stream": len(re.findall(r"\.stream\(", body)),
        }


class Case:
    """target 저장소 + 워커 결과에 대한 assertion 누적기."""

    def __init__(self, target: str, result_json: str):
        self.target = target
        self.result = json.load(open(result_json)) if os.path.exists(result_json) else {}
        self.failures = []
        self._before = self._read_tree("worker-before.tree")
        self._after = self._read_tree("worker-after.tree")

    def _read_tree(self, name: str):
        units = os.path.join(self.target, ".agent-work", "units")
        if not os.path.isdir(units):
            return None
        for uid in sorted(os.listdir(units)):
            p = os.path.join(units, uid, name)
            if os.path.exists(p):
                return open(p).read().strip()
        return None

    def check(self, cond: bool, msg: str):
        if not cond:
            self.failures.append(msg)
        return cond

    def java(self, rel: str) -> JavaFile:
        p = os.path.join(self.target, rel)
        if not os.path.exists(p):
            self.failures.append(f"파일 없음: {rel}")
            return JavaFile(rel, "")
        return JavaFile(rel, open(p, encoding="utf-8").read())

    def exists(self, rel: str) -> bool:
        return os.path.exists(os.path.join(self.target, rel))

    def changed_files(self) -> dict:
        """호출 전후 tree 의 변경 {path: status(A|M|D|T)} — 러너가 남긴 worker-before/after.tree 기준."""
        if not self._before or not self._after:
            return {}
        out = subprocess.run(
            ["git", "-C", self.target, "diff-tree", "-r", "--name-status", self._before, self._after],
            capture_output=True, text=True, check=True,
        ).stdout
        res = {}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                res[parts[-1]] = parts[0][0]
        return res

    def added_files(self) -> set:
        return {p for p, s in self.changed_files().items() if s == "A"}

    def base_java(self, rel: str) -> JavaFile:
        """호출 전 tree(before) 의 파일 — 새 메서드/타입이 늘었는지 대조할 때."""
        if not self._before:
            return JavaFile(rel, "")
        out = subprocess.run(["git", "-C", self.target, "show", f"{self._before}:{rel}"], capture_output=True, text=True)
        return JavaFile(rel, out.stdout if out.returncode == 0 else "")

    def finish(self):
        if self.failures:
            for f in self.failures:
                print(f"  [ASSERT FAIL] {f}")
            sys.exit(1)
        print("  [ASSERT OK]")
        sys.exit(0)
