import java.util.List;

public class QuoteService {
  private final QuoteRepository quotes;
  private final QuoteChangeLogService changeLog;
  private final Notifier notifier;
  public QuoteService(QuoteRepository quotes, QuoteChangeLogService changeLog, Notifier notifier) { this.quotes = quotes; this.changeLog = changeLog; this.notifier = notifier; }

  public Quote update(long id, QuoteUpdate update) {
    Quote before = quotes.findById(id).orElseThrow(() -> new NotFoundException("quote " + id));
    List<ChangeLogEntry> changes = changeLog.logUpdated(before, update);
    if (!changes.isEmpty()) notifier.send(QuoteEditNotification.of(id, changes));
    Quote after = before.applied(update);
    quotes.save(after);
    return after;
  }
}
