public class QuoteService {
  private final QuoteRepository quotes;
  private final QuoteChangeLogService changeLog;
  private final Notifier notifier;
  public QuoteService(QuoteRepository quotes, QuoteChangeLogService changeLog, Notifier notifier) { this.quotes = quotes; this.changeLog = changeLog; this.notifier = notifier; }

  public Quote update(long id, QuoteUpdate update) {
    Quote before = quotes.findById(id).orElseThrow(() -> new NotFoundException("quote " + id));
    changeLog.logUpdated(before, update);
    QuoteEditNotification notification = QuoteEditNotification.of(before, update);
    if (!notification.changedFields().isEmpty()) notifier.send(notification);
    Quote after = before.applied(update);
    quotes.save(after);
    return after;
  }
}
