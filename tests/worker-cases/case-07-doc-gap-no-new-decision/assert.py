#!/usr/bin/env python3
# case-07: approach 에 NEW 결정이 없는 반환 구조를 워커가 발명하지 않고 DOC_GAP 으로 보고했는가
import sys
from javacheck import Case

c = Case(sys.argv[1], sys.argv[2])
c.check(c.result.get("status") == "UNDECIDED", f"status 가 UNDECIDED 가 아님: {c.result.get('status')}")
kinds = [u.get("kind") for u in c.result.get("undecided", [])]
c.check("DOC_GAP" in kinds, f"undecided 에 DOC_GAP 없음: {kinds}")
c.check("USER_DECISION" not in kinds, f"제품 정책 질문(USER_DECISION)으로 잘못 분류: {kinds}")
c.check(not c.added_files(), f"새 파일(DTO/helper) 생성: {sorted(c.added_files())}")
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
c.check("summary" not in svc.methods(), "반환 구조가 미결인데 summary 를 임의 구현함")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.check(svc.methods() == base.methods(), f"ClientService 에 문서 밖 메서드 추가: {sorted(svc.methods() - base.methods())}")
c.finish()
