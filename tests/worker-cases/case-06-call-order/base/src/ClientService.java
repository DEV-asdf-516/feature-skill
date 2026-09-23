public class ClientService {
  private final ClientRepository repo;
  private final ProfilePublisher publisher;
  public ClientService(ClientRepository repo, ProfilePublisher publisher) { this.repo = repo; this.publisher = publisher; }
  public Client get(long id) { return findOrThrow(id); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public ClientProfile profile(long id) {
    Client client = findOrThrow(id);
    return new ClientProfile(client.id(), client.name());
  }
}
