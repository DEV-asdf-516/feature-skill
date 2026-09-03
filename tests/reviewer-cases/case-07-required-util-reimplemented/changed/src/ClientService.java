public class ClientService {
  private final ClientRepository repo;
  private final ClientCache cache;
  public ClientService(ClientRepository repo, ClientCache cache) { this.repo = repo; this.cache = cache; }
  public Client get(long id) { return cache.get(id, () -> findOrThrow(id)); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public ClientSummary summary(long id) {
    Client client = findOrThrow(id);
    String phone = client.phone();
    String masked = phone.length() < 8 ? phone : phone.substring(0, 3) + "****" + phone.substring(7);
    return new ClientSummary(client.id(), client.name(), masked);
  }
}
