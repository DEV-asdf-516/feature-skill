#!/usr/bin/env bash
# 컴파일 + main 기반 테스트 실행 (외부 의존 없음). 사용: bash run-tests.sh [TestClass ...]  — 인자가 없으면 src/test 의 *Test 전부
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
find src -name '*.java' > build/sources.txt
javac -d build @build/sources.txt
if [ "$#" -gt 0 ]; then tests=("$@"); else tests=($(cd src/test && ls *Test.java | sed 's/\.java$//')); fi
for t in "${tests[@]}"; do java -cp build "$t"; done
