public final class ClientUpdate {
  private final String name;
  private final String phone;
  private final String email;
  public ClientUpdate(String name, String phone, String email) { this.name = name; this.phone = phone; this.email = email; }
  public String name() { return name; }
  public String phone() { return phone; }
  public String email() { return email; }
  public java.util.Map<String, String> fields() {
    java.util.Map<String, String> m = new java.util.LinkedHashMap<>();
    m.put("name", name); m.put("phone", phone); m.put("email", email);
    return m;
  }
}
