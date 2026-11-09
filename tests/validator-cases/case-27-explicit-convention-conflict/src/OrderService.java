public class OrderService {
  private final OrderRepository repo;
  public OrderService(OrderRepository repo) { this.repo = repo; }

  public OrderEntity get(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("order " + id));
  }
}
