# implementation.md
src/ProductView.java에 String subtitle component를 추가한다.
src/ProductService.java의 view에 subtitle 인자를 추가하고 record 생성 시 전달한다. 기존 두 인자 view 호출도 유지하며 subtitle=null로 위임한다.
테스트: subtitle="detail"이면 그대로 반환, 없으면 null, 두 경우 모두 기존 id/name 유지.
## 작업 메모
현재 작업 트리에 미커밋 메모가 있다. git diff 기준선 선택과 이전 작업 archive 이름은 아직 정하지 않았다.
