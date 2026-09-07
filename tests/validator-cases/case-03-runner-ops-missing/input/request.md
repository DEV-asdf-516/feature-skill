# request.md
기존 제품 API 응답에 optional subtitle 필드를 추가한다. 값이 없으면 null이며 기존 id/name 값은 유지한다.
변경 범위는 src/ProductView.java와 src/ProductService.java다. 기존 JSON 직렬화는 record component 이름을 그대로 응답 필드로 사용하며 null도 출력한다.
