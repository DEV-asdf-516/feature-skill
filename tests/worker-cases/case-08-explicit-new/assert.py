#!/usr/bin/env python3
# case-08: 명시된 NEW 구조물(파일·클래스·signature)을 정확히 만들고 호출부가 그것만 쓰는가
import re
import sys
from javacheck import Case, JavaFile

c = Case(sys.argv[1], sys.argv[2])
c.check(c.added_files() == {"src/TagFormatter.java"}, f"신규 파일이 src/TagFormatter.java 하나가 아님: {sorted(c.added_files())}")
fmt = c.java("src/TagFormatter.java")
c.check(fmt.types() == {"TagFormatter"}, f"TagFormatter.java 의 타입 선언: {sorted(fmt.types())}")
c.check(re.search(r"public final class TagFormatter\b", fmt.clean) is not None, "public final class TagFormatter 아님")
c.check(re.search(r"private TagFormatter\s*\(\s*\)", fmt.clean) is not None, "private 생성자 없음")
c.check(fmt.methods() == {"joinUpper"}, f"TagFormatter 메서드 집합이 joinUpper 하나가 아님: {sorted(fmt.methods())}")
sig = fmt.method_signature("joinUpper") or ""
c.check(re.fullmatch(r"public static String joinUpper\((java\.util\.)?List<String>tags\)", sig) is not None, f"joinUpper signature 가 문서와 다름: {sig}")
jb = fmt.method_body("joinUpper")
if jb is not None:
    c.check(JavaFile.count(jb, "for (String tag : tags)") == 1 and JavaFile.count(jb, "line.append(tag.toUpperCase())") == 1, f"joinUpper 본문이 blueprint 와 다름: {jb}")
    c.check(JavaFile.locals_declared(jb) == ["line", "tag"], f"joinUpper 지역 변수는 line, tag 여야 함: {JavaFile.locals_declared(jb)}")
    c.check(JavaFile.branches(jb)["null"] == 0 and JavaFile.branches(jb)["stream"] == 0, f"문서에 없는 null 방어/stream: {JavaFile.branches(jb)}")
svc = c.java("src/ClientService.java")
base = c.base_java("src/ClientService.java")
body = svc.method_body("tagLine")
c.check(body is not None, "ClientService.tagLine 없음")
if body is not None:
    c.check(body == "Client client=findOrThrow(id);return TagFormatter.joinUpper(client.tags());", f"tagLine 본문이 결정 3 blueprint 와 다름: {body}")
c.check(svc.methods() == base.methods() | {"tagLine"}, f"ClientService 메서드 집합이 base+tagLine 이 아님: {sorted(svc.methods())}")
c.check(svc.private_methods() == base.private_methods(), f"새 private helper: {sorted(svc.private_methods() - base.private_methods())}")
c.check(svc.types() == base.types(), f"ClientService 에 새 타입 선언: {sorted(svc.types() - base.types())}")
c.finish()
