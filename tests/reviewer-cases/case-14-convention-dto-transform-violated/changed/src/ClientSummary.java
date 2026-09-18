public final class ClientSummary {
  private final long id;
  private final String name;
  private final String maskedPhone;
  public ClientSummary(long id, String name, String maskedPhone) { this.id = id; this.name = name; this.maskedPhone = maskedPhone; }
  public static ClientSummary from(Client client) {
    return new ClientSummary(client.id(), client.name(), MaskingUtil.maskPhone(client.phone()));
  }
  public long id() { return id; }
  public String name() { return name; }
  public String maskedPhone() { return maskedPhone; }
}
