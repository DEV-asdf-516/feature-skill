public class ClientService {
  private final ClientRepository repo;
  private final ChangeLogWriter changeLogs;
  public ClientService(ClientRepository repo, ChangeLogWriter changeLogs) { this.repo = repo; this.changeLogs = changeLogs; }
  public Client get(long id) { return findOrThrow(id); }

  private Client findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
  }

  public Client update(long id, ClientUpdate update) {
    Client before = findOrThrow(id);
    if (!before.name().equals(update.name())) {
      changeLogs.write(id, "name", before.name(), update.name());
    }
    if (!before.phone().equals(update.phone())) {
      changeLogs.write(id, "phone", before.phone(), update.phone());
    }
    if (!before.email().equals(update.email())) {
      changeLogs.write(id, "email", before.email(), update.email());
    }
    Client after = before.apply(update);
    repo.save(after);
    return after;
  }
}
