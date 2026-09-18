public final class Client {
  private final long id;
  private final String name;
  private final String phone;
  private final String email;
  public Client(long id, String name, String phone, String email) { this.id = id; this.name = name; this.phone = phone; this.email = email; }
  public long id() { return id; }
  public String name() { return name; }
  public String phone() { return phone; }
  public String email() { return email; }
  public java.util.Map<String, String> fields() {
    java.util.Map<String, String> m = new java.util.LinkedHashMap<>();
    m.put("name", name); m.put("phone", phone); m.put("email", email);
    return m;
  }
  public Client apply(ClientUpdate update) {
    return new Client(id, update.name(), update.phone(), update.email());
  }
}
