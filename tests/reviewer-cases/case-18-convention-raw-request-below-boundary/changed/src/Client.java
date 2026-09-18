public final class Client {
  private final long id;
  private final String name;
  private final String phone;
  public Client(long id, String name, String phone) { this.id = id; this.name = name; this.phone = phone; }
  public long id() { return id; }
  public String name() { return name; }
  public String phone() { return phone; }
  public Client updated(ClientUpdateRequest request) {
    return new Client(id, request.getName(), request.getPhone());
  }
}
