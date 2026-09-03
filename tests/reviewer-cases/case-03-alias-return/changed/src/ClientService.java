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
    ClientSummary summary = new ClientSummary(client.id(), client.name(), MaskingUtil.maskPhone(client.phone()));
    return summary;
  }
}
