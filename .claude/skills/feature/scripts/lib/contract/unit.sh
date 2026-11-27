#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/contract/unit.sh
# 구현 단위 manifest·unit 유효 계약 스냅샷·rolling implementation context.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 1154–1570)
# =============================================================

# ---------- 구현 단위 manifest (implementation-units.json) ----------
# 오케스트레이터가 implementation.md/approach.md 와 함께 쓴다(schemas/implementation-units.schema.json). impl 합의의 입력이며(PASS 지문 포함),
# 워커 단계는 이 파일을 units 배열 순서대로 **직렬** 실행한다 — unit 마다 fresh 워커 → targeted test. unit 별 리뷰 없음, 병렬·DAG·우선순위 없음.
#   scope : feature-scope.json 과 같은 files/new_file_roots 의미. 전체 범위(lock)의 부분집합이어야 하며 위반 검사는 같은 feature_scope_violations 를 쓴다.
#   lock  : 워커 진입 시 implementation-units.lock.json 으로 확정(feature-scope.lock.json 과 같은 철학). 원본≠lock 이면 어느 쪽이 맞는지 정하지 않고 사람에게.
UNITS_MANIFEST_FILE="$WORK_DIR/implementation-units.json"
UNITS_MANIFEST_LOCK="$WORK_DIR/implementation-units.lock.json"
UNITS_MANIFEST_VERSION=1
units_manifest_present() { [ -f "$UNITS_MANIFEST_FILE" ]; }
units_manifest_file() { if [ -f "$UNITS_MANIFEST_LOCK" ]; then printf '%s' "$UNITS_MANIFEST_LOCK"; else printf '%s' "$UNITS_MANIFEST_FILE"; fi; }
# 스키마(schemas/implementation-units.schema.json)를 jq 로 그대로 강제한다 — 이 파일은 모델 출력이 아니라 오케스트레이터가 쓰므로 CLI 의 스키마 검사가 없다.
#   root/unit/scope additionalProperties false · version 1 · units ≥1 · id 순번 prefix + kebab · id 유일 · 순번이 배열 순서와 같이 증가 ·
#   requirements/references ≥1 · targeted_test 비어 있지 않음 · scope 는 feature-scope 와 같은 canonical 규칙(files/roots 중 하나 이상)
#   depends_on / priority / parallel 같은 필드는 additionalProperties false 로 거부된다(스케줄링 개념 없음).
units_manifest_valid_file() { # manifest-path
  [ -f "$1" ] && jq -e --argjson v "$UNITS_MANIFEST_VERSION" "$JQ_PATH_DEFS"'
    def canonical: canonical_path;
    def nonempty_strings: type=="array" and length>0 and all(.[]; type=="string" and length>0);
    type=="object" and .version==$v and ((keys - ["version","units"])|length)==0
    and (.units|type=="array") and (.units|length)>=1
    and all(.units[]; type=="object"
      and ((keys - ["id","title","goal","requirements","scope","references","targeted_test"])|length)==0
      and (.id|type=="string" and test("^[0-9]{2,}-[a-z0-9]+(-[a-z0-9]+)*$"))
      and (.title|type=="string" and length>0) and (.goal|type=="string" and length>0)
      and (.requirements|nonempty_strings) and (.references|nonempty_strings)
      and (.targeted_test|type=="string" and length>0)
      and (.scope|type=="object" and ((keys - ["files","new_file_roots"])|length)==0
        and (.files|type=="array") and ((.new_file_roots // [])|type=="array")
        and ((.files|length) + ((.new_file_roots // [])|length)) > 0
        and all(.files[]; canonical)
        and all((.new_file_roots // [])[]; type=="string" and (sub("/$"; "") | canonical))))
    and ([.units[].id] | length == (unique|length))
    and ([.units[].id | split("-")[0] | tonumber] as $n | all(range(1; $n|length); $n[.] > $n[.-1]))' \
    "$1" >/dev/null 2>&1
}
# unit scope 가 전체 범위(feature-scope lock) 밖으로 나가는 경로를 "<unit-id>:<path>" 로 출력 (빈 출력이면 부분집합).
#   files 는 전체 files 에 정확히 있거나 전체 roots 아래여야 하고, roots 는 전체 roots 와 같거나 그 아래여야 한다.
#   실행 시에는 전체 검사와 unit 검사를 둘 다 통과해야 하므로(둘 중 좁은 규칙이 이긴다) 여기서는 경로 포함 관계만 본다.
units_scope_outside_global() { # units-manifest global-scope-manifest
  jq -r --slurpfile g "$2" '
    ($g[0].files) as $gf | (($g[0].new_file_roots // []) | map(sub("/+$"; "") + "/")) as $gr
    | def covered_file: . as $p | (($gf | index($p)) != null) or any($gr[]; . as $r | $p | startswith($r));
      def covered_root: (sub("/+$"; "") + "/") as $p | any($gr[]; . as $r | $p == $r or ($p | startswith($r)));
      .units[] | .id as $id
      | ((.scope.files[] | select(covered_file | not) | "\($id):\(.)"),
         ((.scope.new_file_roots // [])[] | select(covered_root | not) | "\($id):\(.)"))' "$1"
}
units_manifest_hash() { # 원본 + lock 내용 해시 (없는 쪽은 MISSING). unit 워커 호출 전후로 비교한다.
  {
    for f in "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK"; do
      printf '%s\0' "$f"; if [ -f "$f" ]; then cat "$f"; else printf 'MISSING'; fi; printf '\0'
    done
  } | sha256_stdin
}
# lock 확정: 없으면 원본을 복사. 있는데 원본과 다르면 2 (호출자가 중단 — 의도한 변경이면 impl 재합의 후 lock 을 지우고 재실행).
lock_units_manifest() {
  if [ ! -f "$UNITS_MANIFEST_LOCK" ]; then
    cp "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK" || return 1
    return 0
  fi
  cmp -s "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK" && return 0
  return 2
}
unit_ids() { jq -r '.units[].id' "$(units_manifest_file)"; }
unit_json() { jq -c --arg id "$1" '.units[] | select(.id==$id)' "$(units_manifest_file)"; }
# unit spec 지문: lock 의 해당 unit 객체(정렬된 compact JSON)의 해시. done.json 의 spec_hash 와 대조해 spec 이 바뀐 unit 의 체크포인트를 무효화한다.
unit_spec_hash() { jq -Sc --arg id "$1" '.units[] | select(.id==$id)' "$(units_manifest_file)" | sha256_stdin; }
# ---------- unit 유효 계약(effective contract) 스냅샷 ----------
# unit JSON 해시(spec_hash)만으로는 "문서가 바뀌었는데 unit JSON 은 그대로"인 경우를 못 잡는다. 그래서 unit 마다 그 unit 이 실제로 의존하는
# 계약 본문을 스냅샷으로 남기고, 완료 판정·테스트-only 재개·DONE 확정·review 진입이 전부 같은 지문을 본다.
#   local  (그 unit 의 계약 — 바뀌면 그 unit 만 stale):
#     · lock 의 unit JSON(정렬) · references 가 가리키는 design.md/implementation.md/approach.md 절의 **본문**(heading 줄 + 조상 heading 경로 포함)
#     · 이 unit 에 묶인 사용자 결정(decisions.md 의 [USER-QUESTION]…[worker-gap=<unit id>#N] 줄)
#   global (전역 입력 — 바뀌면 영향 unit 을 코드가 추정하지 않는다):
#     · request.md · conventions.md · unit 에 묶이지 않은 사용자 결정([worker-gap=…]/[review-issue=…] 태그가 없는 [USER-QUESTION] 줄)
#     · design.md 전체 — 단, 그 unit 이 design.md#… 절을 references 에 하나라도 적었으면 그 절만 local 로 보고 전체는 global 에서 뺀다.
# references 형식: "<design.md|implementation.md|approach.md>#<anchor>"(절) 또는 "#" 없는 문서 이름(문서 전체). anchor 는 heading 텍스트 그대로,
# 그 GitHub 식 slug, 또는 heading 끝의 명시적 {#id} 와 대조하고, 정확히 맞는 heading 이 없을 때만 slug 의 단어 경계 접두(예: "결정-1" ↔ "## 결정 1: 없는 id 처리",
# "결정 10" 은 맞지 않는다)로 대조한다. 0개(삭제·이름 변경)·2개 이상(모호)·지원하지 않는 형식은 '영향 없음'이 아니라 해석 불가다.
# 비교는 내용 기반이다 — heading 문자열이 그대로여도 본문이 바뀌면 변경이고, 절이 다른 상위 절 아래로 옮겨지면 경로 줄이 달라져 변경으로 잡힌다.
# 파일:
#   units/<id>/contract/baseline/{contract.txt,global.txt}  현재 세대의 기준 계약(최초 워커 호출 직전에 기록, unit 완료 시 완료 시점 계약으로 교체 — 옛 것은 history/NN)
#   units/<id>/contract/first/                               그 unit 의 최초 스냅샷(불변)
#   units/<id>/contract/contract.json                        {version, unit_id, local_fingerprint, global_fingerprint, fingerprint, baseline_source, source_tree, consensus_provenance, …}
#   units/<id>/worker-contract.json                          마지막 워커 턴(worker-unit.md)이 프롬프트로 받은 계약의 지문 — 테스트-only 재개·DONE 확정이 이것과 현재를 대조한다
#   units/<id>/changed-contract.diff                         재개 턴에 준 기준 계약 → 현재 계약의 실제 unified diff
#   $WORK_DIR/.unit-contract/<id>/                           현재 계약 렌더링(파생물, 매번 덮어씀)
UNIT_CONTRACT_VERSION=1
UNIT_DONE_VERSION=2
UNIT_CONTRACT_IMPACT_FILE="$WORK_DIR/unit-contract-impact.json"   # 사용자의 명시적 영향 확정: {"version":2,"target_fingerprint":"<러너가 내준 값>","affected_units":[…],"unaffected_units":[…]}
UNIT_CONTRACT_DIFF_MAX_LINES="${UNIT_CONTRACT_DIFF_MAX_LINES:-400}" # 이보다 큰 변경 계약 diff 는 프롬프트에 싣지 않고(임의 절단 금지) 전체 파일을 읽게 한다
unit_contract_dir() { printf '%s/units/%s/contract' "$WORK_DIR" "$1"; }
unit_contract_fingerprint_of() { printf '%s:%s' "$1" "$2" | sha256_stdin; } # local global
# 문서의 한 절: "@path: <조상 heading 경로>" 줄 + heading 줄부터 같은/상위 level 의 다음 heading 직전까지(끝의 빈 줄 제거). 1 = 없음, 2 = 복수 매칭. 3 = 문서 해석 실패.
unit_contract_section() { # doc-path anchor
  local out n
  out="$(jq -Rs --arg a "$2" '
    def slug: ascii_downcase | gsub("[^\\p{L}\\p{N}_ -]"; "") | gsub("^ +| +$"; "") | gsub(" +"; "-");
    split("\n") as $L
    | (reduce range(0; $L|length) as $i ({fence:"", heads:[]};
        $L[$i] as $l | .fence as $f
        | if $f != "" then (if ($l|test("^\\s{0,3}" + $f)) then .fence="" else . end)
          elif ($l|test("^\\s{0,3}(```|~~~)")) then .fence=($l|capture("^\\s{0,3}(?<f>```|~~~)").f)
          elif ($l|test("^#{1,6}[ \\t]+\\S")) then .heads += [{i:$i, level:($l|capture("^(?<h>#+)").h|length),
                text:($l|sub("^#+[ \\t]+";"")|sub("[ \\t]+#+[ \\t]*$";"")|sub("[ \\t\\r]+$";""))}]
          else . end) | .heads) as $H
    | ($a|slug) as $as
    | [range(0; $H|length) | select(($H[.].text == $a) or ($as != "" and ($H[.].text|slug) == $as) or ($H[.].text|endswith("{#" + $a + "}")))] as $exact
    | (if ($exact|length) > 0 or $as == "" then $exact
       else [range(0; $H|length) | select($H[.].text|slug|startswith($as + "-"))] end) as $m
    | {count:($m|length), text:(if ($m|length)==1 then
        $m[0] as $k | $H[$k] as $h
        | (reduce ([range(0; $k)] | reverse[]) as $j ({lvl:$h.level, acc:[]};
            if $H[$j].level < .lvl then {lvl:$H[$j].level, acc:([$H[$j].text] + .acc)} else . end) | .acc) as $anc
        | ([$H[$k+1:][] | select(.level <= $h.level) | .i] | first // ($L|length)) as $end
        | "@path: " + ($anc|join(" > ")) + "\n" + ($L[$h.i:$end] | join("\n") | sub("[\\s]+$"; ""))
      else "" end)}' "$1")" || return 3
  n="$(jq -r '.count' <<< "$out")"
  if [ "$n" -eq 0 ]; then return 1; elif [ "$n" -gt 1 ]; then return 2; fi
  jq -r '.text' <<< "$out"
}
# unit 의 현재 유효 계약을 out-dir/{contract.txt,global.txt} 로 렌더링한다. 1 = 해석 불가(사유는 UC_WHY) — 호출자는 '영향 없음'으로 넘어가지 않는다.
UC_WHY=""; UC_LOCAL=""; UC_GLOBAL=""; UC_DIR=""
unit_contract_render() { # unit-id out-dir
  local id="$1" out="$2" uj ref doc anchor path body rc has_design=0
  UC_WHY=""
  uj="$(unit_json "$id")"
  [ -n "$uj" ] || { UC_WHY="unit $id 가 구현 단위 manifest 에 없음"; return 1; }
  mkdir -p "$out" || { UC_WHY="렌더링 디렉터리 생성 실패: $out"; return 1; }
  {
    printf '=== unit (implementation-units.json) ===\n'; jq -S . <<< "$uj"
    while IFS= read -r ref; do
      doc="${ref%%#*}"; anchor=""; case "$ref" in *'#'*) anchor="${ref#*#}";; esac
      case "$doc" in
        design.md|implementation.md|approach.md) ;;
        *) UC_WHY="references '$ref' 는 지원하지 않는 형식 — 'design.md#<절>' / 'implementation.md#<절>' / 'approach.md#<절>'(또는 # 없이 문서 전체)만 계약 의존으로 해석한다"; return 1;;
      esac
      path="$WORK_DIR/$doc"
      [ -f "$path" ] || { UC_WHY="references '$ref': $path 가 없음"; return 1; }
      [ "$doc" != design.md ] || has_design=1
      printf '\n=== reference: %s ===\n' "$ref"
      if [ -z "$anchor" ]; then
        cat "$path"
      else
        rc=0; body="$(unit_contract_section "$path" "$anchor")" || rc=$?
        case "$rc" in
          0) printf '%s\n' "$body";;
          2) UC_WHY="references '$ref': $doc 에 그 anchor 와 맞는 heading 이 둘 이상(모호)"; return 1;;
          3) UC_WHY="references '$ref': $doc 의 heading 구조를 해석하지 못함(jq 오류)"; return 1;;
          *) UC_WHY="references '$ref': $doc 에 그 anchor 와 맞는 heading 이 없음(삭제·이름 변경)"; return 1;;
        esac
      fi
    done < <(jq -r '.references[]' <<< "$uj")
    printf '\n=== user decisions bound to this unit (decisions.md [worker-gap=%s#N]) ===\n' "$id"
    if [ -f "$WORK_DIR/decisions.md" ]; then grep -E "^[[:space:]]*- \[USER-QUESTION\](\[[^]]*\])*\[worker-gap=$id#[0-9]+(@[0-9]+)?\]" "$WORK_DIR/decisions.md" || true; fi
  } > "$out/contract.txt"
  {
    printf '=== request.md ===\n'; if [ -f "$WORK_DIR/request.md" ]; then cat "$WORK_DIR/request.md"; else printf '(absent)\n'; fi
    printf '\n=== conventions.md ===\n'; conventions_contract_content || printf '(absent)\n'
    if [ "$has_design" -eq 0 ]; then
      printf '\n=== design.md (전체 — 이 unit 의 references 에 design.md#… 절이 없어 영향 절을 특정할 수 없다) ===\n'
      if [ -f "$WORK_DIR/design.md" ]; then cat "$WORK_DIR/design.md"; else printf '(absent)\n'; fi
    fi
    printf '\n=== user decisions not bound to a unit (decisions.md) ===\n'
    if [ -f "$WORK_DIR/decisions.md" ]; then
      { grep -E '^[[:space:]]*- \[USER-QUESTION\]' "$WORK_DIR/decisions.md" || true; } | { grep -vE '\[(worker-gap|review-issue)=[^]]*\]' || true; }
    fi
  } > "$out/global.txt"
}
# manifest 의 모든 unit references 를 현재 문서와 대조해 해석할 수 없는 것을 "<unit id>: <사유>" 줄로 낸다(빈 출력 = 전부 해석됨). 모델 호출 없음.
# impl 합의(검증자) 전에 불러, 가리키는 절이 없는 manifest 로 유료 검증을 돌리지 않는다. lock 이 아니라 인자로 받은 파일을 본다.
units_unresolved_references() { # manifest-path
  local id ref doc anchor rc
  while IFS=$'\t' read -r id ref; do
    [ -n "$id" ] || continue
    doc="${ref%%#*}"; anchor=""; case "$ref" in *'#'*) anchor="${ref#*#}";; esac
    case "$doc" in
      design.md|implementation.md|approach.md) ;;
      *) printf "%s: '%s' 는 지원하지 않는 형식(design.md#<절> / implementation.md#<절> / approach.md#<절> 또는 문서 이름)\n" "$id" "$ref"; continue;;
    esac
    [ -f "$WORK_DIR/$doc" ] || { printf "%s: '%s' 의 문서가 없음\n" "$id" "$ref"; continue; }
    [ -n "$anchor" ] || continue
    rc=0; unit_contract_section "$WORK_DIR/$doc" "$anchor" >/dev/null || rc=$?
    case "$rc" in
      0) ;;
      2) printf "%s: '%s' 와 맞는 heading 이 둘 이상(모호)\n" "$id" "$ref";;
      *) printf "%s: '%s' 와 맞는 heading 이 없음\n" "$id" "$ref";;
    esac
  done < <(jq -r '.units[] | .id as $i | .references[] | [$i, .] | @tsv' "$1")
}
# 현재 계약 렌더링 + 지문(UC_LOCAL/UC_GLOBAL/UC_DIR). 1 = 해석 불가(UC_WHY).
unit_contract_current() { # unit-id
  UC_DIR="$WORK_DIR/.unit-contract/$1"; UC_LOCAL=""; UC_GLOBAL=""
  unit_contract_render "$1" "$UC_DIR" || return 1
  UC_LOCAL="$(sha256_stdin < "$UC_DIR/contract.txt")"; UC_GLOBAL="$(sha256_stdin < "$UC_DIR/global.txt")"
}
# 기준 계약 대비 현재 상태 한 단어:
#   CURRENT          local·global 모두 기준과 같다
#   STALE            이 unit 의 local 계약이 바뀌었다(또는 전역 변경에 대해 사용자가 '영향 있음'으로 확정했다)
#   IMPACT_REQUIRED  local 은 같고 전역 입력만 바뀌었다 — 영향 여부를 코드가 정하지 않는다
#   NO_BASELINE      기준 스냅샷이 없다(이 변경 이전의 산출물)
#   UNRESOLVED       references 를 해석할 수 없다(절 삭제·모호·형식)
unit_contract_status() { # unit-id
  local meta; meta="$(unit_contract_dir "$1")/contract.json"
  unit_contract_current "$1" || { printf 'UNRESOLVED'; return 0; }
  jq -e --argjson v "$UNIT_CONTRACT_VERSION" '.version==$v' "$meta" >/dev/null 2>&1 || { printf 'NO_BASELINE'; return 0; }
  [ "$(jq -r '.local_fingerprint' "$meta")" = "$UC_LOCAL" ] || { printf 'STALE'; return 0; }
  if [ "$(jq -r '.global_fingerprint' "$meta")" = "$UC_GLOBAL" ]; then printf 'CURRENT'; return 0; fi
  if [ "$(jq -r '.impact_confirmed_global // ""' "$meta")" = "$UC_GLOBAL" ]; then printf 'STALE'; return 0; fi
  printf 'IMPACT_REQUIRED'
}
# 합의 입력의 유효 provenance(스냅샷 메타데이터 — 지문에는 넣지 않는다).
unit_contract_provenance() {
  local d=UNVERIFIED i=UNVERIFIED
  if consensus_pass_current design; then d=PASS; elif user_escalation_resolved_current design; then d=USER_RESOLVED; fi
  if consensus_pass_current impl; then i=PASS; elif user_escalation_resolved_current impl; then i=USER_RESOLVED; elif doc_gap_resolved_current; then i=DOC_GAP_RESOLVED; fi
  jq -nc --arg d "$d" --arg i "$i" '{design:$d, impl:$i}'
}
# 기준 계약 기록(교체): src-dir 의 contract.txt/global.txt 를 baseline 으로. 기존 baseline·contract.json 은 history/NN 으로 옮겨 보존한다.
#   source: first-worker-call | unit-done | user-confirmed-unaffected | user-confirmed-affected(src-dir 빈 문자열 = 이전 계약을 알 수 없음, 지문 UNKNOWN)
unit_contract_write_baseline() { # unit-id source src-dir
  local id="$1" source="$2" src="$3" dir base n=1 l g tree
  dir="$(unit_contract_dir "$id")"; base="$dir/baseline"
  mkdir -p "$dir/history" || return 1
  if [ -d "$base" ]; then
    while [ -e "$dir/history/$(printf '%02d' "$n")" ]; do n=$((n + 1)); done
    mv "$base" "$dir/history/$(printf '%02d' "$n")" || return 1
    [ ! -f "$dir/contract.json" ] || cp "$dir/contract.json" "$dir/history/$(printf '%02d' "$n")/contract.json" || return 1
  fi
  mkdir -p "$base" || return 1
  if [ -n "$src" ]; then
    cp "$src/contract.txt" "$src/global.txt" "$base/" || return 1
    l="$(sha256_stdin < "$base/contract.txt")"; g="$(sha256_stdin < "$base/global.txt")"
  else
    : > "$base/contract.txt"; : > "$base/global.txt"; l=UNKNOWN; g=UNKNOWN
  fi
  [ -d "$dir/first" ] || cp -R "$base" "$dir/first" || return 1
  tree="$(snapshot_worktree_tree)" || return 1
  jq -n --argjson v "$UNIT_CONTRACT_VERSION" --arg id "$id" --arg l "$l" --arg g "$g" --arg fp "$(unit_contract_fingerprint_of "$l" "$g")" \
    --arg source "$source" --arg tree "$tree" --argjson prov "$(unit_contract_provenance)" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, unit_id:$id, local_fingerprint:$l, global_fingerprint:$g, fingerprint:$fp, baseline_source:$source,
      source_tree:$tree, consensus_provenance:$prov, recorded_at:$now}' > "$dir/contract.json.tmp" && mv "$dir/contract.json.tmp" "$dir/contract.json"
}
# 워커 턴(worker-unit.md) 직전: 기준 계약을 확정하고 [UNIT TURN]/[CHANGED CONTRACT] 블록과 worker-contract.json 을 만든다(모델 호출 없음).
#   kind 는 프롬프트 블록의 비어 있음이 아니라 러너 상태로 정한다 — 이 unit 의 워커 CLI 가 한 번이라도 시작됐으면(worker-before.tree) RESUME.
#   반환: 0 준비됨 / 1 references 해석 불가(UC_WHY) / 2 과거 진행 흔적은 있는데 기준 스냅샷이 없음(최초 실행으로 오판하지 않는다) / 3 기록 실패
UNIT_TURN_BLOCK=""; UNIT_CHANGED_CONTRACT_BLOCK=""
unit_contract_prepare_turn() { # unit-id unit-dir
  local id="$1" ud="$2" dir meta kind=FIRST prev cur diff_file lines
  dir="$(unit_contract_dir "$id")"; meta="$dir/contract.json"
  unit_contract_current "$id" || return 1
  [ ! -f "$ud/worker-before.tree" ] || kind=RESUME
  cur="$(unit_contract_fingerprint_of "$UC_LOCAL" "$UC_GLOBAL")"
  if ! jq -e --argjson v "$UNIT_CONTRACT_VERSION" '.version==$v' "$meta" >/dev/null 2>&1; then
    if [ "$kind" = RESUME ] || [ -f "$ud/worker-result.json" ] || [ -f "$ud/done.json" ]; then return 2; fi
    unit_contract_write_baseline "$id" first-worker-call "$UC_DIR" || return 3
  elif [ "$kind" = FIRST ] && [ "$(jq -r '.fingerprint' "$meta")" != "$cur" ]; then
    # 스냅샷만 남기고 워커 CLI 는 시작되지 않았다(호출 직전 중단) — 워커가 본 적 없는 계약과의 diff 는 의미가 없으므로 최초 스냅샷을 현재로 다시 잡는다
    unit_contract_write_baseline "$id" first-worker-call "$UC_DIR" || return 3
  fi
  prev="$(jq -r '.fingerprint' "$meta")"
  diff_file="$ud/changed-contract.diff"
  {
    diff -u -L "previous/contract.txt" -L "current/contract.txt" "$dir/baseline/contract.txt" "$UC_DIR/contract.txt" || true
    diff -u -L "previous/global.txt" -L "current/global.txt" "$dir/baseline/global.txt" "$UC_DIR/global.txt" || true
  } > "$diff_file.tmp" && mv "$diff_file.tmp" "$diff_file" || return 3
  lines="$(wc -l < "$diff_file" | tr -d ' ')"
  UNIT_TURN_BLOCK="kind=$kind
unit_id=$id
previous_contract_fingerprint=$prev
current_contract_fingerprint=$cur"
  if [ "$prev" = "$cur" ]; then
    UNIT_CHANGED_CONTRACT_BLOCK="none"
  elif [ "$(jq -r '.local_fingerprint' "$meta")" = UNKNOWN ]; then
    UNIT_CHANGED_CONTRACT_BLOCK="이 unit 의 이전 계약 스냅샷이 없다(이 기능 이전의 산출물이고 사용자가 '영향 있음'으로 확정했다) — 무엇이 바뀌었는지 diff 로 줄 수 없다. 현재 계약 전문: $UC_DIR/contract.txt, $UC_DIR/global.txt. 두 파일 전체를 읽고 기존 구현 전체를 현재 계약과 대조하라."
  elif [ "$lines" -le "$UNIT_CONTRACT_DIFF_MAX_LINES" ]; then
    UNIT_CHANGED_CONTRACT_BLOCK="$(cat "$diff_file")
(위가 전체 diff 다 — 파일: $diff_file. previous = 이 unit 의 기준 계약, current = 지금 유효한 계약)"
  else
    UNIT_CHANGED_CONTRACT_BLOCK="변경 계약 diff 가 $lines 줄이라 프롬프트에 싣지 않았다(일부만 잘라 보여 주지 않는다). 전체 diff: $diff_file — 구현 전에 이 파일 **전체**를 읽어라. 이전 계약 전문: $dir/baseline/, 현재 계약 전문: $UC_DIR/. 파일을 끝까지 읽을 수 없으면 구현하지 말고 undecided(kind=DOC_GAP, decision_needed 에 '변경 계약 diff 를 읽을 수 없음')로 보고하라 — 사람이 직접 확인한다."
  fi
  jq -n --arg id "$id" --arg kind "$kind" --arg l "$UC_LOCAL" --arg g "$UC_GLOBAL" --arg fp "$cur" --arg prev "$prev" --arg now "$(date '+%FT%T%z')" \
    '{unit_id:$id, kind:$kind, local_fingerprint:$l, global_fingerprint:$g, fingerprint:$fp, previous_fingerprint:$prev, recorded_at:$now}' \
    > "$ud/worker-contract.json.tmp" && mv "$ud/worker-contract.json.tmp" "$ud/worker-contract.json" || return 3
}
# 마지막 워커 턴이 받은 계약 == 현재 계약인가. 과거 DONE 결과로 워커 없이 테스트부터 재개할 때와 done.json 확정 직전에 본다.
unit_worker_contract_current() { # unit-id unit-dir
  [ -f "$2/worker-contract.json" ] || return 1
  unit_contract_current "$1" || return 1
  [ "$(jq -r '.fingerprint // ""' "$2/worker-contract.json")" = "$(unit_contract_fingerprint_of "$UC_LOCAL" "$UC_GLOBAL")" ]
}
# 기준 계약과 달라진 **이 unit 의** 차이가 '구현 후 gap 의 사용자 해결'로 설명되는가. 유효한 해결 기록이 있다는 것만으로는 부족하다 —
# 그 해결이 이 unit 의 이 계약 변경을 낳은 것이어야 한다. 네 조건을 모두 만족할 때만 true:
#   ① 해결 provenance 가 현재 입력에 유효(doc_gap_resolved_current)하고 리뷰 DOC_GAP(또는 verify 의 worker-fix 미결정)이다. unit 워커 gap(unit_id 있음)은 그 unit 을 다시 돌리므로 해당하지 않는다.
#      앞서 해결된 gap(prior_gaps)도 같은 조건으로 센다 — 대상 선별은 _unit_gap_linked_tags 가 한다.
#   ② 전역 입력(global.txt)은 기준 그대로다 — gap 해결은 request·conventions·design·묶이지 않은 결정을 바꾸지 않는다([review-issue=…]/[worker-gap=…] 줄은 전역 계약에 들어가지 않는다).
#   ③ local 계약의 차이가 approach.md 를 가리키는 reference 블록 안에만 있다(해결 범위 = approach.md 반영 + decisions.md 추가). implementation·design 절이나 unit JSON 이 달라졌으면 gap 해결이 아니다.
#   ④ 이 unit 이 그 gap 과 연결돼 있다: gap 의 구조화된 경로(paths — 워커 undecided 의 paths / 리뷰 issue 의 code_refs) 중 하나 이상이 이 unit 의 scope(files / new_file_roots) 안이다.
#      paths 가 없는 옛 체크포인트만 refs/location 을 제한적으로 해석한다(doc_gap_links). 자유 문자열 location 은 새 기록의 판정 근거가 아니다.
#   ⑤ 달라진 approach 절 **각각**이 그 gap 의 해결임이 명시돼 있다: 절 본문에 연결된 gap 의 tag(`[review-issue=<id>]` / `[worker-gap=review-gap#<n>]`)가 있다.
#      절과 gap 의 관계를 코드가 추정하지 않는다 — 표시가 없는 절 변경은 gap 해결로 확정할 수 없으므로 자동 승인하지 않고 stale 로 사용자에게 돌아간다.
# 그 해결의 구현자는 unit 워커가 아니라 review-gap 워커(→ 전체 리뷰)다. gap 과 무관한 unit 의 approach 절까지 같이 고쳤으면 그 unit 은 정상 stale 이다(변경 계약으로 다시 돈다).
# gap 과 연결된 unit 인가: gap 의 경로(doc_gap_links 가 해석한 paths) 중 하나 이상이 unit scope(files / new_file_roots) 안인 gap 의 tag 목록(JSON 배열).
# 경로가 하나도 확인되지 않은 gap 은 어느 unit 과도 연결되지 않는다(모든 unit 에 허용하지 않는다).
# new_file_roots 는 manifest 가 'src/gen/' 처럼 끝 슬래시를 달 수 있으므로 정규화한 뒤 접두 비교한다('src/gen//' 와 비교해 정상 경로를 놓치지 않게).
# 대상 gap: ① 현재 체크포인트의 gap(리뷰 DOC_GAP 이거나 unit_id 가 없는 워커 미결정일 때만 — unit 워커 gap 은 그 unit 을 다시 돌린다)
#           ② 앞서 해결된 gap(prior_gaps) 가운데 원본 리뷰·이슈 ID·사용자 결정의 연결이 지금도 확인되는 것(doc_gap_prior_valid_tags).
#   리뷰 DOC_GAP 이 연달아 나오면 체크포인트는 새 gap 으로 바뀌지만 unit 의 기준 계약은 그대로라, 앞 해결로 바뀐 절도 계속 '기준과 다른 절'이다 —
#   앞 해결을 잊으면 그 unit 이 stale 로 멈춘다(feature 061). 허용 범위는 gap 마다 같다: 그 gap 의 코드 위치가 scope 안인 unit 의, 그 gap 의 tag 가 적힌 approach 절.
_unit_links_tags() { # unit-json links-json(doc_gap_links) → 그 unit scope 와 연결된 gap 의 tag 배열
  jq -c --argjson u "$1" '
    ($u.scope.files // []) as $f | [($u.scope.new_file_roots // [])[] | sub("/+$"; "")] as $r
    | [.[] | select(any(.paths[]; . as $p | any($f[]; . == $p) or any($r[]; . as $root | $p | startswith($root + "/")))) | .tag]' <<< "$2"
}
_unit_gap_linked_tags() { # unit-json
  local links; links="$(doc_gap_links)" || return 1
  _unit_links_tags "$1" "$links"
}
# 기준 계약 대비 **이 unit 의** 차이를 진단 JSON 으로 낸다 — 판정은 하지 않는다(해결 provenance 를 보지 않는다). 1 = 진단 불가(기준 스냅샷 없음·references 해석 불가).
#   {unit, global_changed, linked_tags:[연결된 gap tag], changed:[{block:"=== reference: approach.md#… ===", approach:bool, tagged:bool, mentions:[본문에 적힌 후보 gap tag]}]}
#   tagged   = 그 블록 본문에 이 unit 과 연결된 gap 의 tag 가 있다(조건 ⑤)
#   mentions = 연결 여부와 무관하게 본문에 적힌 후보 gap 의 tag — tag 는 적혀 있는데 연결이 안 된 경우(위치 미확정·다른 unit 의 gap)를 구분해 보고하는 데 쓴다
unit_contract_drift_json() { # unit-id
  local id="$1" dir uj links tags g=false
  dir="$(unit_contract_dir "$id")"
  [ -f "$dir/baseline/contract.txt" ] && [ -f "$dir/contract.json" ] || return 1
  unit_contract_current "$id" || return 1
  [ "$(jq -r '.global_fingerprint // ""' "$dir/contract.json")" = "$UC_GLOBAL" ] || g=true
  uj="$(unit_json "$id")"; [ -n "$uj" ] || return 1
  links="$(doc_gap_links)" || return 1
  tags="$(_unit_links_tags "$uj" "$links")" || return 1
  # 계약을 '=== … ===' 머리줄 단위 블록으로 나눠 기준과 현재를 블록별로 대조한다.
  jq -nc --arg id "$id" --argjson g "$g" --rawfile a "$dir/baseline/contract.txt" --rawfile b "$UC_DIR/contract.txt" --argjson tags "$tags" --argjson links "$links" '
    def blocks: split("\n") | reduce .[] as $l ({cur:"", m:{}};
      if ($l|test("^=== .* ===$")) then .cur=$l | .m[$l]="" else .m[.cur] = ((.m[.cur] // "") + $l + "\n") end) | .m;
    ($a|blocks) as $A | ($b|blocks) as $B
    | {unit:$id, global_changed:$g, linked_tags:$tags,
       changed:[ (($A + $B) | keys[]) | select($A[.] != $B[.]) | . as $k | ($B[$k] // "") as $body
         | {block:$k, approach:($k|test("^=== reference: approach\\.md(#.*)? ===$")),
            tagged:any($tags[]; . as $t | $body | contains("[" + $t + "]")),
            mentions:[$links[].tag | select(. as $t | $body | contains("[" + $t + "]"))]} ]}'
}
unit_contract_drift_covered() { # unit-id
  local d
  doc_gap_resolved_current || return 1
  d="$(unit_contract_drift_json "$1")" || return 1
  # ② 전역 입력 그대로 · ④ 연결된 gap 이 있음 · 달라진 블록은 전부 ③ approach.md reference 블록이고 ⑤ 그 블록마다 연결된 gap 의 tag 가 본문에 있다 —
  # 같은 unit 의 다른 approach 절(B04)을 같이 고친 것까지 덮지 않는다.
  jq -e '(.global_changed|not) and (.linked_tags|length) > 0 and (.changed|length) > 0 and all(.changed[]; .approach and .tagged)' <<< "$d" >/dev/null 2>&1
}
# 완료 체크포인트가 유효한가: run-state 는 힌트일 뿐이고 실제 판정은 units/<id>/done.json 의 내용 + 현재 spec 지문 + **현재 유효 계약 지문** 교차 확인이다.
# 문서가 달라졌는데 unit JSON 이 같다는 이유로 DONE 을 재사용하지 않는다. done.json 포맷(version 2)만 맞춘다고 유효해지지 않는다 — 기준 스냅샷과 현재 계약이 같아야 한다.
unit_done_valid() { # unit-id
  local done="$WORK_DIR/units/$1/done.json" st
  [ -f "$done" ] || return 1
  jq -e --arg id "$1" --arg h "$(unit_spec_hash "$1")" --argjson v "$UNIT_DONE_VERSION" \
    '.version==$v and .unit_id==$id and .spec_hash==$h and .worker_status=="DONE" and .targeted_test_status=="PASS"
     and (.unit_contract_fingerprint|type=="string" and length>0)' "$done" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.unit_contract_fingerprint' "$done")" = "$(jq -r '.fingerprint // ""' "$(unit_contract_dir "$1")/contract.json" 2>/dev/null)" ] || return 1
  st="$(unit_contract_status "$1")"
  case "$st" in
    CURRENT) return 0;;
    STALE|IMPACT_REQUIRED) unit_contract_drift_covered "$1";;
    *) return 1;;
  esac
}
all_units_done() { local id; for id in $(unit_ids); do unit_done_valid "$id" || return 1; done; }

# ---------- unit 간 rolling implementation context ----------
# 파일: $WORK_DIR/implementation-context.json = {version, completed_units[], facts[{kind,subject,note,source_unit}]}.
# source of truth 가 아니다(실제 코드 → 합의 문서 → 이 파일). 각 완료 unit 의 units/<id>/context-updates.json(워커 → test-fix 순서의
# context_updates 원본)이 원천이고 이 파일은 그로부터 **재구성되는 파생 상태**다 — 러너는 의미를 해석하지 않고 upsert/remove 만 적용한다.
#   identity  : (kind, subject). 같은 키의 upsert 는 제자리 교체(append 아님), remove 는 삭제. 한 update 안에서는 remove → upsert 순.
#   확정 시점 : unit 워커 DONE → targeted test PASS → context-updates.json → done.json. 실패한 unit 의 update 는 확정되지 않는다.
#   resume    : lock 순서대로 done 체크포인트가 유효한(내용 + spec_hash) 연속 prefix 만 fold 한다 — 무효화된 체크포인트의 update 는 재사용하지 않는다.
IMPL_CONTEXT_FILE="$WORK_DIR/implementation-context.json"
IMPL_CONTEXT_VERSION=1
impl_context_empty() { jq -nc --argjson v "$IMPL_CONTEXT_VERSION" '{version:$v, completed_units:[], facts:[]}'; }
# 결과 JSON(워커/test-fix) 의 context_updates 를 정규화해 한 줄로 낸다(없으면 빈 update). source 는 산출물 접두(worker, test-fix-01 …).
context_update_of() { # result-json source-label
  jq -c --arg src "$2" '{source:$src, upsert:((.context_updates.upsert // []) | map({kind,subject,note})), remove:((.context_updates.remove // []) | map({kind,subject}))}' "$1"
}
# fold: base facts 배열(JSON 문자열) 에 updates 배열(파일)을 순서대로 적용한 facts 배열을 낸다. 결정론적 — 병합·요약 판단 없음.
fold_context_updates() { # base-facts-json updates-file source-unit
  jq -c --argjson base "$1" --arg unit "$3" '
    reduce .[] as $u ($base;
      reduce ($u.remove // [])[] as $r (.; map(select((.kind==$r.kind and .subject==$r.subject) | not)))
      | reduce ($u.upsert // [])[] as $f (.;
          ({kind:$f.kind, subject:$f.subject, note:$f.note, source_unit:$unit}) as $new
          | if any(.[]; .kind==$f.kind and .subject==$f.subject)
            then map(if .kind==$f.kind and .subject==$f.subject then $new else . end)
            else . + [$new] end))' "$2"
}
# implementation-context.json 재구성: lock 순서대로 완료 체크포인트가 유효한 unit 의 context-updates.json 을 fold 한다.
#   stop-id 가 있으면 그 unit 직전까지(현재 unit 워커 호출 전) — 그 앞의 unit 이 하나라도 무효면 실패(조용히 건너뛰지 않는다).
#   stop-id 가 없으면 첫 무효 unit 에서 멈춘다(그 뒤 unit 의 update 는 무효 unit 재실행 뒤 다시 포함된다).
impl_context_write() { # [stop-id]
  local stop="${1:-}" id facts='[]' done_ids='[]' upd
  for id in $(unit_ids); do
    [ "$id" != "$stop" ] || { stop=""; break; }
    if ! unit_done_valid "$id"; then
      [ -z "$stop" ] || return 1
      break
    fi
    upd="$WORK_DIR/units/$id/context-updates.json"
    if [ -f "$upd" ]; then
      facts="$(jq -c '.updates' "$upd" | fold_context_updates "$facts" /dev/stdin "$id")" || return 1
    else
      echo "[WARN] unit $id: context-updates.json 없음(이 변경 이전의 체크포인트) — 해당 unit 의 문맥 없이 진행" >&2
    fi
    done_ids="$(jq -c --arg id "$id" '. + [$id]' <<<"$done_ids")"
  done
  [ -z "$stop" ] || return 1   # stop-id 가 unit 목록에 없음
  jq -n --argjson v "$IMPL_CONTEXT_VERSION" --argjson u "$done_ids" --argjson f "$facts" '{version:$v, completed_units:$u, facts:$f}' \
    > "$IMPL_CONTEXT_FILE.tmp" && mv "$IMPL_CONTEXT_FILE.tmp" "$IMPL_CONTEXT_FILE"
}
