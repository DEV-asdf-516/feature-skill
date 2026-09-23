import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class NotificationServiceTest {
  private final ClientRepository repo = mock(ClientRepository.class);
  private final SmsGateway gateway = mock(SmsGateway.class);
  private final NotificationService service = new NotificationService(repo, gateway);
}
