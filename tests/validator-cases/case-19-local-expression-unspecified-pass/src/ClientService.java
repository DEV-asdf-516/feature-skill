public class ClientService {
  private final ClientRepository repo;
  public ClientService(ClientRepository repo) { this.repo = repo; }
  public Client get(long id) { return findOrThrow(id); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }
}
