#!/usr/bin/env python3
# case-02: 지정 유틸 호출이 있고 같은 의미의 인라인 재구현·새 helper class 가 없는가 — 문자열 조립 표현(연결식/format/join/StringBuilder)과 local 은 워커 소유
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("exportLine")
c.check(body is not None, "ClientService.exportLine 없음")
if body is not None:
    c.check(svc.norm.count("MaskingUtil.maskPhone(") == 1, f"MaskingUtil.maskPhone 호출이 ClientService 전체에서 정확히 1회가 아님")
    c.check(JavaFile.count(body, "findOrThrow(id)") == 1, f"findOrThrow(id) 호출이 정확히 1회가 아님: {body}")
    b = JavaFile.branches(body)
    c.check(b["if"] + b["ternary"] + b["try"] + b["catch"] + b["switch"] + b["null"] == 0, f"문서에 없는 분기/fallback: {b}")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"exportLine"}, f"public 메서드 집합이 base+exportLine 이 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(not c.added_files(), f"새 파일(포매터 class?) 생성: {sorted(c.added_files())}")
c.check(c.base_java("src/MaskingUtil.java").norm == c.java("src/MaskingUtil.java").norm, "MaskingUtil 이 변경됨 (범위 밖)")
c.finish()
