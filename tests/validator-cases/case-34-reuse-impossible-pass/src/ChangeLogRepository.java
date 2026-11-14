import java.util.List;

public interface ChangeLogRepository {
  void saveAll(long quoteId, List<ChangeLogEntry> entries);
}
