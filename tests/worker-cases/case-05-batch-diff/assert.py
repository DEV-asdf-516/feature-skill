#!/usr/bin/env python3
# case-05: batch 사양(diff → writeAll 1회)을 필드별 orchestration 으로 풀지 않았는가 — 동작·테스트가 맞아도 구조가 다르면 FAIL. local 이름·같은 클래스 private helper 는 워커 소유
import re
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("update")
c.check(body is not None, "ClientService.update 없음")
if body is not None:
    c.check(svc.norm.count("DiffUtil.diff(") == 1, f"DiffUtil.diff 호출이 ClientService 전체에서 {svc.norm.count('DiffUtil.diff(')}회")
    c.check(svc.norm.count("writeAll(") == 1, f"ClientService 전체에서 writeAll 호출이 {svc.norm.count('writeAll(')}회")
    c.check(len(re.findall(r"\.write\(", svc.norm)) == 0, "개별 write(...) 호출 존재")
    c.check(len(re.findall(r"==|!=", svc.norm.replace("!=null", ""))) == 0, "필드 equality 비교 존재")
    c.check(".equals(" not in svc.norm and "Objects.equals" not in svc.norm, "필드별 equals 비교 존재")
    c.check("new FieldChange(" not in svc.norm and "new ChangeLog(" not in svc.norm, "개별 change 생성 존재")
    ok, _ = JavaFile.order(body, "findOrThrow(id)", "DiffUtil.diff(", "writeAll(", "apply(update)", "repo.save(", "return")
    c.check(ok, "조회 → diff → writeAll → apply → save → 반환 순서 위반")
    b = JavaFile.branches(body)
    c.check(b["if"] + b["ternary"] + b["try"] + b["catch"] + b["switch"] + b["null"] + b["for"] + b["while"] + b["stream"] == 0, f"문서에 없는 분기/루프/fallback(필드별 if?): {b}")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"update"}, f"public 메서드 집합이 base+update 가 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(not c.added_files(), f"새 파일 생성: {sorted(c.added_files())}")
for f in ("src/DiffUtil.java", "src/ChangeLogWriter.java", "src/Client.java", "src/ClientUpdate.java"):
    c.check(c.base_java(f).norm == c.java(f).norm, f"{f} 가 변경됨 (범위 밖)")
c.finish()
