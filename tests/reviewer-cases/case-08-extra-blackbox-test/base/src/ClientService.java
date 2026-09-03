public class ClientService {
  private final ClientRepository repo;
  private final ClientCache cache;
  public ClientService(ClientRepository repo, ClientCache cache) { this.repo = repo; this.cache = cache; }
  public Client get(long id) { return cache.get(id, () -> findOrThrow(id)); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }
}
