import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class ClientServiceTest {
  private final ClientRepository repo = mock(ClientRepository.class);
  private final java.util.List<ChangeLog> saved = new java.util.ArrayList<>();
  private final ClientService service = new ClientService(repo, new ChangeLogWriter(saved::add));

  @Test void get_returnsClient() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678", "kim@x.io")));
    assertEquals("Kim", service.get(1L).name());
  }

  @Test void get_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.get(9L));
  }

  @Test void update_logsChangedFieldsOnly() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678", "kim@x.io")));
    Client after = service.update(1L, new ClientUpdate("Lee", "01012345678", "lee@x.io"));
    assertEquals("Lee", after.name());
    assertEquals(2, saved.size());
    assertEquals("name", saved.get(0).field()); assertEquals("Kim", saved.get(0).before()); assertEquals("Lee", saved.get(0).after());
    assertEquals("email", saved.get(1).field()); assertEquals("kim@x.io", saved.get(1).before()); assertEquals("lee@x.io", saved.get(1).after());
    verify(repo).save(after);
  }

  @Test void update_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.update(9L, new ClientUpdate("Lee", "01012345678", "lee@x.io")));
    assertTrue(saved.isEmpty());
  }
}
