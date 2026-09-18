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
    java.util.Map<String, FieldChange> changes = collectChanges(before, update);
    changeLogs.writeAll(id, changes);
    Client after = before.apply(update);
    repo.save(after);
    return after;
  }

  private java.util.Map<String, FieldChange> collectChanges(Client before, ClientUpdate update) {
    java.util.Map<String, FieldChange> changes = new java.util.LinkedHashMap<>();
    if (!before.name().equals(update.name())) changes.put("name", new FieldChange(before.name(), update.name()));
    if (!before.phone().equals(update.phone())) changes.put("phone", new FieldChange(before.phone(), update.phone()));
    if (!before.email().equals(update.email())) changes.put("email", new FieldChange(before.email(), update.email()));
    return changes;
  }
}
