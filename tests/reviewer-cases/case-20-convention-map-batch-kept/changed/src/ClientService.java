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
    java.util.Map<String, FieldChange> changes = DiffUtil.diff(before.fields(), update.fields());
    changeLogs.writeAll(id, changes);
    Client after = before.apply(update);
    repo.save(after);
    return after;
  }
}
