public class ClientService {
  private final ClientRepository repo;
  public ClientService(ClientRepository repo) { this.repo = repo; }
  public Client get(long id) { return findOrThrow(id); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public Client update(long id, ClientUpdateRequest request) {
    Client before = findOrThrow(id);
    if (request.getName() == null || request.getName().isBlank()) {
      throw new IllegalArgumentException("name");
    }
    if (request.getPhone() == null || !request.getPhone().matches("\\d{10,11}")) {
      throw new IllegalArgumentException("phone");
    }
    Client after = before.updated(request);
    repo.save(after);
    return after;
  }
}
