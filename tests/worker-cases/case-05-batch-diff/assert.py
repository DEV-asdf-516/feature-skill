#!/usr/bin/env python3
# case-05: batch 사양(diff → writeAll 1회)을 필드별 orchestration 으로 풀지 않았는가 — 동작·테스트가 맞아도 구조가 다르면 FAIL
import re
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("update")
c.check(body is not None, "ClientService.update 없음")
if body is not None:
    c.check(JavaFile.count(body, "DiffUtil.diff(before.fields(), update.fields())") == 1, f"DiffUtil.diff(before.fields(), update.fields()) 호출이 정확히 1회가 아님: {body}")
    c.check(JavaFile.count(body, "changeLogs.writeAll(id, changes)") == 1, f"changeLogs.writeAll(id, changes) 호출이 정확히 1회가 아님: {body}")
    c.check(svc.norm.count("writeAll(") == 1, f"ClientService 전체에서 writeAll 호출이 {svc.norm.count('writeAll(')}회")
    c.check(len(re.findall(r"\.write\(", svc.norm)) == 0, "개별 write(...) 호출 존재")
    c.check(len(re.findall(r"==|!=", body)) == 0, f"필드 equality 비교 존재: {body}")
    c.check(".equals(" not in body and "Objects.equals" not in body, f"필드별 equals 비교 존재: {body}")
    c.check(JavaFile.locals_declared(body) == ["before", "changes", "after"], f"지역 변수는 before, changes, after 여야 함: {JavaFile.locals_declared(body)}")
    ok, _ = JavaFile.order(body, "findOrThrow(id)", "DiffUtil.diff(", "writeAll(", "before.apply(update)", "repo.save(after)", "return after")
    c.check(ok, "조회 → diff → writeAll → apply → save → 반환 순서 위반")
    b = JavaFile.branches(body)
    c.check(sum(b.values()) == 0, f"문서에 없는 분기/루프/fallback(필드별 if?): {b}")
    c.check("new FieldChange(" not in body and "new ChangeLog(" not in body and "put(" not in body and "add(" not in body, f"개별 change 생성·수집 orchestration 존재: {body}")
c.check(svc.methods() == base.methods() | {"update"}, f"ClientService 메서드 집합이 base+update 가 아님(helper 추출?): {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(not c.added_files(), f"새 파일 생성: {sorted(c.added_files())}")
for f in ("src/DiffUtil.java", "src/ChangeLogWriter.java", "src/Client.java", "src/ClientUpdate.java"):
    c.check(c.base_java(f).norm == c.java(f).norm, f"{f} 가 변경됨 (범위 밖)")
c.finish()
