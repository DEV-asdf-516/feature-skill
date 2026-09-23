public class ClientServiceTest {
  static void check(boolean cond, String msg) { if (!cond) throw new AssertionError(msg); }

  public static void main(String[] args) {
    get_returnsClient();
    get_unknownId_throwsNotFound();
    System.out.println("ClientServiceTest OK");
  }

  static void get_returnsClient() {
    java.util.List<ChangeLog> logs = new java.util.ArrayList<>();
    ClientService service = new ClientService(new InMemoryClientRepository(new Client(1L, "Kim", "01012345678", "kim@x.io")), new ChangeLogWriter(logs::add));
    check("Kim".equals(service.get(1L).name()), "get_returnsClient");
  }

  static void get_unknownId_throwsNotFound() {
    java.util.List<ChangeLog> logs = new java.util.ArrayList<>();
    ClientService service = new ClientService(new InMemoryClientRepository(), new ChangeLogWriter(logs::add));
    try { service.get(9L); check(false, "get_unknownId_throwsNotFound: no exception"); } catch (NotFoundException expected) { }
  }
}
