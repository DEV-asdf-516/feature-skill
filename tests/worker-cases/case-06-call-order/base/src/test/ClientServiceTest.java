public class ClientServiceTest {
  static void check(boolean cond, String msg) { if (!cond) throw new AssertionError(msg); }
  static ClientRepository repoWith(Client... clients) {
    java.util.Map<Long, Client> m = new java.util.HashMap<>();
    for (Client c : clients) m.put(c.id(), c);
    return id -> java.util.Optional.ofNullable(m.get(id));
  }
  static class RecordingPublisher implements ProfilePublisher {
    final java.util.List<ClientProfile> published = new java.util.ArrayList<>();
    public void publish(ClientProfile profile) { published.add(profile); }
  }

  public static void main(String[] args) {
    get_returnsClient();
    get_unknownId_throwsNotFound();
    profile_returnsIdAndName();
    System.out.println("ClientServiceTest OK");
  }

  static void get_returnsClient() {
    ClientService service = new ClientService(repoWith(new Client(1L, "Kim", "01012345678")), new RecordingPublisher());
    check("Kim".equals(service.get(1L).name()), "get_returnsClient");
  }

  static void get_unknownId_throwsNotFound() {
    ClientService service = new ClientService(repoWith(), new RecordingPublisher());
    try { service.get(9L); check(false, "get_unknownId_throwsNotFound: no exception"); } catch (NotFoundException expected) { }
  }

  static void profile_returnsIdAndName() {
    ClientService service = new ClientService(repoWith(new Client(1L, "Kim", "01012345678")), new RecordingPublisher());
    ClientProfile profile = service.profile(1L);
    check(profile.id() == 1L && "Kim".equals(profile.name()), "profile_returnsIdAndName");
  }
}
