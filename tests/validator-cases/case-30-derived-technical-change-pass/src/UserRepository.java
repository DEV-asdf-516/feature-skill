public interface UserRepository {
  java.util.Optional<User> findById(long id);
  void updateName(long id, String name);
}
