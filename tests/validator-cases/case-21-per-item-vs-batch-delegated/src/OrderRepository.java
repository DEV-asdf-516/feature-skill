public interface OrderRepository {
  java.util.Optional<Order> findById(long id);
  java.util.List<Order> findAllByIds(java.util.List<Long> ids);
}
