#!/usr/bin/env python3
# case-03: 로직이 tagLine 본문에 있고 새 private helper·helper class 가 없는가
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("tagLine")
c.check(body is not None, "ClientService.tagLine 없음")
if body is not None:
    c.check(JavaFile.count(body, "for (String tag : client.tags())") == 1, f"blueprint 의 for-each(String tag : client.tags()) 가 tagLine 본문에 없음: {body}")
    c.check(JavaFile.count(body, "line.append(tag.toUpperCase())") == 1, f"line.append(tag.toUpperCase()) 가 본문에 없음: {body}")
    c.check(JavaFile.count(body, "if (line.length() > 0)") == 1, f"구분자 분기(if (line.length() > 0)) 가 본문에 없음: {body}")
    c.check(JavaFile.locals_declared(body) == ["client", "line", "tag"], f"지역 변수는 client, line, (순회) tag 여야 함: {JavaFile.locals_declared(body)}")
    b = JavaFile.branches(body)
    c.check(b["if"] == 1 and b["ternary"] == 0 and b["try"] == 0 and b["null"] == 0 and b["stream"] == 0, f"문서에 없는 분기/fallback: {b}")
c.check(svc.methods() == base.methods() | {"tagLine"}, f"ClientService 메서드 집합이 base+tagLine 이 아님(helper 추출?): {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(not c.added_files(), f"새 파일(helper class?) 생성: {sorted(c.added_files())}")
c.finish()
