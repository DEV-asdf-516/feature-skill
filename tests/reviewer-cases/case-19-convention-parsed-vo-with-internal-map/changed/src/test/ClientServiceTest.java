import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class ClientServiceTest {
  private final ClientRepository repo = mock(ClientRepository.class);
  private final ClientService service = new ClientService(repo);

  @Test void get_returnsClient() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    assertEquals("Kim", service.get(1L).name());
  }

  @Test void get_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.get(9L));
  }

  @Test void update_savesUpdatedClient() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    Client after = service.update(1L, new ClientUpdateRequest("Lee", "01099998888"));
    assertEquals("Lee", after.name());
    assertEquals("01099998888", after.phone());
    verify(repo).save(after);
  }

  @Test void update_rejectsBlankName() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    assertThrows(IllegalArgumentException.class, () -> service.update(1L, new ClientUpdateRequest("  ", "01099998888")));
    verify(repo, never()).save(any());
  }

  @Test void update_rejectsNonDigitPhone() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    assertThrows(IllegalArgumentException.class, () -> service.update(1L, new ClientUpdateRequest("Lee", "010-9999-8888")));
    verify(repo, never()).save(any());
  }

  @Test void update_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.update(9L, new ClientUpdateRequest("Lee", "01099998888")));
  }
}
