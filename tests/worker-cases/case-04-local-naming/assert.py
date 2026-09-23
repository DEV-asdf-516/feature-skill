#!/usr/bin/env python3
# case-04: 문서가 정한 지역 변수 이름(client, renamed)과 네 줄 구조를 그대로 썼는가
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("rename")
c.check(body is not None, "ClientService.rename 없음")
if body is not None:
    names = JavaFile.locals_declared(body)
    c.check(names == ["client", "renamed"], f"지역 변수 이름이 문서(client, renamed)와 다름: {names}")
    c.check(JavaFile.count(body, "Client client = findOrThrow(id);") == 1, f"'Client client = findOrThrow(id);' 없음: {body}")
    c.check(JavaFile.count(body, "Client renamed = client.withName(newName);") == 1, f"'Client renamed = client.withName(newName);' 없음: {body}")
    c.check(JavaFile.count(body, "repo.save(renamed);") == 1, f"'repo.save(renamed);' 없음: {body}")
    c.check(JavaFile.count(body, "return renamed;") == 1, f"'return renamed;' 없음: {body}")
    ok, _ = JavaFile.order(body, "findOrThrow(id)", "withName(newName)", "repo.save(renamed)", "return renamed")
    c.check(ok, "조회 → 사본 → 저장 → 반환 순서 위반")
    c.check(sum(JavaFile.branches(body).values()) == 0, f"문서에 없는 분기/fallback: {JavaFile.branches(body)}")
c.check(svc.methods() == base.methods() | {"rename"}, f"ClientService 메서드 집합이 base+rename 이 아님: {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(base.method_body("changePhone") == svc.method_body("changePhone"), "기존 changePhone 이 변경됨")
c.check(not c.added_files(), f"새 파일 생성: {sorted(c.added_files())}")
c.finish()
