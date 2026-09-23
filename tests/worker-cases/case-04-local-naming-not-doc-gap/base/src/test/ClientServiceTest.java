public class ClientServiceTest {
  static void check(boolean cond, String msg) { if (!cond) throw new AssertionError(msg); }

  public static void main(String[] args) {
    get_returnsClient();
    get_unknownId_throwsNotFound();
    changePhone_savesAndReturnsChanged();
    System.out.println("ClientServiceTest OK");
  }

  static void get_returnsClient() {
    ClientService service = new ClientService(new InMemoryClientRepository(new Client(1L, "Kim", "01012345678")));
    check("Kim".equals(service.get(1L).name()), "get_returnsClient");
  }

  static void get_unknownId_throwsNotFound() {
    ClientService service = new ClientService(new InMemoryClientRepository());
    try { service.get(9L); check(false, "get_unknownId_throwsNotFound: no exception"); } catch (NotFoundException expected) { }
  }

  static void changePhone_savesAndReturnsChanged() {
    InMemoryClientRepository repo = new InMemoryClientRepository(new Client(1L, "Kim", "01012345678"));
    ClientService service = new ClientService(repo);
    Client changed = service.changePhone(1L, "01099998888");
    check("01099998888".equals(changed.phone()), "changePhone: returned phone");
    check(repo.saved.size() == 1 && repo.saved.get(0) == changed, "changePhone: saved once with returned instance");
  }
}
