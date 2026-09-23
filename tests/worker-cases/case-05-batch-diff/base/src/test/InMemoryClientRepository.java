public class InMemoryClientRepository implements ClientRepository {
  private final java.util.Map<Long, Client> store = new java.util.HashMap<>();
  public final java.util.List<Client> saved = new java.util.ArrayList<>();
  public InMemoryClientRepository(Client... clients) { for (Client c : clients) store.put(c.id(), c); }
  public java.util.Optional<Client> findById(long id) { return java.util.Optional.ofNullable(store.get(id)); }
  public void save(Client client) { store.put(client.id(), client); saved.add(client); }
}
