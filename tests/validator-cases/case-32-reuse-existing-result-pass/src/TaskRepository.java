import java.util.Optional;

public interface TaskRepository {
  Optional<Task> findById(long id);
  void save(Task task);
}
