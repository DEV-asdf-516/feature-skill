import java.util.ArrayList;
import java.util.List;

public record TaskEditNotification(long taskId, List<String> changedFields) {
  public static TaskEditNotification of(long taskId, List<ChangeLogEntry> changes) {
    return new TaskEditNotification(taskId, fieldNames(changes));
  }

  private static List<String> fieldNames(List<ChangeLogEntry> changes) {
    List<String> names = new ArrayList<>();
    for (ChangeLogEntry change : changes) names.add(change.field());
    return names;
  }
}
