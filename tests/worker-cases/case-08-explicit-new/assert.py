#!/usr/bin/env python3
# case-08: 명시된 NEW 구조물(파일·클래스·public signature)을 정확히 만들고 호출부가 그것만 쓰는가 — 메서드 내부 표현·파라미터/local 이름은 워커 소유
import re
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
c.check(c.added_files() == {"src/TagFormatter.java"}, f"신규 파일이 src/TagFormatter.java 하나가 아님: {sorted(c.added_files())}")
fmt = c.java("src/TagFormatter.java")
c.check(fmt.types() == {"TagFormatter"}, f"TagFormatter.java 의 타입 선언: {sorted(fmt.types())}")
c.check(re.search(r"public final class TagFormatter\b", fmt.clean) is not None, "public final class TagFormatter 아님")
c.check(re.search(r"private TagFormatter\s*\(\s*\)", fmt.clean) is not None, "private 생성자 없음")
c.check((fmt.methods() - fmt.private_methods()) == {"joinUpper"}, f"TagFormatter public 메서드 집합이 joinUpper 하나가 아님: {sorted(fmt.methods() - fmt.private_methods())}")
sig = fmt.method_signature("joinUpper") or ""
c.check(re.fullmatch(r"public static String joinUpper\((java\.util\.)?List<String>\w+\)", sig) is not None, f"joinUpper signature 가 문서와 다름: {sig}")
jb = fmt.method_body("joinUpper")
if jb is not None:
    c.check(JavaFile.branches(jb)["null"] == 0, f"문서에 없는 null 방어: {JavaFile.branches(jb)}")
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("tagLine")
c.check(body is not None, "ClientService.tagLine 없음")
if body is not None:
    c.check(JavaFile.count(body, "findOrThrow(id)") == 1 and JavaFile.count(body, "TagFormatter.joinUpper(") == 1, f"tagLine 이 findOrThrow → TagFormatter.joinUpper 를 쓰지 않음: {body}")
    c.check("toUpperCase" not in svc.norm, "ClientService 에 대문자화 코드 존재(TagFormatter 우회)")
c.check((svc.methods() - svc.private_methods()) == (base.methods() - base.private_methods()) | {"tagLine"}, f"public 메서드 집합이 base+tagLine 이 아님: {sorted(svc.methods() - svc.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.finish()
