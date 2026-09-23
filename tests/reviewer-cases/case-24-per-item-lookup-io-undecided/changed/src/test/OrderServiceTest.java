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

  @Test void statuses_returnsInInputOrder() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Order(1L, "PAID")));
    when(repo.findById(2L)).thenReturn(java.util.Optional.of(new Order(2L, "SHIPPED")));
    assertEquals(List.of("PAID", "SHIPPED"), service.statuses(List.of(1L, 2L)));
  }

  @Test void statuses_unknownId_throwsNotFound() {
    when(repo.findById(1L)).thenReturn(java.util.Optional.of(new Order(1L, "PAID")));
    when(repo.findById(9L)).thenReturn(java.util.Optional.empty());
    assertThrows(NotFoundException.class, () -> service.statuses(List.of(1L, 9L)));
  }
}
