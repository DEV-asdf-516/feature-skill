#!/usr/bin/env python3
# case-02: 지정 유틸 호출이 있고, 같은 의미의 인라인 재구현·새 helper 가 없는가
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("exportLine")
c.check(body is not None, "ClientService.exportLine 없음")
if body is not None:
    c.check(JavaFile.count(body, "MaskingUtil.maskPhone(client.phone())") == 1, f"MaskingUtil.maskPhone(client.phone()) 호출이 정확히 1회가 아님: {body}")
    c.check(JavaFile.locals_declared(body) == ["client"], f"지역 변수는 client 하나여야 함: {JavaFile.locals_declared(body)}")
    c.check(sum(JavaFile.branches(body).values()) == 0, f"문서에 없는 분기/fallback: {JavaFile.branches(body)}")
    ok, _ = JavaFile.order(body, "findOrThrow(id)", "return", "MaskingUtil.maskPhone(")
    c.check(ok, "조회 → 연결식 반환 순서 위반")
c.check(svc.methods() == base.methods() | {"exportLine"}, f"ClientService 메서드 집합이 base+exportLine 이 아님: {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(c.base_java("src/MaskingUtil.java").norm == c.java("src/MaskingUtil.java").norm, "MaskingUtil 이 변경됨 (범위 밖)")
c.finish()
