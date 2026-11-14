import java.util.List;

public class TaskService {
  private final TaskRepository tasks;
  private final TaskChangeLogService changeLog;
  private final Notifier notifier;
  public TaskService(TaskRepository tasks, TaskChangeLogService changeLog, Notifier notifier) { this.tasks = tasks; this.changeLog = changeLog; this.notifier = notifier; }

  public Task update(long id, TaskUpdate update) {
    Task before = tasks.findById(id).orElseThrow(() -> new NotFoundException("task " + id));
    List<ChangeLogEntry> changes = changeLog.logUpdated(before, update);
    if (!changes.isEmpty()) notifier.send(TaskEditNotification.of(id, changes));
    Task after = before.applied(update);
    tasks.save(after);
    return after;
  }
}
