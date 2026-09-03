// 알려진 기존 결함: 갱신 시 캐시를 비우지 않아 오래된 값이 남을 수 있음 (이번 피처 범위 밖)
public class ClientCache {
  private final java.util.Map<Long, Client> map = new java.util.HashMap<>();
  public Client get(long id, java.util.function.Supplier<Client> loader) {
    return map.computeIfAbsent(id, k -> loader.get());
  }
}
