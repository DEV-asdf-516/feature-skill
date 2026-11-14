import java.util.List;

public record TaskEditNotification(long taskId, List<String> changedFields) {}
