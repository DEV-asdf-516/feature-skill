import java.util.ArrayList;
import java.util.List;

public class QuoteChangeLogService {
  private final ChangeLogRepository repo;
  public QuoteChangeLogService(ChangeLogRepository repo) { this.repo = repo; }

  /** 값이 바뀐 필드마다 변경 항목을 만들어 저장하고, 저장한 변경 항목 목록을 반환한다(변경이 없으면 빈 목록). 순서는 title → amount → dueDate. */
  public List<ChangeLogEntry> logUpdated(Quote before, QuoteUpdate update) {
    List<ChangeLogEntry> changes = new ArrayList<>();
    if (!before.title().equals(update.title())) changes.add(new ChangeLogEntry("title", before.title(), update.title()));
    if (before.amount() != update.amount()) changes.add(new ChangeLogEntry("amount", String.valueOf(before.amount()), String.valueOf(update.amount())));
    if (!before.dueDate().equals(update.dueDate())) changes.add(new ChangeLogEntry("dueDate", before.dueDate(), update.dueDate()));
    repo.saveAll(before.id(), changes);
    return changes;
  }
}
