public interface ChangeHistoryRepository {
  void save(String type, long targetId, String before, String after);
}
