import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public class QuoteServiceTest {
  static final class Fixture {
    final List<QuoteEditNotification> sent = new ArrayList<>();
    final QuoteRepository quotes = new QuoteRepository() {
      public Optional<Quote> findById(long id) { return id == 1 ? Optional.of(new Quote(1, "A", 100, "2026-01-01")) : Optional.empty(); }
      public void save(Quote quote) {}
    };
    final QuoteService service = new QuoteService(quotes, new QuoteChangeLogService((quoteId, entries) -> {}), sent::add);
  }

  void update_notifiesChangedFields() {
    Fixture f = new Fixture();
    f.service.update(1, new QuoteUpdate("B", 100, "2026-02-01"));
    assert f.sent.size() == 1 && f.sent.get(0).changedFields().equals(List.of("title", "dueDate"));
  }

  void update_noChange_doesNotNotify() {
    Fixture f = new Fixture();
    f.service.update(1, new QuoteUpdate("A", 100, "2026-01-01"));
    assert f.sent.isEmpty();
  }
}
