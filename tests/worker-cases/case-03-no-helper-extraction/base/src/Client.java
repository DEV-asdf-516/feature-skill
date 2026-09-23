public final class Client {
  private final long id;
  private final String name;
  private final java.util.List<String> tags;
  public Client(long id, String name, java.util.List<String> tags) { this.id = id; this.name = name; this.tags = java.util.List.copyOf(tags); }
  public long id() { return id; }
  public String name() { return name; }
  public java.util.List<String> tags() { return tags; }
}
