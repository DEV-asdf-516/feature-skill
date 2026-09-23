import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class NotificationServiceTest {
  private final ClientRepository repo = mock(ClientRepository.class);
  private final SmsGateway gateway = mock(SmsGateway.class);
  private final NotificationService service = new NotificationService(repo, gateway);

  @Test void send_withPhone_sendsOnceAndReturnsSent() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Client(1L, "Kim", "01012345678")));
    assertEquals(SendStatus.SENT, service.send(1L));
    verify(gateway, times(1)).send("01012345678", "안내 메시지");
  }

  @Test void send_emptyPhone_skips() {
    when(repo.findById(2L)).thenReturn(java.util.Optional.of(new Client(2L, "Lee", "")));
    assertEquals(SendStatus.SKIPPED_NO_PHONE, service.send(2L));
    verifyNoInteractions(gateway);
  }

  @Test void send_unknownId_throwsNotFound() {
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.send(9L));
  }
}
