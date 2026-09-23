#!/usr/bin/env python3
# case-01: material contract(REUSE findOrThrow·maskPhone·기존 ClientSummary, 문서 밖 분기 없음, 새 구조물 없음)만 본다 — helper/local 이름/줄 구조는 워커 소유
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("summary")
c.check(body is not None, "ClientService.summary 없음")
if body is not None:
    c.check(JavaFile.count(body, "findOrThrow(id)") == 1, f"findOrThrow(id) 호출이 정확히 1회가 아님: {body}")
    c.check("MaskingUtil.maskPhone(" in svc.norm, "MaskingUtil.maskPhone 호출 없음(마스킹 재구현?)")
    c.check("****" not in svc.norm and "substring(" not in svc.norm, "마스킹 규칙을 서비스에 다시 씀")
    c.check("new ClientSummary(" in svc.norm, "기존 ClientSummary 생성 없음")
    b = JavaFile.branches(body)
    c.check(b["if"] + b["ternary"] + b["try"] + b["catch"] + b["switch"] + b["null"] == 0, f"문서에 없는 분기/fallback: {b}")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"summary"}, f"public 메서드 집합이 base+summary 가 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(not c.added_files(), f"새 파일(DTO/helper class?) 생성: {sorted(c.added_files())}")
c.check(base.method_body("profile") == svc.method_body("profile"), "기존 profile 이 변경됨")
c.check(c.base_java("src/ClientSummary.java").norm == c.java("src/ClientSummary.java").norm, "ClientSummary 가 변경됨 (범위 밖)")
c.finish()
