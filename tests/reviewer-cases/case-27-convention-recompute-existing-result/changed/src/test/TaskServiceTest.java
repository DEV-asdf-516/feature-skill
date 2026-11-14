import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public class TaskServiceTest {
  static final class Fixture {
    final List<TaskEditNotification> sent = new ArrayList<>();
    final TaskRepository tasks = new TaskRepository() {
      public Optional<Task> findById(long id) { return id == 1 ? Optional.of(new Task(1, "A", 100, "2026-01-01")) : Optional.empty(); }
      public void save(Task task) {}
    };
    final TaskService service = new TaskService(tasks, new TaskChangeLogService((taskId, entries) -> {}), sent::add);
  }

  void update_notifiesChangedFields() {
    Fixture f = new Fixture();
    f.service.update(1, new TaskUpdate("B", 100, "2026-02-01"));
    assert f.sent.size() == 1 && f.sent.get(0).changedFields().equals(List.of("title", "dueDate"));
  }

  void update_noChange_doesNotNotify() {
    Fixture f = new Fixture();
    f.service.update(1, new TaskUpdate("A", 100, "2026-01-01"));
    assert f.sent.isEmpty();
  }
}
