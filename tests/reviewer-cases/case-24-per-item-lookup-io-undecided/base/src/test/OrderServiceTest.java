import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class OrderServiceTest {
  private final OrderRepository repo = mock(OrderRepository.class);
  private final OrderService service = new OrderService(repo);

  @Test void get_returnsOrder() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Order(1L, "PAID")));
    assertEquals("PAID", service.get(1L).status());
  }
}
