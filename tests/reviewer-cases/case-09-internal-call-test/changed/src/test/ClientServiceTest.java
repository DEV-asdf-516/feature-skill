import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class ClientServiceTest {
  private final ClientRepository repo = mock(ClientRepository.class);
  private final ClientService service = new ClientService(repo, new ClientCache());

  @Test void get_returnsClient() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    assertEquals("Kim", service.get(1L).name());
  }

  @Test void get_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.get(9L));
  }

  @Test void summary_returnsThreeFields() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    ClientSummary summary = service.summary(1L);
    assertEquals(1L, summary.id());
    assertEquals("Kim", summary.name());
    assertEquals("010****5678", summary.maskedPhone());
  }

  @Test void summary_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.summary(9L));
  }

  @Test void summary_callsRepositoryExactlyOnce() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    service.summary(1L);
    verify(repo, times(1)).findById(1L);
    verifyNoMoreInteractions(repo);
  }
}
