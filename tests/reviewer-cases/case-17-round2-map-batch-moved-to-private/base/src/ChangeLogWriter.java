public class ChangeLogWriter {
  private final ChangeLogRepository repo;
  public ChangeLogWriter(ChangeLogRepository repo) { this.repo = repo; }
  public void write(long clientId, String field, String before, String after) {
    repo.save(new ChangeLog(clientId, field, before, after));
  }
  public void writeAll(long clientId, java.util.Map<String, FieldChange> changes) {
    for (java.util.Map.Entry<String, FieldChange> e : changes.entrySet()) {
      write(clientId, e.getKey(), e.getValue().before(), e.getValue().after());
    }
  }
}
