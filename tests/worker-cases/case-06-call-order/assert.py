#!/usr/bin/env python3
# case-06: 호출 순서(lookup → transform → publish → return)와 분기·fallback 부재
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("publishProfile")
c.check(body is not None, "ClientService.publishProfile 없음")
if body is not None:
    ok, pos = JavaFile.order(body, "findOrThrow(id)", "new ClientProfile(client.id(), client.name())", "publisher.publish(profile)", "return profile")
    c.check(ok, f"lookup → transform → publish → return 순서 위반 (positions {pos}): {body}")
    c.check(JavaFile.count(body, "publisher.publish(profile)") == 1, "publish 호출이 정확히 1회가 아님")
    c.check(JavaFile.count(body, "profile(id)") == 0, "기존 profile(id) 를 호출해 변환 (결정 2 위반)")
    c.check(JavaFile.locals_declared(body) == ["client", "profile"], f"지역 변수는 client, profile 이어야 함: {JavaFile.locals_declared(body)}")
    b = JavaFile.branches(body)
    c.check(sum(b.values()) == 0, f"문서에 없는 분기/fallback/try: {b}")
c.check(svc.methods() == base.methods() | {"publishProfile"}, f"ClientService 메서드 집합이 base+publishProfile 이 아님: {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(base.method_body("profile") == svc.method_body("profile"), "기존 profile 이 변경됨")
c.check(not c.added_files(), f"새 파일 생성: {sorted(c.added_files())}")
c.finish()
