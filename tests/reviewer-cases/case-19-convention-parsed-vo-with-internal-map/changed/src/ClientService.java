public class ClientService {
  private final ClientRepository repo;
  public ClientService(ClientRepository repo) { this.repo = repo; }
  public Client get(long id) { return findOrThrow(id); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public Client update(long id, ClientUpdateRequest request) {
    Client before = findOrThrow(id);
    ClientPatch patch = ClientPatch.parse(request);
    Client after = before.updated(patch);
    repo.save(after);
    return after;
  }
}
