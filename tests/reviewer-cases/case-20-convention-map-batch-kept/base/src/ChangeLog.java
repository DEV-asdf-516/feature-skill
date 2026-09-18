public final class ChangeLog {
  private final long clientId;
  private final String field;
  private final String before;
  private final String after;
  public ChangeLog(long clientId, String field, String before, String after) { this.clientId = clientId; this.field = field; this.before = before; this.after = after; }
  public long clientId() { return clientId; }
  public String field() { return field; }
  public String before() { return before; }
  public String after() { return after; }
}
