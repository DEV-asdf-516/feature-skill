public class ClientService {
  private final ClientRepository repo;
  private final ClientCache cache;
  private final ClientSummaryRepository summaryRepo;
  public ClientService(ClientRepository repo, ClientCache cache) {
    this.repo = repo; this.cache = cache; this.summaryRepo = new ClientSummaryRepository(repo);
  }
  public Client get(long id) { return cache.get(id, () -> findOrThrow(id)); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public ClientSummary summary(long id) {
    Client client = summaryRepo.findById(id);
    return new ClientSummary(client.id(), client.name(), MaskingUtil.maskPhone(client.phone()));
  }

  static final class ClientSummaryRepository {
    private final ClientRepository repo;
    ClientSummaryRepository(ClientRepository repo) { this.repo = repo; }
    Client findById(long id) {
      return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
    }
  }
}
