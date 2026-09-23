#!/usr/bin/env python3
# case-04: 문서가 지역 변수 이름·줄 구조를 정하지 않았다 — 워커가 DOC_GAP 없이 DONE 하고 material 순서(조회 → 사본 → save 1회 → 반환)만 지키는가
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
c.check(c.result.get("status") == "DONE", f"status 가 DONE 이 아님(local 이름 때문에 DOC_GAP?): {c.result.get('status')} {c.result.get('undecided')}")
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("rename")
c.check(body is not None, "ClientService.rename 없음")
if body is not None:
    ok, pos = JavaFile.order(body, "findOrThrow(id)", "withName(newName)", "repo.save(", "return")
    c.check(ok, f"조회 → 사본 → 저장 → 반환 순서 위반 (positions {pos}): {body}")
    c.check(JavaFile.count(body, "repo.save(") == 1, f"repo.save 호출이 정확히 1회가 아님: {body}")
    c.check(JavaFile.count(body, "withName(") == 1, f"withName 호출이 정확히 1회가 아님: {body}")
    c.check(sum(JavaFile.branches(body).values()) == 0, f"문서에 없는 분기/fallback: {JavaFile.branches(body)}")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"rename"}, f"public 메서드 집합이 base+rename 이 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(base.method_body("changePhone") == svc.method_body("changePhone"), "기존 changePhone 이 변경됨")
c.check(not c.added_files(), f"새 파일 생성: {sorted(c.added_files())}")
c.finish()
