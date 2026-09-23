#!/usr/bin/env python3
# case-03: 로직이 ClientService 안에 있고 새 helper class·새 파일이 없는가 — 같은 클래스 안의 private helper·for/stream·local 이름은 워커 소유
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("tagLine")
c.check(body is not None, "ClientService.tagLine 없음")
if body is not None:
    c.check(JavaFile.count(body, "findOrThrow(id)") == 1, f"findOrThrow(id) 호출이 정확히 1회가 아님: {body}")
    c.check("toUpperCase" in svc.norm, "대문자화가 ClientService 안에 없음(helper class 로 나감?)")
    b = JavaFile.branches(body)
    c.check(b["try"] + b["catch"] + b["null"] == 0, f"문서에 없는 방어 분기/fallback: {b}")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"tagLine"}, f"public 메서드 집합이 base+tagLine 이 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(not c.added_files(), f"새 파일(helper class?) 생성: {sorted(c.added_files())}")
c.finish()
