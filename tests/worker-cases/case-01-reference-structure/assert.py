#!/usr/bin/env python3
# case-01: summary 가 참조 profile 의 두 줄 구조·지역 변수 이름·호출 순서를 그대로 옮겼는가 (동작이 같아도 구조가 다르면 FAIL)
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("summary")
c.check(body is not None, "ClientService.summary 없음")
if body is not None:
    blueprint = "Client client=findOrThrow(id);return new ClientSummary(client.id(),client.name(),MaskingUtil.maskPhone(client.phone()));"
    c.check(body == blueprint, f"summary 본문이 결정 3 blueprint 와 다름: {body}")
    ok, _ = JavaFile.order(body, "findOrThrow(id)", "return new ClientSummary(", "MaskingUtil.maskPhone(client.phone())")
    c.check(ok, "호출 순서(findOrThrow → return new ClientSummary(…, maskPhone(…))) 위반")
    c.check(JavaFile.locals_declared(body) == ["client"], f"지역 변수는 client 하나여야 함: {JavaFile.locals_declared(body)}")
    c.check(sum(JavaFile.branches(body).values()) == 0, f"문서에 없는 분기/fallback: {JavaFile.branches(body)}")
c.check(svc.methods() == base.methods() | {"summary"}, f"ClientService 메서드 집합이 base+summary 가 아님: {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(c.base_java("src/ClientService.java").method_body("profile") == svc.method_body("profile"), "기존 profile 이 변경됨")
c.finish()
