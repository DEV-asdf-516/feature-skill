public final class ClientProfile {
  private final long id;
  private final String name;
  public ClientProfile(long id, String name) { this.id = id; this.name = name; }
  public long id() { return id; }
  public String name() { return name; }
}
