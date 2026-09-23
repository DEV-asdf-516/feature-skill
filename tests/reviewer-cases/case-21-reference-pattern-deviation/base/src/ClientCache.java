public class ClientCache {
  private final java.util.Map<Long, Client> map = new java.util.HashMap<>();
  public Client get(long id, java.util.function.Supplier<Client> loader) {
    return map.computeIfAbsent(id, k -> loader.get());
  }
  public void evict(long id) {
    map.remove(String.valueOf(id));
  }
}
