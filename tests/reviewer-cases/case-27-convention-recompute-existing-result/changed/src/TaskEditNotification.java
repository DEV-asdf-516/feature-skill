import java.util.ArrayList;
import java.util.List;

public record TaskEditNotification(long taskId, List<String> changedFields) {
  public static TaskEditNotification of(Task before, TaskUpdate update) {
    List<String> fields = new ArrayList<>();
    if (!before.title().equals(update.title())) fields.add("title");
    if (before.amount() != update.amount()) fields.add("amount");
    if (!before.dueDate().equals(update.dueDate())) fields.add("dueDate");
    return new TaskEditNotification(before.id(), fields);
  }
}
