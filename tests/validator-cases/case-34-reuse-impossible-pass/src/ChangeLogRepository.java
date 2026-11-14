import java.util.List;

public interface ChangeLogRepository {
  void saveAll(long taskId, List<ChangeLogEntry> entries);
}
