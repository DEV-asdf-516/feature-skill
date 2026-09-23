public class ClientService {
  private final ClientRepository repo;
  private final ClientCache cache;
  public ClientService(ClientRepository repo, ClientCache cache) { this.repo = repo; this.cache = cache; }
  public Client get(long id) { return cache.get(id, () -> findOrThrow(id)); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public ClientProfile profile(long id) {
    Client client = findOrThrow(id);
    return new ClientProfile(client.id(), client.name());
  }

  public ClientSummary summary(long id) {
    Client found = findOrThrow(id);
    return new ClientSummary(found.id(), found.name(), MaskingUtil.maskPhone(found.phone()));
  }
}
